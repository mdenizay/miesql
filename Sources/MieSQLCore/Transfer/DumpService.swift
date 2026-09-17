import Foundation

public struct DumpOptions: Sendable {
    public var includeSchema: Bool
    public var includeData: Bool
    public var dropIfExists: Bool
    /// Wraps the data section in a transaction so a failed restore leaves nothing behind.
    public var wrapInTransaction: Bool
    /// Rows per multi-row INSERT. 1 produces one statement per row, which is slower to
    /// restore but much easier to diff.
    public var rowsPerInsert: Int
    /// How many rows to hold in memory at once while reading.
    public var fetchBatchSize: Int
    public var addHeaderComment: Bool

    public init(
        includeSchema: Bool = true,
        includeData: Bool = true,
        dropIfExists: Bool = false,
        wrapInTransaction: Bool = true,
        rowsPerInsert: Int = 100,
        fetchBatchSize: Int = 1_000,
        addHeaderComment: Bool = true
    ) {
        self.includeSchema = includeSchema
        self.includeData = includeData
        self.dropIfExists = dropIfExists
        self.wrapInTransaction = wrapInTransaction
        self.rowsPerInsert = rowsPerInsert
        self.fetchBatchSize = fetchBatchSize
        self.addHeaderComment = addHeaderComment
    }
}

public struct DumpProgress: Sendable {
    public let currentTable: String
    public let tableIndex: Int
    public let tableCount: Int
    public let rowsWritten: Int
    public let bytesWritten: Int

    public var fraction: Double {
        tableCount == 0 ? 0 : Double(tableIndex) / Double(tableCount)
    }
}

/// Writes a `.sql` file that can recreate the selected tables. Output is streamed to disk
/// in batches, so dumping a table larger than RAM works.
public struct DumpService: Sendable {

    public init() {}

    public func dump(
        tables: [TableRef],
        using driver: any DatabaseDriver,
        kind: DatabaseKind,
        options: DumpOptions,
        to url: URL,
        progress: @Sendable @escaping (DumpProgress) -> Void
    ) async throws {
        let dialect = SQLDialect(kind: kind)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw DatabaseError(message: "Could not open \(url.lastPathComponent) for writing.")
        }
        defer { try? handle.close() }

        var bytesWritten = 0
        func write(_ text: String) throws {
            guard let data = text.data(using: .utf8) else { return }
            try handle.write(contentsOf: data)
            bytesWritten += data.count
        }

        if options.addHeaderComment {
            let formatter = ISO8601DateFormatter()
            try write("""
            -- MieSQL dump
            -- Engine: \(kind.displayName)
            -- Generated: \(formatter.string(from: Date()))
            -- Tables: \(tables.count)

            """)
        }

        // Constraint checks are relaxed for the whole restore so table order cannot matter.
        switch kind {
        case .mysql, .mariadb:
            try write("SET FOREIGN_KEY_CHECKS = 0;\n\n")
        case .sqlite:
            try write("PRAGMA foreign_keys = OFF;\n\n")
        case .postgres:
            try write("SET session_replication_role = 'replica';\n\n")
        }

        if options.wrapInTransaction {
            try write("BEGIN;\n\n")
        }

        var totalRows = 0
        for (index, table) in tables.enumerated() {
            try Task.checkCancellation()
            progress(DumpProgress(
                currentTable: table.qualifiedName,
                tableIndex: index,
                tableCount: tables.count,
                rowsWritten: totalRows,
                bytesWritten: bytesWritten
            ))

            try write("-- ----------------------------\n-- \(table.qualifiedName)\n-- ----------------------------\n")

            if options.includeSchema {
                if options.dropIfExists {
                    let keyword = table.kind == .table ? "TABLE" : "VIEW"
                    try write("DROP \(keyword) IF EXISTS \(dialect.qualified(table));\n")
                }
                let ddl = try await driver.createStatement(for: table)
                try write(ddl.hasSuffix(";") ? ddl + "\n\n" : ddl + ";\n\n")
            }

            if options.includeData, table.kind == .table {
                let details = try await driver.describe(table: table)
                let rows = try await writeData(
                    table: table,
                    details: details,
                    driver: driver,
                    dialect: dialect,
                    options: options,
                    write: write
                )
                totalRows += rows
                try write("\n")
            }
        }

