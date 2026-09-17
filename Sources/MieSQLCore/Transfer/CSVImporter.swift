import Foundation

public struct CSVImportOptions: Sendable {
    public var delimiter: Character
    public var hasHeaderRow: Bool
    /// Text in the file that should become SQL NULL rather than an empty string.
    public var nullMarker: String
    public var rowsPerInsert: Int
    /// Maps CSV column index to target table column name. Unmapped columns are skipped.
    public var columnMapping: [Int: String]

    public init(
        delimiter: Character = ",",
        hasHeaderRow: Bool = true,
        nullMarker: String = "",
        rowsPerInsert: Int = 200,
        columnMapping: [Int: String] = [:]
    ) {
        self.delimiter = delimiter
        self.hasHeaderRow = hasHeaderRow
        self.nullMarker = nullMarker
        self.rowsPerInsert = rowsPerInsert
        self.columnMapping = columnMapping
    }
}

public struct CSVPreview: Sendable {
    public let header: [String]
    public let rows: [[String]]
    public let totalRowsScanned: Int
}

/// RFC 4180 reader plus an INSERT generator. Parsing and inserting are separate so the
/// import sheet can show a preview and a column mapping before anything touches the server.
public struct CSVImporter: Sendable {

    public init() {}

    public func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var field = ""
        var insideQuotes = false
        var iterator = text.startIndex

        while iterator < text.endIndex {
            let character = text[iterator]

            if insideQuotes {
                if character == "\"" {
                    let next = text.index(after: iterator)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        iterator = text.index(after: next)
                        continue
                    }
                    insideQuotes = false
                    iterator = next
                    continue
                }
                field.append(character)
                iterator = text.index(after: iterator)
                continue
            }

            switch character {
            case "\"" where field.isEmpty:
                insideQuotes = true
            case delimiter:
                currentRow.append(field)
                field = ""
            case "\r":
                break // handled by the \n that follows
            case "\n":
                currentRow.append(field)
                rows.append(currentRow)
                currentRow = []
                field = ""
            default:
                field.append(character)
            }
            iterator = text.index(after: iterator)
        }

        if !field.isEmpty || !currentRow.isEmpty {
            currentRow.append(field)
            rows.append(currentRow)
        }

        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    public func preview(fileAt url: URL, options: CSVImportOptions, maxRows: Int = 20) throws -> CSVPreview {
        let text = try readText(at: url)
        let rows = parse(text, delimiter: options.delimiter)
        guard !rows.isEmpty else { return CSVPreview(header: [], rows: [], totalRowsScanned: 0) }

        let header = options.hasHeaderRow
            ? rows[0]
            : rows[0].indices.map { "column\($0 + 1)" }
        let dataRows = options.hasHeaderRow ? Array(rows.dropFirst()) : rows
        return CSVPreview(
            header: header,
            rows: Array(dataRows.prefix(maxRows)),
            totalRowsScanned: dataRows.count
        )
    }

    /// Builds the INSERT statements for a parsed file. Returning statements rather than
    /// running them keeps the import reviewable before it is applied.
    public func statements(
        fileAt url: URL,
        table: TableRef,
        kind: DatabaseKind,
        options: CSVImportOptions
    ) throws -> [String] {
        let dialect = SQLDialect(kind: kind)
        let text = try readText(at: url)
        let rows = parse(text, delimiter: options.delimiter)
        guard !rows.isEmpty else { return [] }

        let dataRows = options.hasHeaderRow ? Array(rows.dropFirst()) : rows
        guard !dataRows.isEmpty else { return [] }

        let mapping = options.columnMapping.isEmpty
            ? defaultMapping(header: options.hasHeaderRow ? rows[0] : [])
            : options.columnMapping
        let orderedIndices = mapping.keys.sorted()
        guard !orderedIndices.isEmpty else {
            throw DatabaseError(message: "No CSV columns are mapped to table columns.")
        }

        let columnList = orderedIndices.compactMap { mapping[$0] }.map(dialect.quote).joined(separator: ", ")

        var statements: [String] = []
        var batch: [String] = []

        func flush() {
            guard !batch.isEmpty else { return }
            statements.append("INSERT INTO \(dialect.qualified(table)) (\(columnList)) VALUES\n" + batch.joined(separator: ",\n") + ";")
            batch.removeAll(keepingCapacity: true)
        }

        for row in dataRows {
            let values = orderedIndices.map { index -> String in
                guard index < row.count else { return "NULL" }
                let raw = row[index]
                return raw == options.nullMarker ? "NULL" : dialect.stringLiteral(raw)
            }
            batch.append("  (\(values.joined(separator: ", ")))")
            if batch.count >= options.rowsPerInsert { flush() }
        }
        flush()

        return statements
    }

    private func defaultMapping(header: [String]) -> [Int: String] {
        var mapping: [Int: String] = [:]
        for (index, name) in header.enumerated() where !name.isEmpty {
            mapping[index] = name
        }
        return mapping
    }

    private func readText(at url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) { return utf8 }
        if let latin = try? String(contentsOf: url, encoding: .isoLatin1) { return latin }
        throw DatabaseError(message: "Could not read \(url.lastPathComponent) as text.")
    }
}
