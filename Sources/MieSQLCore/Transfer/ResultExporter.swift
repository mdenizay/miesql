import Foundation

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv
    case tsv
    case json
    case sqlInsert
    case markdown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .csv: return "CSV"
        case .tsv: return "TSV"
        case .json: return "JSON"
        case .sqlInsert: return "SQL INSERT"
        case .markdown: return "Markdown"
        }
    }

    public var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .tsv: return "tsv"
        case .json: return "json"
        case .sqlInsert: return "sql"
        case .markdown: return "md"
        }
    }
}

public struct ExportOptions: Sendable {
    public var format: ExportFormat
    public var includeHeader: Bool
    /// Text written in place of NULL. Empty means an empty field, which is the CSV convention.
    public var nullPlaceholder: String
    public var delimiter: String
    /// Table name used when generating INSERT statements.
    public var tableName: String
    public var kind: DatabaseKind

    public init(
        format: ExportFormat = .csv,
        includeHeader: Bool = true,
        nullPlaceholder: String = "",
        delimiter: String = ",",
        tableName: String = "exported_data",
        kind: DatabaseKind = .postgres
    ) {
        self.format = format
        self.includeHeader = includeHeader
        self.nullPlaceholder = nullPlaceholder
        self.delimiter = delimiter
        self.tableName = tableName
        self.kind = kind
    }
}

/// Turns a result set into a file. Used by "Export result", "Copy as…" and the dumper.
public enum ResultExporter {

    public static func export(_ result: QueryResult, options: ExportOptions) -> String {
        export(columns: result.columns, rows: result.rows, options: options)
    }

    public static func export(columns: [ColumnInfo], rows: [ResultRow], options: ExportOptions) -> String {
        switch options.format {
        case .csv:
            return delimited(columns: columns, rows: rows, delimiter: options.delimiter, options: options)
        case .tsv:
            return delimited(columns: columns, rows: rows, delimiter: "\t", options: options)
        case .json:
            return json(columns: columns, rows: rows)
        case .sqlInsert:
            return sqlInserts(columns: columns, rows: rows, options: options)
        case .markdown:
            return markdown(columns: columns, rows: rows, options: options)
        }
    }

    // MARK: - Formats

    private static func delimited(columns: [ColumnInfo], rows: [ResultRow], delimiter: String, options: ExportOptions) -> String {
        var lines: [String] = []
        if options.includeHeader {
            lines.append(columns.map { escapeDelimited($0.name, delimiter: delimiter) }.joined(separator: delimiter))
        }
        for row in rows {
            let fields = columns.indices.map { index -> String in
                let value = row[index]
                let text = value.isNull ? options.nullPlaceholder : value.stringValue
                return escapeDelimited(text, delimiter: delimiter)
            }
            lines.append(fields.joined(separator: delimiter))
        }
        return lines.joined(separator: "\n")
    }

    /// RFC 4180 quoting: wrap in quotes when the field contains the delimiter, a quote or a
    /// newline, and double any embedded quote.
    private static func escapeDelimited(_ value: String, delimiter: String) -> String {
        let needsQuoting = value.contains(delimiter)
            || value.contains("\"")
            || value.contains("\n")
            || value.contains("\r")
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func json(columns: [ColumnInfo], rows: [ResultRow]) -> String {
        var objects: [String] = []
        for row in rows {
            var pairs: [String] = []
            for column in columns {
                let value = row[column.index]
                let rendered: String
                if value.isNull {
                    rendered = "null"
                } else {
                    rendered = jsonString(value.stringValue)
                }
                pairs.append("\(jsonString(column.name)): \(rendered)")
            }
            objects.append("  {\(pairs.joined(separator: ", "))}")
        }
        return "[\n" + objects.joined(separator: ",\n") + "\n]"
    }

    private static func jsonString(_ value: String) -> String {
        var output = "\""
        for character in value.unicodeScalars {
            switch character {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if character.value < 0x20 {
                    output += String(format: "\\u%04x", character.value)
                } else {
                    output.unicodeScalars.append(character)
                }
            }
        }
        return output + "\""
    }

    private static func sqlInserts(columns: [ColumnInfo], rows: [ResultRow], options: ExportOptions) -> String {
        let dialect = SQLDialect(kind: options.kind)
        let columnList = columns.map { dialect.quote($0.name) }.joined(separator: ", ")
        let table = options.tableName.contains(".")
            ? dialect.quoteQualified(options.tableName.split(separator: ".").map(String.init))
            : dialect.quote(options.tableName)

        return rows.map { row -> String in
            let values = columns.indices.map { dialect.literal(row[$0]) }.joined(separator: ", ")
            return "INSERT INTO \(table) (\(columnList)) VALUES (\(values));"
        }.joined(separator: "\n")
    }

    private static func markdown(columns: [ColumnInfo], rows: [ResultRow], options: ExportOptions) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        var lines: [String] = []
        lines.append("| " + columns.map { escape($0.name) }.joined(separator: " | ") + " |")
        lines.append("| " + columns.map { _ in "---" }.joined(separator: " | ") + " |")
        for row in rows {
            let cells = columns.indices.map { index -> String in
                let value = row[index]
                return escape(value.isNull ? options.nullPlaceholder : value.stringValue)
            }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }
}