        if options.wrapInTransaction {
            try write("COMMIT;\n")
        }

        switch kind {
        case .mysql, .mariadb:
            try write("\nSET FOREIGN_KEY_CHECKS = 1;\n")
        case .sqlite:
            try write("\nPRAGMA foreign_keys = ON;\n")
        case .postgres:
            try write("\nSET session_replication_role = 'origin';\n")
        }

        progress(DumpProgress(
            currentTable: "",
            tableIndex: tables.count,
            tableCount: tables.count,
            rowsWritten: totalRows,
            bytesWritten: bytesWritten
        ))
    }

    private func writeData(
        table: TableRef,
        details: TableDetails,
        driver: any DatabaseDriver,
        dialect: SQLDialect,
        options: DumpOptions,
        write: (String) throws -> Void
    ) async throws -> Int {
        // Paging needs a stable order; the primary key is the natural choice, and without
        // one we fall back to the first column so repeated pages do not overlap.
        let orderColumns = details.primaryKeyColumns.isEmpty
            ? Array(details.columns.prefix(1).map(\.name))
            : details.primaryKeyColumns
        let order = orderColumns.map { (column: $0, ascending: true) }

        var offset = 0
        var written = 0
        var pending: [String] = []
        var columnList = ""
        var columns: [ColumnInfo] = []

        func flush() throws {
            guard !pending.isEmpty else { return }
            try write("INSERT INTO \(dialect.qualified(table)) (\(columnList)) VALUES\n")
            try write(pending.joined(separator: ",\n"))
            try write(";\n")
            pending.removeAll(keepingCapacity: true)
        }

        while true {
            try Task.checkCancellation()
            let page = try await driver.fetchRows(
                table: table,
                orderBy: order,
                limit: options.fetchBatchSize,
                offset: offset
            )
            if page.rows.isEmpty { break }

            if columns.isEmpty {
                columns = page.columns
                columnList = columns.map { dialect.quote($0.name) }.joined(separator: ", ")
            }

            for row in page.rows {
                let values = columns.indices.map { index -> String in
                    literal(row[index], column: index < columns.count ? columns[index] : nil, dialect: dialect)
                }
                pending.append("  (\(values.joined(separator: ", ")))")
                written += 1
                if pending.count >= options.rowsPerInsert {
                    try flush()
                }
            }

            offset += page.rows.count
            if page.rows.count < options.fetchBatchSize { break }
        }

        try flush()
        return written
    }

    /// Numbers and binary blobs are written unquoted so a restore round-trips exactly.
    private func literal(_ value: SQLValue, column: ColumnInfo?, dialect: SQLDialect) -> String {
        guard case .text(let string) = value else { return "NULL" }

        if let column {
            let type = column.typeName.lowercased()
            if type.contains("blob") || type.contains("bytea") || type.contains("binary") {
                if string.hasPrefix("X'") || string.hasPrefix("x'") { return string }
                if string.hasPrefix("\\x") {
                    return dialect.blobLiteral(String(string.dropFirst(2)))
                }
            }
            if column.isNumeric, Double(string) != nil {
                return string
            }
            if type.contains("bool") {
                let lowered = string.lowercased()
                if ["true", "false", "t", "f", "0", "1"].contains(lowered) {
                    return dialect.kind == .sqlite
                        ? (["true", "t", "1"].contains(lowered) ? "1" : "0")
                        : (["true", "t", "1"].contains(lowered) ? "TRUE" : "FALSE")
                }
            }
        }
        return dialect.stringLiteral(string)
    }
}
