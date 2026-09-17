import Foundation
import Logging
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL

/// MySQL and MariaDB share a wire protocol, so one driver serves both. Queries go through
/// the text protocol (`COM_QUERY`), which means the server hands back every value already
/// formatted as text — exactly what the grid wants, and free of binary decoding surprises.
public actor MySQLDriver: DatabaseDriver {
    public nonisolated let kind: DatabaseKind

    private let credentials: ConnectionCredentials
    private var connection: MySQLConnection?
    private var activeDatabase: String
    private let logger = Logger(label: "app.miesql.mysql")

    public init(credentials: ConnectionCredentials) {
        self.credentials = credentials
        self.kind = credentials.profile.kind
        self.activeDatabase = credentials.profile.database
    }

    public var isConnected: Bool { connection?.isClosed == false }

    // MARK: - Lifecycle

    public func connect() async throws -> ServerInfo {
        let profile = credentials.profile

        var tlsConfiguration: TLSConfiguration?
        if profile.sslMode != .disable {
            var configuration = TLSConfiguration.makeClientConfiguration()
            // Self-signed certificates are the norm on development servers; validation is
            // opt-in through the server's own configuration rather than enforced here.
            configuration.certificateVerification = .none
            tlsConfiguration = configuration
        }

        do {
            let address = try SocketAddress.makeAddressResolvingHost(profile.host, port: profile.port)
            connection = try await MySQLConnection.connect(
                to: address,
                username: profile.username,
                database: profile.database,
                password: credentials.password,
                tlsConfiguration: tlsConfiguration,
                serverHostname: profile.host,
                logger: logger,
                on: MultiThreadedEventLoopGroup.singleton.any()
            ).get()
        } catch {
            throw Self.translate(error)
        }

        let version = try await scalar("SELECT VERSION()") ?? "unknown"
        let database = try await scalar("SELECT DATABASE()") ?? profile.database
        let user = try await scalar("SELECT CURRENT_USER()") ?? profile.username
        activeDatabase = database

        return ServerInfo(
            productName: version.lowercased().contains("mariadb") ? "MariaDB" : "MySQL",
            version: version,
            currentDatabase: database,
            currentUser: user
        )
    }

    public func disconnect() async {
        guard let connection else { return }
        self.connection = nil
        try? await connection.close().get()
    }

    public func use(database: String) async throws {
        guard database != activeDatabase, !database.isEmpty else { return }
        let dialect = SQLDialect(kind: kind)
        _ = try await runSingle("USE \(dialect.quote(database))")
        activeDatabase = database
    }

    // MARK: - Query execution

    public func execute(_ sql: String) async throws -> [QueryResult] {
        let statements = SQLStatementSplitter.split(sql, kind: kind)
        guard !statements.isEmpty else { return [] }

        var results: [QueryResult] = []
        for statement in statements {
            try guardReadOnly(statement.text)
            var result = try await runSingle(statement.text)

            // The text protocol does not report an affected-row count, so ask the server
            // for it right after any statement that could have changed something.
            if !result.hasResultSet, !SQLDialect.isReadOnlyStatement(statement.text) {
                if let affected = try? await scalar("SELECT ROW_COUNT()"), let count = Int(affected), count >= 0 {
                    result = QueryResult(
                        statement: result.statement,
                        columns: result.columns,
                        rows: result.rows,
                        rowsAffected: count,
                        duration: result.duration
                    )
                }
            }

            // Keep our idea of the active database in step with the user's own USE statements.
            if SQLDialect.leadingKeyword(of: statement.text) == "use" {
                activeDatabase = (try? await scalar("SELECT DATABASE()")) ?? activeDatabase
            }

            results.append(result)
        }
        return results
    }

    private func runSingle(_ sql: String) async throws -> QueryResult {
        guard let connection, !connection.isClosed else {
            throw DatabaseError(message: "Not connected.")
        }

        let started = Date()
        do {
            let rows = try await connection.simpleQuery(sql).get()
            let duration = Date().timeIntervalSince(started)

            var columns: [ColumnInfo] = []
            if let definitions = rows.first?.columnDefinitions {
                columns = definitions.enumerated().map { index, definition in
                    ColumnInfo(
                        index: index,
                        name: definition.name,
                        typeName: definition.columnType.name,
                        tableName: definition.table.isEmpty ? nil : definition.table
                    )
                }
            }

            let resultRows = rows.enumerated().map { index, row in
                ResultRow(id: index, values: row.values.map { buffer -> SQLValue in
                    guard var buffer else { return .null }
                    let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
                    return .text(String(decoding: bytes, as: UTF8.self))
                })
            }

            return QueryResult(
                statement: sql,
                columns: columns,
                rows: resultRows,
                rowsAffected: nil,
                duration: duration
            )
        } catch {
            throw Self.translate(error)
        }
    }

    private func guardReadOnly(_ sql: String) throws {
        guard credentials.profile.readOnly, !SQLDialect.isReadOnlyStatement(sql) else { return }
        // `USE` only changes the session, so it stays allowed on read-only connections.
        if SQLDialect.leadingKeyword(of: sql) == "use" { return }
        throw DatabaseError(
            message: "This connection is marked read-only. \(SQLDialect.leadingKeyword(of: sql).uppercased()) statements are blocked.",
            code: "MIESQL_READONLY"
        )
    }

    private func scalar(_ sql: String) async throws -> String? {
        let result = try await runSingle(sql)
        guard let value = result.rows.first?.values.first, !value.isNull else { return nil }
        return value.stringValue
    }

    // MARK: - Schema introspection

    public func listDatabases() async throws -> [String] {
        let result = try await runSingle("""
        SELECT SCHEMA_NAME FROM information_schema.SCHEMATA
        WHERE SCHEMA_NAME NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys')
        ORDER BY SCHEMA_NAME
        """)
        return result.rows.compactMap { $0.values.first?.stringValue }
    }

    /// MySQL has no level between database and table.
    public func listSchemas(database: String) async throws -> [String] { [] }

    public func listTables(in ref: SchemaRef) async throws -> [TableRef] {
        let dialect = SQLDialect(kind: kind)
        let result = try await runSingle("""
        SELECT TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = \(dialect.stringLiteral(ref.database))
        ORDER BY TABLE_NAME
        """)

        return result.rows.compactMap { row in
            guard let name = row.values.first?.stringValue else { return nil }
            let type = row.values.count > 1 ? row.values[1].stringValue.uppercased() : "BASE TABLE"
            return TableRef(
                database: ref.database,
                schema: "",
                name: name,
                kind: type.contains("VIEW") ? .view : .table
            )
        }
    }

    public func describe(table: TableRef) async throws -> TableDetails {
        let dialect = SQLDialect(kind: kind)
        let databaseLiteral = dialect.stringLiteral(table.database)
        let tableLiteral = dialect.stringLiteral(table.name)

        let columnRows = try await runSingle("""
        SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY, EXTRA,
               COLUMN_COMMENT, ORDINAL_POSITION
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = \(databaseLiteral) AND TABLE_NAME = \(tableLiteral)
        ORDER BY ORDINAL_POSITION
        """)

        let columns = columnRows.rows.map { row -> ColumnDefinition in
            ColumnDefinition(
                name: row[0].stringValue,
                dataType: row[1].stringValue,
                isNullable: row[2].stringValue.uppercased() == "YES",
                defaultValue: row[3].isNull ? nil : row[3].stringValue,
                isPrimaryKey: row[4].stringValue.uppercased() == "PRI",
                isAutoIncrement: row[5].stringValue.lowercased().contains("auto_increment"),
                comment: row[6].stringValue.isEmpty ? nil : row[6].stringValue,
                ordinalPosition: Int(row[7].stringValue) ?? 0
            )
        }

        let indexRows = try await runSingle("""
        SELECT INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME, INDEX_TYPE
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = \(databaseLiteral) AND TABLE_NAME = \(tableLiteral)
        ORDER BY INDEX_NAME, SEQ_IN_INDEX
        """)

        // information_schema returns one row per indexed column, so they are folded back
        // into one entry per index, keeping the column order the server reported.
        var indexOrder: [String] = []
        var indexBuckets: [String: IndexDefinition] = [:]
        for row in indexRows.rows {
            let name = row[0].stringValue
            let column = row[3].stringValue
            if var existing = indexBuckets[name] {
                existing.columns.append(column)
                indexBuckets[name] = existing
            } else {
                indexOrder.append(name)
                indexBuckets[name] = IndexDefinition(
                    name: name,
                    columns: [column],
                    isUnique: row[1].stringValue == "0",
                    isPrimary: name == "PRIMARY",
                    method: row[4].stringValue
                )
            }
        }
        let indexes = indexOrder.compactMap { indexBuckets[$0] }

        let foreignKeyRows = try await runSingle("""
        SELECT k.CONSTRAINT_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME,
               r.DELETE_RULE, r.UPDATE_RULE
        FROM information_schema.KEY_COLUMN_USAGE k
        JOIN information_schema.REFERENTIAL_CONSTRAINTS r
          ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
        WHERE k.TABLE_SCHEMA = \(databaseLiteral) AND k.TABLE_NAME = \(tableLiteral)
          AND k.REFERENCED_TABLE_NAME IS NOT NULL
        ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION
        """)

        var keyOrder: [String] = []
        var keyBuckets: [String: ForeignKeyDefinition] = [:]
        for row in foreignKeyRows.rows {
            let name = row[0].stringValue
            if var existing = keyBuckets[name] {
                existing.columns.append(row[1].stringValue)
                existing.referencedColumns.append(row[3].stringValue)
                keyBuckets[name] = existing
            } else {
                keyOrder.append(name)
                keyBuckets[name] = ForeignKeyDefinition(
                    name: name,
                    columns: [row[1].stringValue],
                    referencedTable: row[2].stringValue,
                    referencedColumns: [row[3].stringValue],
                    onDelete: row[4].stringValue,
                    onUpdate: row[5].stringValue
                )
            }
        }

        let statsRow = try? await runSingle("""
        SELECT TABLE_ROWS, TABLE_COMMENT FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = \(databaseLiteral) AND TABLE_NAME = \(tableLiteral)
        """)
        let estimatedRows = statsRow?.rows.first.flatMap { Int($0[0].stringValue) }
        let comment = statsRow?.rows.first.map { $0[1].stringValue }

        return TableDetails(
            table: table,
            columns: columns,
            indexes: indexes,
            foreignKeys: keyOrder.compactMap { keyBuckets[$0] },
            estimatedRowCount: estimatedRows,
            comment: (comment?.isEmpty ?? true) ? nil : comment
        )
    }

    public func createStatement(for table: TableRef) async throws -> String {
        let dialect = SQLDialect(kind: kind)
        let qualified = dialect.quoteQualified([table.database, table.name])
        let keyword = table.kind == .view ? "VIEW" : "TABLE"
        let result = try await runSingle("SHOW CREATE \(keyword) \(qualified)")
        // SHOW CREATE returns (name, statement); the statement is the second column.
        guard let row = result.rows.first, row.values.count > 1 else {
            throw DatabaseError(message: "The server did not return a CREATE statement for \(table.name).")
        }
        return row.values[1].stringValue + ";"
    }

    // MARK: - Errors

    static func translate(_ error: any Error) -> DatabaseError {
        if let error = error as? DatabaseError { return error }
        if let mysql = error as? MySQLError {
            switch mysql {
            case .server(let packet):
                return DatabaseError(
                    message: packet.errorMessage,
                    code: packet.sqlState ?? String(packet.errorCode.rawValue)
                )
            case .duplicateEntry(let message):
                return DatabaseError(message: message, code: "1062")
            case .invalidSyntax(let message):
                return DatabaseError(message: message, code: "1064")
            case .secureConnectionRequired:
                return DatabaseError(
                    message: "This server requires an encrypted connection.",
                    detail: "Set SSL to Prefer or Require in the connection settings. MySQL 8 accounts using caching_sha2_password cannot authenticate over a plaintext socket."
                )
            case .unsupportedAuthPlugin(let name):
                return DatabaseError(
                    message: "Unsupported authentication plugin: \(name).",
                    detail: "Switch the account to mysql_native_password, or enable SSL so caching_sha2_password can complete."
                )
            default:
                return DatabaseError(message: mysql.description)
            }
        }
        return DatabaseError(message: error.localizedDescription)
    }
}
