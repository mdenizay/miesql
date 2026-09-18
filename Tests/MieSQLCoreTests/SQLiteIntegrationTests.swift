import Foundation
import Testing
@testable import MieSQLCore

/// End-to-end coverage against a real SQLite file: DDL, queries, introspection, then a
/// dump that is restored into a second database and compared row for row.
@Suite("SQLite driver", .serialized)
struct SQLiteIntegrationTests {

    private func makeProfile(path: String) -> ConnectionProfile {
        ConnectionProfile(name: "test", kind: .sqlite, filePath: path)
    }

    private func temporaryPath(_ name: String) -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miesql-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name).path
    }

    private func seed(_ driver: SQLiteDriver) async throws {
        _ = try await driver.execute("""
        CREATE TABLE users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            email TEXT UNIQUE,
            age INTEGER,
            balance REAL,
            bio TEXT
        );
        CREATE INDEX idx_users_email ON users(email);
        CREATE TABLE orders (
            id INTEGER PRIMARY KEY,
            user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            total REAL NOT NULL
        );
        INSERT INTO users (name, email, age, balance, bio) VALUES
            ('Ada Lovelace', 'ada@example.com', 36, 1250.75, 'First programmer'),
            ('Grace Hopper', 'grace@example.com', 85, 980.0, 'Compiler pioneer'),
            ('Alan Turing', 'alan@example.com', 41, NULL, NULL);
        INSERT INTO orders (user_id, total) VALUES (1, 99.9), (2, 12.0);
        """)
    }

    @Test("Connects, queries and reports metadata")
    func queriesAndMetadata() async throws {
        let driver = SQLiteDriver(credentials: ConnectionCredentials(profile: makeProfile(path: temporaryPath("a.sqlite")), password: nil))
        let info = try await driver.connect()
        #expect(info.productName == "SQLite")
        #expect(!info.version.isEmpty)

        try await seed(driver)

        let results = try await driver.execute("SELECT id, name, balance FROM users ORDER BY id")
        let result = try #require(results.first)
        #expect(result.columns.map(\.name) == ["id", "name", "balance"])
        #expect(result.rows.count == 3)
        #expect(result.rows[0][1].stringValue == "Ada Lovelace")
        // NULL must stay distinct from the empty string all the way to the grid.
        #expect(result.rows[2][2].isNull)

        let update = try await driver.execute("UPDATE users SET age = age + 1 WHERE id <= 2")
        #expect(update.first?.rowsAffected == 2)

        await driver.disconnect()
    }

    @Test("Reads columns, indexes and foreign keys")
    func introspection() async throws {
        let driver = SQLiteDriver(credentials: ConnectionCredentials(profile: makeProfile(path: temporaryPath("b.sqlite")), password: nil))
        _ = try await driver.connect()
        try await seed(driver)

        let tables = try await driver.listTables(in: SchemaRef(database: "main"))
        #expect(Set(tables.map(\.name)) == ["users", "orders"])

        let users = try #require(tables.first { $0.name == "users" })
        let details = try await driver.describe(table: users)
        #expect(details.columns.map(\.name) == ["id", "name", "email", "age", "balance", "bio"])
        #expect(details.primaryKeyColumns == ["id"])
        #expect(details.columns.first { $0.name == "name" }?.isNullable == false)
        #expect(details.indexes.contains { $0.name == "idx_users_email" && $0.columns == ["email"] })
        #expect(details.estimatedRowCount == 3)

        let orders = try #require(tables.first { $0.name == "orders" })
        let orderDetails = try await driver.describe(table: orders)
        let key = try #require(orderDetails.foreignKeys.first)
        #expect(key.columns == ["user_id"])
        #expect(key.referencedTable == "users")
        #expect(key.referencedColumns == ["id"])

        let ddl = try await driver.createStatement(for: users)
        #expect(ddl.contains("CREATE TABLE users"))
        #expect(ddl.contains("idx_users_email"))

        await driver.disconnect()
    }

    @Test("Paging and counting agree with the data")
    func pagingAndCounting() async throws {
        let driver = SQLiteDriver(credentials: ConnectionCredentials(profile: makeProfile(path: temporaryPath("c.sqlite")), password: nil))
        _ = try await driver.connect()
        try await seed(driver)

        let users = TableRef(database: "main", name: "users")
        #expect(try await driver.countRows(table: users) == 3)
        #expect(try await driver.countRows(table: users, whereClause: "age > 40") == 2)

        let firstPage = try await driver.fetchRows(
            table: users,
            orderBy: [(column: "id", ascending: true)],
            limit: 2,
            offset: 0
        )
        #expect(firstPage.rows.count == 2)

        let secondPage = try await driver.fetchRows(
            table: users,
            orderBy: [(column: "id", ascending: true)],
            limit: 2,
            offset: 2
        )
        #expect(secondPage.rows.count == 1)
        #expect(secondPage.rows[0][1].stringValue == "Alan Turing")

        await driver.disconnect()
    }

    @Test("Read-only connections refuse writes")
    func readOnlyIsEnforced() async throws {
        let path = temporaryPath("d.sqlite")
        let writable = SQLiteDriver(credentials: ConnectionCredentials(profile: makeProfile(path: path), password: nil))
        _ = try await writable.connect()
        try await seed(writable)
        await writable.disconnect()

        var profile = makeProfile(path: path)
        profile.readOnly = true
        let guarded = SQLiteDriver(credentials: ConnectionCredentials(profile: profile, password: nil))
        _ = try await guarded.connect()

        // Reads still work…
        let read = try await guarded.execute("SELECT COUNT(*) FROM users")
        #expect(read.first?.rows.first?[0].stringValue == "3")

        // …writes are stopped before they reach the file.
        await #expect(throws: DatabaseError.self) {
            _ = try await guarded.execute("DELETE FROM users")
        }

        await guarded.disconnect()
    }

    @Test("A dump restores into an identical database")
    func dumpAndRestoreRoundTrip() async throws {
        let sourcePath = temporaryPath("source.sqlite")
        let source = SQLiteDriver(credentials: ConnectionCredentials(profile: makeProfile(path: sourcePath), password: nil))
        _ = try await source.connect()
        try await seed(source)

        let tables = try await source.listTables(in: SchemaRef(database: "main"))
        let dumpURL = URL(fileURLWithPath: temporaryPath("dump.sql"))

        try await DumpService().dump(
            tables: tables,
            using: source,
            kind: .sqlite,
            options: DumpOptions(rowsPerInsert: 2),
            to: dumpURL
        ) { _ in }

        let script = try String(contentsOf: dumpURL, encoding: .utf8)
        #expect(script.contains("CREATE TABLE users"))
        #expect(script.contains("INSERT INTO \"users\""))
        // Text values must be quoted and numbers must not be.
        #expect(script.contains("'Ada Lovelace'"))
        #expect(script.contains("1250.75"))
        #expect(script.contains("NULL"))

        await source.disconnect()

        let restored = SQLiteDriver(credentials: ConnectionCredentials(profile: makeProfile(path: temporaryPath("restored.sqlite")), password: nil))
        _ = try await restored.connect()
        let summary = try await ScriptRunner().run(
            fileAt: dumpURL,
            using: restored,
            kind: .sqlite,
            stopOnError: true
        ) { _ in }

        #expect(summary.failures.isEmpty)
        #expect(summary.succeeded == summary.total)

        let users = try await restored.execute("SELECT id, name, email, age, balance, bio FROM users ORDER BY id")
        let rows = try #require(users.first?.rows)
        #expect(rows.count == 3)
        #expect(rows[0][1].stringValue == "Ada Lovelace")
        #expect(rows[0][4].stringValue == "1250.75")
        #expect(rows[2][4].isNull)
        #expect(rows[2][5].isNull)

        let orders = try await restored.execute("SELECT COUNT(*) FROM orders")
        #expect(orders.first?.rows.first?[0].stringValue == "2")

        await restored.disconnect()
    }

    @Test("Generated row edits round-trip through the database")
    func rowEditsApply() async throws {
        let driver = SQLiteDriver(credentials: ConnectionCredentials(profile: makeProfile(path: temporaryPath("e.sqlite")), password: nil))
        _ = try await driver.connect()
        try await seed(driver)

        let table = TableRef(database: "main", name: "users")
        let planner = RowEditPlanner(kind: .sqlite, table: table, keyColumns: ["id"])
        let planned = try planner.plan([
            .update(rowID: 0, changes: ["name": .text("Ada L.")], original: ["id": .text("1")]),
            .update(rowID: 1, changes: ["bio": .null], original: ["id": .text("2")]),
            .delete(rowID: 2, original: ["id": .text("3")])
        ])

        for statement in planned {
            _ = try await driver.execute(statement.sql)
        }

        let result = try await driver.execute("SELECT id, name, bio FROM users ORDER BY id")
        let rows = try #require(result.first?.rows)
        #expect(rows.count == 2)
        #expect(rows[0][1].stringValue == "Ada L.")
        #expect(rows[1][2].isNull)

        await driver.disconnect()
    }

    @Test("CSV import inserts the mapped columns")
    func csvImport() async throws {
        let driver = SQLiteDriver(credentials: ConnectionCredentials(profile: makeProfile(path: temporaryPath("f.sqlite")), password: nil))
        _ = try await driver.connect()
        try await seed(driver)

        let csvURL = URL(fileURLWithPath: temporaryPath("people.csv"))
        try """
        name,email,age
        Katherine Johnson,katherine@example.com,101
        "Hamilton, Margaret",margaret@example.com,88
        """.write(to: csvURL, atomically: true, encoding: .utf8)

        let statements = try CSVImporter().statements(
            fileAt: csvURL,
            table: TableRef(database: "main", name: "users"),
            kind: .sqlite,
            options: CSVImportOptions()
        )
        for statement in statements {
            _ = try await driver.execute(statement)
        }

        let result = try await driver.execute("SELECT name FROM users WHERE age > 80 ORDER BY age")
        let names = result.first?.rows.map { $0[0].stringValue } ?? []
        #expect(names == ["Grace Hopper", "Hamilton, Margaret", "Katherine Johnson"])

        await driver.disconnect()
    }
}

