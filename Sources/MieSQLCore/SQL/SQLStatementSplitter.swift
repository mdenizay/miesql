import Foundation

/// One statement carved out of an editor buffer, with the range it came from so the
/// editor can highlight "the statement under the cursor" and report error positions.
public struct SQLStatement: Sendable, Identifiable {
    public let id = UUID()
    public let text: String
    public let range: Range<String.Index>

    public init(text: String, range: Range<String.Index>) {
        self.text = text
        self.range = range
    }
}

/// Splits a script into statements on semicolons, while respecting the things that make
/// a naive `split(separator: ";")` wrong: quoted strings, quoted identifiers, line and
/// block comments, PostgreSQL dollar quoting, and MySQL `DELIMITER` changes.
public enum SQLStatementSplitter {

    public static func split(_ sql: String, kind: DatabaseKind = .postgres) -> [SQLStatement] {
        var statements: [SQLStatement] = []
        var index = sql.startIndex
        var statementStart = sql.startIndex
        var delimiter = ";"
        let end = sql.endIndex

        func flush(upTo terminator: String.Index, skipping consumed: String.Index) {
            let raw = String(sql[statementStart..<terminator])
            if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                statements.append(SQLStatement(text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                                               range: statementStart..<terminator))
            }
            statementStart = consumed
        }

        while index < end {
            let char = sql[index]

            // -- line comment
            if char == "-", sql.index(after: index) < end, sql[sql.index(after: index)] == "-" {
                while index < end, sql[index] != "\n" { index = sql.index(after: index) }
                continue
            }

            // # line comment (MySQL)
            if char == "#", kind.usesMySQLProtocol {
                while index < end, sql[index] != "\n" { index = sql.index(after: index) }
                continue
            }

            // /* block comment */
            if char == "/", sql.index(after: index) < end, sql[sql.index(after: index)] == "*" {
                index = sql.index(index, offsetBy: 2, limitedBy: end) ?? end
                while index < end {
                    if sql[index] == "*", sql.index(after: index) < end, sql[sql.index(after: index)] == "/" {
                        index = sql.index(index, offsetBy: 2, limitedBy: end) ?? end
                        break
                    }
                    index = sql.index(after: index)
                }
                continue
            }

            // Quoted string or identifier. Doubling the quote escapes it in every dialect
            // we support; MySQL additionally honours backslash escapes.
            if char == "'" || char == "\"" || (char == "`" && kind.usesMySQLProtocol) {
                let quote = char
                index = sql.index(after: index)
                while index < end {
                    if sql[index] == "\\", kind.usesMySQLProtocol, quote != "`" {
                        index = sql.index(index, offsetBy: 2, limitedBy: end) ?? end
                        continue
                    }
                    if sql[index] == quote {
                        let next = sql.index(after: index)
                        if next < end, sql[next] == quote {
                            index = sql.index(after: next)
                            continue
                        }
                        index = next
                        break
                    }
                    index = sql.index(after: index)
                }
                continue
            }

            // PostgreSQL dollar quoting: $$ ... $$ or $tag$ ... $tag$
            if char == "$", kind == .postgres, let tag = dollarTag(in: sql, at: index) {
                let bodyStart = sql.index(index, offsetBy: tag.count, limitedBy: end) ?? end
                if let closing = sql.range(of: tag, range: bodyStart..<end) {
                    index = closing.upperBound
                } else {
                    index = end
                }
                continue
            }

            // MySQL DELIMITER directive, which changes the terminator for what follows.
            if kind.usesMySQLProtocol, isAtLineStart(sql, index), matchesKeyword(sql, at: index, keyword: "DELIMITER") {
                var cursor = sql.index(index, offsetBy: 9, limitedBy: end) ?? end
                while cursor < end, sql[cursor] == " " || sql[cursor] == "\t" { cursor = sql.index(after: cursor) }
                var newDelimiter = ""
                while cursor < end, !sql[cursor].isWhitespace {
                    newDelimiter.append(sql[cursor])
                    cursor = sql.index(after: cursor)
                }
                if !newDelimiter.isEmpty { delimiter = newDelimiter }
                // The directive itself is a client-side instruction, never sent to the server.
                flush(upTo: index, skipping: cursor)
                index = cursor
                continue
            }

            // Statement terminator
            if sql[index...].hasPrefix(delimiter) {
                let terminator = index
                let after = sql.index(index, offsetBy: delimiter.count, limitedBy: end) ?? end
                flush(upTo: terminator, skipping: after)
                index = after
                continue
            }

            index = sql.index(after: index)
        }

        // Trailing statement without a terminator.
        if statementStart < end {
            let raw = String(sql[statementStart..<end])
            if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                statements.append(SQLStatement(text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                                               range: statementStart..<end))
            }
        }

        return statements
    }

    /// The statement whose range contains `location`, used by "Run current statement".
    public static func statement(at location: String.Index, in sql: String, kind: DatabaseKind) -> SQLStatement? {
        let statements = split(sql, kind: kind)
        if let match = statements.first(where: { $0.range.contains(location) }) {
            return match
        }
        // A caret sitting just past the final semicolon belongs to the statement before it.
        return statements.last(where: { $0.range.upperBound <= location })
    }

    private static func dollarTag(in sql: String, at index: String.Index) -> String? {
        var cursor = sql.index(after: index)
        var tag = "$"
        while cursor < sql.endIndex {
            let char = sql[cursor]
            if char == "$" { return tag + "$" }
            guard char.isLetter || char.isNumber || char == "_" else { return nil }
            tag.append(char)
            cursor = sql.index(after: cursor)
        }
        return nil
    }

    private static func isAtLineStart(_ sql: String, _ index: String.Index) -> Bool {
        var cursor = index
        while cursor > sql.startIndex {
            cursor = sql.index(before: cursor)
            let char = sql[cursor]
            if char == "\n" { return true }
            if !char.isWhitespace { return false }
        }
        return true
    }

    private static func matchesKeyword(_ sql: String, at index: String.Index, keyword: String) -> Bool {
        guard let upper = sql.index(index, offsetBy: keyword.count, limitedBy: sql.endIndex) else { return false }
        return sql[index..<upper].uppercased() == keyword
    }
}
