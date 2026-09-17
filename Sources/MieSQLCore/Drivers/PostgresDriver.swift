import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import PostgresNIO

/// PostgreSQL connection. One actor per open connection, so several databases can be
/// queried at the same time without any shared mutable state between them.
public actor PostgresDriver: DatabaseDriver {
    public nonisolated let kind: DatabaseKind = .postgres

    private let credentials: ConnectionCredentials
    private var connection: PostgresConnection?
    private var activeDatabase: String
    private let logger = Logger(label: "app.miesql.postgres")

    public init(credentials: ConnectionCredentials) {
        self.credentials = credentials
        self.activeDatabase = credentials.profile.database
    }

    public var isConnected: Bool { connection?.isClosed == false }

    // MARK: - Lifecycle

    public func connect() async throws -> ServerInfo {
        try await openConnection(database: activeDatabase.isEmpty ? "postgres" : activeDatabase)

        let version = try await scalar("SHOW server_version") ?? "unknown"
        let database = try await scalar("SELECT current_database()") ?? activeDatabase
        let user = try await scalar("SELECT current_user") ?? credentials.profile.username
        activeDatabase = database

        return ServerInfo(
            productName: "PostgreSQL",
            version: version,
            currentDatabase: database,
            currentUser: user
        )
    }

    private func openConnection(database: String) async throws {
        let profile = credentials.profile

        // libpq's `require` encrypts but does not validate the certificate; `verify-*` modes
        // are what add validation. Matching that keeps local and containerised servers usable.
        var tls: PostgresConnection.Configuration.TLS = .disable
        if profile.sslMode != .disable {
            var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            tlsConfiguration.certificateVerification = .none
            let context = try NIOSSLContext(configuration: tlsConfiguration)
            tls = profile.sslMode == .require ? .require(context) : .prefer(context)
        }

        var configuration = PostgresConnection.Configuration(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            password: credentials.password,
            database: database,
            tls: tls
        )
        configuration.options.connectTimeout = .seconds(Int64(profile.connectTimeoutSeconds))

        do {
            connection = try await PostgresConnection.connect(
                on: MultiThreadedEventLoopGroup.singleton.any(),
                configuration: configuration,
                id: 1,
                logger: logger
            )
            activeDatabase = database
        } catch {
            throw Self.translate(error)
        }
    }

    public func disconnect() async {
        guard let connection else { return }
        self.connection = nil
        try? await connection.close()
    }

    /// PostgreSQL binds a connection to one database, so switching means reconnecting.
    public func use(database: String) async throws {
        guard database != activeDatabase else { return }
        await disconnect()
        try await openConnection(database: database)
    }

    // MARK: - Query execution

    public func execute(_ sql: String) async throws -> [QueryResult] {
        let statements = SQLStatementSplitter.split(sql, kind: .postgres)
        guard !statements.isEmpty else { return [] }

        var results: [QueryResult] = []
        for statement in statements {
            try guardReadOnly(statement.text)
            results.append(try await runSingle(statement.text))
        }
        return results
    }

    private func runSingle(_ sql: String) async throws -> QueryResult {
        guard let connection, !connection.isClosed else {
            throw DatabaseError(message: "Not connected.")
        }

        let started = Date()
        do {
            let future: EventLoopFuture<PostgresQueryResult> = connection.query(
                PostgresQuery(unsafeSQL: sql),
                logger: logger
            )
            let result = try await future.get()
            let duration = Date().timeIntervalSince(started)

            var columns: [ColumnInfo] = []
            var rows: [ResultRow] = []
            rows.reserveCapacity(result.rows.count)

            for (rowIndex, row) in result.rows.enumerated() {
                var values: [SQLValue] = []
                for cell in row {
                    if rowIndex == 0 {
                        columns.append(ColumnInfo(
                            index: cell.columnIndex,
                            name: cell.columnName,
                            typeName: Self.typeName(for: cell.dataType)
                        ))
                    }
                    values.append(PostgresValueRenderer.render(
                        bytes: cell.bytes,
                        dataType: cell.dataType,
                        format: cell.format
                    ))
                }
                rows.append(ResultRow(id: rowIndex, values: values))
            }

            // `rows` in the command tag counts touched rows for writes; for SELECT it just
            // repeats the row count, which would be misleading shown as "rows affected".
            let isSelect = result.metadata.command.uppercased() == "SELECT"
            return QueryResult(
                statement: sql,
                columns: columns,
                rows: rows,
                rowsAffected: isSelect ? nil : result.metadata.rows,
                duration: duration
            )
        } catch {
            throw Self.translate(error)
        }
    }

    private func guardReadOnly(_ sql: String) throws {
        guard credentials.profile.readOnly, !SQLDialect.isReadOnlyStatement(sql) else { return }
        throw DatabaseError(
            message: "This connection is marked read-only. \(SQLDialect.leadingKeyword(of: sql).uppercased()) statements are blocked.",
            code: "MIESQL_READONLY"
        )
    }

    private func scalar(_ sql: String) async throws -> String? {
        let result = try await runSingle(sql)
        return result.rows.first?.values.first?.stringValue
    }

    // MARK: - Schema introspection

    public func listDatabases() async throws -> [String] {
        let result = try await runSingle("""
        SELECT datname FROM pg_database
        WHERE datistemplate = false AND has_database_privilege(datname, 'CONNECT')
        ORDER BY datname
        """)
        return result.rows.compactMap { $0.values.first?.stringValue }
    }

    public func listSchemas(database: String) async throws -> [String] {
        try await use(database: database)
        let result = try await runSingle("""
        SELECT nspname FROM pg_namespace
        WHERE nspname NOT LIKE 'pg\\_%' AND nspname <> 'information_schema'
        ORDER BY nspname
        """)
        return result.rows.compactMap { $0.values.first?.stringValue }
    }

    public func listTables(in ref: SchemaRef) async throws -> [TableRef] {
        try await use(database: ref.database)
        let dialect = SQLDialect(kind: .postgres)
        let result = try await runSingle("""
        SELECT c.relname, c.relkind
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = \(dialect.stringLiteral(ref.schema))
          AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
        ORDER BY c.relname
        """)

        return result.rows.compactMap { row in
            guard let name = row.values.first?.stringValue else { return nil }
            let relkind = row.values.count > 1 ? row.values[1].stringValue : "r"
            let tableKind: TableKind
            switch relkind {
            case "v": tableKind = .view
            case "m": tableKind = .materializedView
            default: tableKind = .table
            }
            return TableRef(database: ref.database, schema: ref.schema, name: name, kind: tableKind)
        }
    }

    public func describe(table: TableRef) async throws -> TableDetails {
        try await use(database: table.database)
        let dialect = SQLDialect(kind: .postgres)
        let schemaLiteral = dialect.stringLiteral(table.schema)
        let tableLiteral = dialect.stringLiteral(table.name)
        let qualifiedLiteral = dialect.stringLiteral("\(table.schema).\(table.name)")

        let columnRows = try await runSingle("""
        SELECT
            a.attname,
            format_type(a.atttypid, a.atttypmod),
            NOT a.attnotnull,
            pg_get_expr(d.adbin, d.adrelid),
            COALESCE(pk.is_primary, false),
            a.attidentity <> '' OR pg_get_expr(d.adbin, d.adrelid) LIKE 'nextval%',
            col_description(a.attrelid, a.attnum),
            a.attnum
        FROM pg_attribute a
        LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
        LEFT JOIN (
            SELECT conrelid, unnest(conkey) AS attnum, true AS is_primary
            FROM pg_constraint WHERE contype = 'p'
        ) pk ON pk.conrelid = a.attrelid AND pk.attnum = a.attnum
        WHERE a.attrelid = \(qualifiedLiteral)::regclass
          AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum
        """)

        let columns = columnRows.rows.map { row -> ColumnDefinition in
            ColumnDefinition(
                name: row[0].stringValue,
                dataType: row[1].stringValue,
                isNullable: row[2].stringValue == "true",
                defaultValue: row[3].isNull ? nil : row[3].stringValue,
                isPrimaryKey: row[4].stringValue == "true",
                isAutoIncrement: row[5].stringValue == "true",
                comment: row[6].isNull ? nil : row[6].stringValue,
                ordinalPosition: Int(row[7].stringValue) ?? 0
            )
        }

        let indexRows = try await runSingle("""
        SELECT
            i.relname,
            ix.indisunique,
            ix.indisprimary,
            am.amname,
            pg_get_indexdef(ix.indexrelid)
        FROM pg_index ix
        JOIN pg_class i ON i.oid = ix.indexrelid
        JOIN pg_class t ON t.oid = ix.indrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_am am ON am.oid = i.relam
        WHERE n.nspname = \(schemaLiteral) AND t.relname = \(tableLiteral)
        ORDER BY i.relname
        """)

        let indexes = indexRows.rows.map { row -> IndexDefinition in
            IndexDefinition(
                name: row[0].stringValue,
                columns: Self.columnsFromIndexDefinition(row[4].stringValue),
                isUnique: row[1].stringValue == "true",
                isPrimary: row[2].stringValue == "true",
                method: row[3].stringValue
            )
        }

        let foreignKeyRows = try await runSingle("""
        SELECT
            con.conname,
            pg_get_constraintdef(con.oid)
        FROM pg_constraint con
        JOIN pg_class t ON t.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE con.contype = 'f' AND n.nspname = \(schemaLiteral) AND t.relname = \(tableLiteral)
        ORDER BY con.conname
        """)

        let foreignKeys = foreignKeyRows.rows.compactMap { row in
            Self.parseForeignKey(name: row[0].stringValue, definition: row[1].stringValue)
        }

        let estimate = try? await runSingle("""
        SELECT reltuples::bigint FROM pg_class WHERE oid = \(qualifiedLiteral)::regclass
        """)
        let rowCount = estimate?.rows.first?.values.first.flatMap { Int($0.stringValue) }

        let comment = try? await scalar("SELECT obj_description(\(qualifiedLiteral)::regclass)")

        return TableDetails(
            table: table,
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys,
            estimatedRowCount: rowCount.flatMap { $0 < 0 ? nil : $0 },
            comment: comment
        )
    }

    /// PostgreSQL has no `SHOW CREATE TABLE`, so the DDL is rebuilt from the catalog.
    public func createStatement(for table: TableRef) async throws -> String {
        let details = try await describe(table: table)
        let dialect = SQLDialect(kind: .postgres)

        if table.kind == .view || table.kind == .materializedView {
            let literal = dialect.stringLiteral("\(table.schema).\(table.name)")
            if let definition = try await scalar("SELECT pg_get_viewdef(\(literal)::regclass, true)") {
                let keyword = table.kind == .view ? "VIEW" : "MATERIALIZED VIEW"
                return "CREATE OR REPLACE \(keyword) \(dialect.qualified(table)) AS\n\(definition)"
            }
        }

        var lines: [String] = []
        for column in details.columns {
            var line = "    \(dialect.quote(column.name)) \(column.dataType)"
            if !column.isNullable { line += " NOT NULL" }
            if let defaultValue = column.defaultValue { line += " DEFAULT \(defaultValue)" }
            lines.append(line)
        }

        let primaryKey = details.primaryKeyColumns
        if !primaryKey.isEmpty {
            lines.append("    PRIMARY KEY (\(primaryKey.map(dialect.quote).joined(separator: ", ")))")
        }

        var sql = "CREATE TABLE \(dialect.qualified(table)) (\n" + lines.joined(separator: ",\n") + "\n);"

        for key in details.foreignKeys {
            sql += "\n\nALTER TABLE \(dialect.qualified(table)) ADD CONSTRAINT \(dialect.quote(key.name))"
            sql += " FOREIGN KEY (\(key.columns.map(dialect.quote).joined(separator: ", ")))"
            sql += " REFERENCES \(key.referencedTable) (\(key.referencedColumns.map(dialect.quote).joined(separator: ", ")));"
        }

        for index in details.indexes where !index.isPrimary {
            let unique = index.isUnique ? "UNIQUE " : ""
            sql += "\n\nCREATE \(unique)INDEX \(dialect.quote(index.name)) ON \(dialect.qualified(table))"
            sql += " (\(index.columns.map(dialect.quote).joined(separator: ", ")));"
        }

        return sql
    }

    // MARK: - Helpers

    /// `CREATE INDEX x ON t USING btree (a, b)` → `["a", "b"]`.
    static func columnsFromIndexDefinition(_ definition: String) -> [String] {
        guard let open = definition.lastIndex(of: "("), let close = definition.lastIndex(of: ")"), open < close else {
            return []
        }
        let inner = definition[definition.index(after: open)..<close]
        return inner.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }

    /// `FOREIGN KEY (a) REFERENCES other(b) ON DELETE CASCADE` → a structured definition.
    static func parseForeignKey(name: String, definition: String) -> ForeignKeyDefinition? {
        guard let keyOpen = definition.range(of: "("),
              let keyClose = definition.range(of: ")", range: keyOpen.upperBound..<definition.endIndex),
              let referencesRange = definition.range(of: "REFERENCES ") else { return nil }

        let columns = definition[keyOpen.upperBound..<keyClose.lowerBound]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }

        let tail = definition[referencesRange.upperBound...]
        guard let refOpen = tail.range(of: "("),
              let refClose = tail.range(of: ")", range: refOpen.upperBound..<tail.endIndex) else { return nil }

        let referencedTable = tail[tail.startIndex..<refOpen.lowerBound].trimmingCharacters(in: .whitespaces)
        let referencedColumns = tail[refOpen.upperBound..<refClose.lowerBound]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }

        func action(_ keyword: String) -> String? {
            guard let range = definition.range(of: "ON \(keyword) ") else { return nil }
            let rest = definition[range.upperBound...]
            let words = rest.split(separator: " ").prefix(2).joined(separator: " ")
            for candidate in ["NO ACTION", "SET NULL", "SET DEFAULT", "CASCADE", "RESTRICT"] where words.hasPrefix(candidate) {
                return candidate
            }
            return nil
        }

        return ForeignKeyDefinition(
            name: name,
            columns: columns,
            referencedTable: referencedTable,
            referencedColumns: referencedColumns,
            onDelete: action("DELETE"),
            onUpdate: action("UPDATE")
        )
    }

    static func translate(_ error: any Error) -> DatabaseError {
        if let error = error as? DatabaseError { return error }
        if let psql = error as? PSQLError {
            if let server = psql.serverInfo {
                return DatabaseError(
                    message: server[.message] ?? String(describing: psql.code),
                    code: server[.sqlState],
                    detail: [server[.detail], server[.hint]].compactMap { $0 }.joined(separator: "\n")
                )
            }
            return DatabaseError(message: "\(psql.code)", detail: psql.underlying?.localizedDescription)
        }
        return DatabaseError(message: error.localizedDescription)
    }

    /// Names for the OIDs the result grid is likely to meet. Anything else shows its OID,
    /// which is still more useful than a blank type column.
    static func typeName(for dataType: PostgresDataType) -> String {
        let names: [UInt32: String] = [
            16: "bool", 17: "bytea", 18: "char", 19: "name", 20: "int8", 21: "int2",
            23: "int4", 25: "text", 26: "oid", 114: "json", 142: "xml", 600: "point",
            650: "cidr", 700: "float4", 701: "float8", 705: "unknown", 790: "money",
            829: "macaddr", 869: "inet", 1000: "bool[]", 1005: "int2[]", 1007: "int4[]",
            1009: "text[]", 1015: "varchar[]", 1016: "int8[]", 1021: "float4[]",
            1022: "float8[]", 1042: "bpchar", 1043: "varchar", 1082: "date", 1083: "time",
            1114: "timestamp", 1184: "timestamptz", 1186: "interval", 1231: "numeric[]",
            1266: "timetz", 1560: "bit", 1562: "varbit", 1700: "numeric", 2950: "uuid",
            3802: "jsonb"
        ]
        if let name = names[dataType.rawValue] { return name }
        return dataType.isUserDefined ? "user-defined" : "oid:\(dataType.rawValue)"
    }
}
