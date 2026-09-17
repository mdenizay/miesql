import Foundation

/// A deliberately conservative pretty printer: it re-indents, breaks before the major
/// clauses and uppercases keywords, and otherwise leaves the user's SQL alone. It never
/// reorders or rewrites anything, so running it cannot change what a statement does.
///
/// The output style puts each clause keyword on its own line with its body indented:
///
///     SELECT
///         a,
///         b
///     FROM
///         t
///     WHERE
///         a = 1
public enum SQLFormatter {

    /// Keywords that start a clause: they break the line and indent what follows.
    private static let clauseKeywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "HAVING", "VALUES", "SET", "RETURNING", "WINDOW",
        "GROUP BY", "ORDER BY", "LIMIT", "OFFSET"
    ]

    /// Keywords that break the line but keep their body alongside them.
    private static let inlineBreakKeywords: Set<String> = [
        "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL",
        "UNION", "INTERSECT", "EXCEPT", "AND", "OR", "ON"
    ]

    public static func format(_ sql: String, kind: DatabaseKind = .postgres, indent: String = "    ") -> String {
        let statements = SQLStatementSplitter.split(sql, kind: kind)
        guard !statements.isEmpty else { return sql }
        return statements
            .map { formatStatement($0.text, kind: kind, indent: indent) }
            .joined(separator: ";\n\n") + ";"
    }

    public static func formatStatement(_ sql: String, kind: DatabaseKind, indent: String = "    ") -> String {
        let tokens = SQLLexer.tokenize(sql, kind: kind)
        guard !tokens.isEmpty else { return sql }

        var lines: [String] = []
        var current = ""
        var parenDepth = 0
        var inClauseBody = false
        var skipNext = false

        func indentation() -> String {
            String(repeating: indent, count: max(parenDepth, 0) + (inClauseBody ? 1 : 0))
        }

        func endLine() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(indentation() + trimmed) }
            current = ""
        }

        /// `GROUP BY` and `ORDER BY` are two tokens but one clause.
        func compoundKeyword(at index: Int) -> String? {
            let word = tokens[index].text.uppercased()
            guard word == "GROUP" || word == "ORDER" else { return nil }
            guard index + 1 < tokens.count, tokens[index + 1].text.uppercased() == "BY" else { return nil }
            return "\(word) BY"
        }

        for (index, token) in tokens.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }

            let upper = token.text.uppercased()

            switch token.kind {
            case .comment:
                endLine()
                lines.append(indentation() + token.text)
                continue

            case .punctuation where token.text == "(":
                current += current.isEmpty || current.hasSuffix(" ") || current.hasSuffix("(") ? "(" : " ("
                parenDepth += 1
                continue

            case .punctuation where token.text == ")":
                endLine()
                parenDepth = max(parenDepth - 1, 0)
                current = ")"
                continue

            case .punctuation where token.text == ",":
                current += ","
                endLine()
                continue

            case .punctuation:
                current += token.text
                continue

            case .keyword:
                if let compound = compoundKeyword(at: index) {
                    endLine()
                    inClauseBody = false
                    lines.append(indentation() + compound)
                    inClauseBody = true
                    skipNext = true
                    continue
                }
                if clauseKeywords.contains(upper) {
                    endLine()
                    inClauseBody = false
                    lines.append(indentation() + upper)
                    inClauseBody = true
                    continue
                }
                if inlineBreakKeywords.contains(upper) {
                    endLine()
                    current = upper
                    continue
                }
                current += current.isEmpty || current.hasSuffix("(") ? upper : " " + upper
                continue

            default:
                let text = (token.kind == .type || token.kind == .function) ? upper : token.text
                current += current.isEmpty || current.hasSuffix("(") ? text : " " + text
            }
        }

        endLine()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
