import Foundation
import SQLite3

/// SQLite talks to the C library directly — there is no server, so there is nothing to
/// pool or reconnect. Everything runs inside the actor, which keeps the single `sqlite3`
/// handle to one thread at a time as the library expects.
public actor SQLiteDriver: DatabaseDriver {
    public nonisolated let kind: DatabaseKind = .sqlite

    private let credentials: ConnectionCredentials
    private var handle: OpaquePointer?

    /// SQLite has no real database list, so the tree shows one fixed node.
    public static let mainDatabase = "main"

    public init(credentials: ConnectionCredentials) {
        self.credentials = credentials
    }

    public var isConnected: Bool { handle != nil }

    // MARK: - Lifecycle

    public func connect() async throws -> ServerInfo {
        let path = credentials.profile.filePath
        guard !path.isEmpty else {
            throw DatabaseError(message: "No database file was selected.")
        }

        let flags = credentials.profile.readOnly
            ? SQLITE_OPEN_READONLY
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE

        var newHandle: OpaquePointer?
        let status = sqlite3_open_v2(path, &newHandle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let newHandle else {
            let message = newHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open \(path)."
            if newHandle != nil { sqlite3_close_v2(newHandle) }
            throw DatabaseError(message: message, code: "SQLITE_\(status)")
        }
        handle = newHandle

        // Foreign keys are off by default; a database client should honour the schema's
        // declared constraints rather than silently letting the user break them.
        _ = try? runSingle("PRAGMA foreign_keys = ON")

        let version = try scalar("SELECT sqlite_version()") ?? "unknown"
        return ServerInfo(
            productName: "SQLite",
            version: version,
            currentDatabase: (path as NSString).lastPathComponent,
            currentUser: NSUserName()
        )
    }

    public func disconnect() async {
        guard let handle else { return }
        self.handle = nil
        sqlite3_close_v2(handle)
    }

    /// Nothing to switch: a SQLite connection is a file.
    public func use(database: String) async throws {}

    // MARK: - Query execution

    public func execute(_ sql: String) async throws -> [QueryResult] {
        let statements = SQLStatementSplitter.split(sql, kind: .sqlite)
        guard !statements.isEmpty else { return [] }

        var results: [QueryResult] = []
        for statement in statements {
            try guardReadOnly(statement.text)
            results.append(try runSingle(statement.text))
        }
        return results
    }

    private func runSingle(_ sql: String) throws -> QueryResult {
        guard let handle else {
            throw DatabaseError(message: "Not connected.")
        }

        let started = Date()
        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepareStatus == SQLITE_OK, let statement else {
            throw currentError(handle)
        }
        defer { sqlite3_finalize(statement) }

        let columnCount = Int(sqlite3_column_count(statement))
        var columns: [ColumnInfo] = []
        columns.reserveCapacity(columnCount)
        for index in 0..<columnCount {
            let name = sqlite3_column_name(statement, Int32(index)).map { String(cString: $0) } ?? "column\(index + 1)"
            let declared = sqlite3_column_decltype(statement, Int32(index)).map { String(cString: $0) }
            let table = sqlite3_column_table_name(statement, Int32(index)).map { String(cString: $0) }
            columns.append(ColumnInfo(
                index: index,
                name: name,
                typeName: declared ?? "",
                tableName: table
            ))
        }

        var rows: [ResultRow] = []
        var rowIndex = 0
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                var values: [SQLValue] = []
                values.reserveCapacity(columnCount)
                for index in 0..<columnCount {
                    values.append(value(of: statement, at: Int32(index)))
                }
                rows.append(ResultRow(id: rowIndex, values: values))
                rowIndex += 1
                continue
            }
            if status == SQLITE_DONE { break }
            throw currentError(handle)
        }

        // `sqlite3_column_decltype` is empty for expressions, so fall back to the runtime
        // type of the first row, which is what the grid needs for alignment.
        if !rows.isEmpty {
            columns = columns.enumerated().map { index, column in
                guard column.typeName.isEmpty else { return column }
                return ColumnInfo(
                    index: column.index,
                    name: column.name,
                    typeName: runtimeTypeName(rows[0][index]),
                    tableName: column.tableName
                )
            }
        }

        let duration = Date().timeIntervalSince(started)
        let isRead = SQLDialect.isReadOnlyStatement(sql)
        return QueryResult(
            statement: sql,
            columns: columnCount > 0 ? columns : [],
            rows: rows,
            rowsAffected: (columnCount == 0 && !isRead) ? Int(sqlite3_changes(handle)) : nil,
            duration: duration
        )
    }

    private func value(of statement: OpaquePointer, at index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return .null
        case SQLITE_BLOB:
            guard let pointer = sqlite3_column_blob(statement, index) else { return .text("") }
            let length = Int(sqlite3_column_bytes(statement, index))
            let bytes = Data(bytes: pointer, count: length)
            return .text("X'" + bytes.map { String(format: "%02X", $0) }.joined() + "'")
        default:
            guard let text = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: text))
        }
    }

    private func runtimeTypeName(_ value: SQLValue) -> String {
        switch value {
        case .null: return ""
        case .text(let string):
            if string.hasPrefix("X'") { return "BLOB" }
            if Int(string) != nil { return "INTEGER" }
            if Double(string) != nil { return "REAL" }
            return "TEXT"
        }
    }

    private func guardReadOnly(_ sql: String) throws {
        guard credentials.profile.readOnly, !SQLDialect.isReadOnlyStatement(sql) else { return }
        throw DatabaseError(
            message: "This connection is marked read-only. \(SQLDialect.leadingKeyword(of: sql).uppercased()) statements are blocked.",
            code: "MIESQL_READONLY"
        )
    }

    private func scalar(_ sql: String) throws -> String? {
        let result = try runSingle(sql)
        guard let value = result.rows.first?.values.first, !value.isNull else { return nil }
        return value.stringValue
    }

    private func currentError(_ handle: OpaquePointer) -> DatabaseError {
        DatabaseError(
            message: String(cString: sqlite3_errmsg(handle)),
            code: "SQLITE_\(sqlite3_extended_errcode(handle))"
        )
    }

    // MARK: - Schema introspection

    public func listDatabases() async throws -> [String] {
        // `PRAGMA database_list` also reports anything the user has ATTACHed.
        let result = try runSingle("PRAGMA database_list")
        let names = result.rows.compactMap { row -> String? in
            guard row.values.count > 1 else { return nil }
            return row.values[1].stringValue
        }
        return names.isEmpty ? [Self.mainDatabase] : names
    }

    public func listSchemas(database: String) async throws -> [String] { [] }

    public func listTables(in ref: SchemaRef) async throws -> [TableRef] {
        let dialect = SQLDialect(kind: .sqlite)
        let schemaPrefix = ref.database.isEmpty ? Self.mainDatabase : ref.database
        let result = try runSingle("""
        SELECT name, type FROM \(dialect.quote(schemaPrefix)).sqlite_master
        WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'
        ORDER BY name
        """)

        return result.rows.compactMap { row in
            guard let name = row.values.first?.stringValue else { return nil }
            let type = row.values.count > 1 ? row.values[1].stringValue : "table"
            return TableRef(database: schemaPrefix, schema: "", name: name, kind: type == "view" ? .view : .table)
        }
    }

    public func describe(table: TableRef) async throws -> TableDetails {
        let dialect = SQLDialect(kind: .sqlite)
        let quoted = dialect.quote(table.name)

        let columnRows = try runSingle("PRAGMA table_info(\(quoted))")
        let columns = columnRows.rows.map { row -> ColumnDefinition in
            // cid, name, type, notnull, dflt_value, pk
            ColumnDefinition(
                name: row[1].stringValue,
                dataType: row[2].stringValue,
                isNullable: row[3].stringValue != "1",
                defaultValue: row[4].isNull ? nil : row[4].stringValue,
                isPrimaryKey: row[5].stringValue != "0",
                isAutoIncrement: false,
                comment: nil,
                ordinalPosition: (Int(row[0].stringValue) ?? 0) + 1
            )
        }

        let indexListRows = try runSingle("PRAGMA index_list(\(quoted))")
        var indexes: [IndexDefinition] = []
        for row in indexListRows.rows {
            // seq, name, unique, origin, partial
            let name = row[1].stringValue
            let indexColumns = try runSingle("PRAGMA index_info(\(dialect.quote(name)))")
            indexes.append(IndexDefinition(
                name: name,
                columns: indexColumns.rows.map { $0[2].stringValue },
                isUnique: row[2].stringValue == "1",
                isPrimary: row[3].stringValue == "pk",
                method: nil
            ))
        }

        let foreignKeyRows = try runSingle("PRAGMA foreign_key_list(\(quoted))")
        var keyOrder: [String] = []
        var keyBuckets: [String: ForeignKeyDefinition] = [:]
        for row in foreignKeyRows.rows {
            // id, seq, table, from, to, on_update, on_delete, match
            let identifier = row[0].stringValue
            let name = "fk_\(table.name)_\(identifier)"
            if var existing = keyBuckets[name] {
                existing.columns.append(row[3].stringValue)
                existing.referencedColumns.append(row[4].stringValue)
                keyBuckets[name] = existing
            } else {
                keyOrder.append(name)
                keyBuckets[name] = ForeignKeyDefinition(
                    name: name,
                    columns: [row[3].stringValue],
                    referencedTable: row[2].stringValue,
                    referencedColumns: [row[4].stringValue],
                    onDelete: row[6].stringValue,
                    onUpdate: row[5].stringValue
                )
            }
        }

        let countResult = try? runSingle("SELECT COUNT(*) FROM \(quoted)")
        let rowCount = countResult?.rows.first?.values.first.flatMap { Int($0.stringValue) }

        return TableDetails(
            table: table,
            columns: columns,
            indexes: indexes,
            foreignKeys: keyOrder.compactMap { keyBuckets[$0] },
            estimatedRowCount: rowCount,
            comment: nil
        )
    }

    public func createStatement(for table: TableRef) async throws -> String {
        let dialect = SQLDialect(kind: .sqlite)
        let result = try runSingle("""
        SELECT sql FROM sqlite_master WHERE name = \(dialect.stringLiteral(table.name))
        """)
        guard let sql = result.rows.first?.values.first?.stringValue, !sql.isEmpty else {
            throw DatabaseError(message: "No CREATE statement is stored for \(table.name).")
        }
        var output = sql.hasSuffix(";") ? sql : sql + ";"

        let indexResult = try runSingle("""
        SELECT sql FROM sqlite_master
        WHERE type = 'index' AND tbl_name = \(dialect.stringLiteral(table.name)) AND sql IS NOT NULL
        ORDER BY name
        """)
        for row in indexResult.rows {
            let indexSQL = row.values.first?.stringValue ?? ""
            if !indexSQL.isEmpty {
                output += "\n\n" + (indexSQL.hasSuffix(";") ? indexSQL : indexSQL + ";")
            }
        }
        return output
    }
}
