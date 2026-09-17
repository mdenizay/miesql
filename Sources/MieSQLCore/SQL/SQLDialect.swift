import Foundation

/// Per-engine quoting and paging rules. Everything that builds SQL on the user's behalf —
/// the data browser, the row editor, the dumper — goes through here so identifiers and
/// literals are escaped exactly once, in one place.
public struct SQLDialect: Sendable {
    public let kind: DatabaseKind

    public init(kind: DatabaseKind) {
        self.kind = kind
    }

    /// Quote an identifier, doubling any embedded quote character.
    public func quote(_ identifier: String) -> String {
        switch kind {
        case .mysql, .mariadb:
            return "`" + identifier.replacingOccurrences(of: "`", with: "``") + "`"
        case .postgres, .sqlite:
            return "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    /// Quote a possibly-qualified name such as `public.users`, part by part.
    public func quoteQualified(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.map(quote).joined(separator: ".")
    }

    public func qualified(_ table: TableRef) -> String {
        quoteQualified([table.schema, table.name])
    }

    /// Render a value as a SQL literal. `nil` becomes `NULL`.
    public func literal(_ value: SQLValue) -> String {
        switch value {
        case .null:
            return "NULL"
        case .text(let string):
            return stringLiteral(string)
        }
    }

    public func stringLiteral(_ string: String) -> String {
        switch kind {
        case .mysql, .mariadb:
            // MySQL treats backslash as an escape character by default, so it needs doubling
            // on top of the standard single-quote doubling.
            var escaped = string.replacingOccurrences(of: "\\", with: "\\\\")
            escaped = escaped.replacingOccurrences(of: "'", with: "''")
            return "'" + escaped + "'"
        case .postgres, .sqlite:
            return "'" + string.replacingOccurrences(of: "'", with: "''") + "'"
        }
    }

    /// Byte literal used by the dumper for binary columns.
    public func blobLiteral(_ hex: String) -> String {
        switch kind {
        case .mysql, .mariadb, .sqlite:
            return "X'\(hex)'"
        case .postgres:
            return "'\\x\(hex)'::bytea"
        }
    }

    public func limitClause(limit: Int, offset: Int) -> String {
        offset > 0 ? "LIMIT \(limit) OFFSET \(offset)" : "LIMIT \(limit)"
    }

    /// `SELECT * FROM table ORDER BY ... LIMIT ...` for the data browser.
    public func selectStatement(
        table: TableRef,
        columns: [String] = [],
        whereClause: String = "",
        orderBy: [(column: String, ascending: Bool)] = [],
        limit: Int,
        offset: Int
    ) -> String {
        let projection = columns.isEmpty ? "*" : columns.map(quote).joined(separator: ", ")
        var sql = "SELECT \(projection) FROM \(qualified(table))"
        let trimmedWhere = whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedWhere.isEmpty {
            sql += " WHERE \(trimmedWhere)"
        }
        if !orderBy.isEmpty {
            let terms = orderBy.map { "\(quote($0.column)) \($0.ascending ? "ASC" : "DESC")" }
            sql += " ORDER BY \(terms.joined(separator: ", "))"
        }
        sql += " \(limitClause(limit: limit, offset: offset))"
        return sql
    }

    public func countStatement(table: TableRef, whereClause: String = "") -> String {
        var sql = "SELECT COUNT(*) FROM \(qualified(table))"
        let trimmedWhere = whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedWhere.isEmpty {
            sql += " WHERE \(trimmedWhere)"
        }
        return sql
    }

    /// Statement kinds we need to tell apart to enforce read-only mode and to decide
    /// whether a result grid is expected.
    public static func isReadOnlyStatement(_ sql: String) -> Bool {
        let first = SQLDialect.leadingKeyword(of: sql)
        return ["select", "show", "explain", "describe", "desc", "with", "pragma", "values", "table"].contains(first)
    }

    /// The first real keyword, skipping comments and whitespace.
    public static func leadingKeyword(of sql: String) -> String {
        var scanner = sql.startIndex
        let end = sql.endIndex
        while scanner < end {
            let char = sql[scanner]
            if char.isWhitespace {
                scanner = sql.index(after: scanner)
                continue
            }
            // Line comment
            if char == "-", sql.index(after: scanner) < end, sql[sql.index(after: scanner)] == "-" {
                while scanner < end, sql[scanner] != "\n" { scanner = sql.index(after: scanner) }
                continue
            }
            // Block comment
            if char == "/", sql.index(after: scanner) < end, sql[sql.index(after: scanner)] == "*" {
                scanner = sql.index(scanner, offsetBy: 2, limitedBy: end) ?? end
                while scanner < end {
                    if sql[scanner] == "*", sql.index(after: scanner) < end, sql[sql.index(after: scanner)] == "/" {
                        scanner = sql.index(scanner, offsetBy: 2, limitedBy: end) ?? end
                        break
                    }
                    scanner = sql.index(after: scanner)
                }
                continue
            }
            break
        }
        guard scanner < end else { return "" }
        var word = ""
        while scanner < end, sql[scanner].isLetter {
            word.append(sql[scanner])
            scanner = sql.index(after: scanner)
        }
        return word.lowercased()
    }
}