/// Closes the loop between the URL parser and the drivers: a pasted connection string has
/// to produce a profile that actually opens.
@Suite("Connecting from a URL", .serialized)
struct ConnectionURLIntegrationTests {

    @Test("A SQLite URL produces a profile that connects and queries")
    func sqliteURLConnects() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miesql-url-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("from-url.sqlite").path

        let parsed = try ConnectionURLParser.parse("sqlite://\(path)")
        #expect(parsed.profile.kind == .sqlite)
        #expect(parsed.profile.filePath == path)

        let driver = SQLiteDriver(credentials: ConnectionCredentials(profile: parsed.profile, password: parsed.password))
        let info = try await driver.connect()
        #expect(info.productName == "SQLite")

        _ = try await driver.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, label TEXT); INSERT INTO t (label) VALUES ('ok');")
        let result = try await driver.execute("SELECT label FROM t")
        #expect(result.first?.rows.first?[0].stringValue == "ok")

        await driver.disconnect()
    }

    @Test("A read-only URL parameter reaches the driver")
    func readOnlyURLIsEnforced() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miesql-url-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("ro.sqlite").path

        let writable = SQLiteDriver(credentials: ConnectionCredentials(
            profile: ConnectionProfile(kind: .sqlite, filePath: path), password: nil
        ))
        _ = try await writable.connect()
        _ = try await writable.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        await writable.disconnect()

        let parsed = try ConnectionURLParser.parse("sqlite://\(path)?mode=ro")
        #expect(parsed.profile.readOnly)

        let guarded = SQLiteDriver(credentials: ConnectionCredentials(profile: parsed.profile, password: parsed.password))
        _ = try await guarded.connect()
        await #expect(throws: DatabaseError.self) {
            _ = try await guarded.execute("DROP TABLE t")
        }
        await guarded.disconnect()
    }

    @Test("Credentials survive the round trip into a profile")
    func credentialsReachTheProfile() throws {
        let parsed = try ConnectionURLParser.parse("postgres://ada:p@ss word@db.example.com:6432/analytics?sslmode=require")
        let credentials = ConnectionCredentials(profile: parsed.profile, password: parsed.password)

        #expect(credentials.profile.username == "ada")
        #expect(credentials.profile.host == "db.example.com")
        #expect(credentials.profile.port == 6432)
        #expect(credentials.profile.database == "analytics")
        #expect(credentials.profile.sslMode == .require)
        #expect(credentials.password == "p@ss word")
        // A URL that carries a password opts into the Keychain by default.
        #expect(credentials.profile.savePassword)
        #expect(credentials.profile.validationError == nil)
    }
}
