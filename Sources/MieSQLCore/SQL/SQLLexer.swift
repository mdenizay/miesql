import Foundation

public enum SQLTokenKind: Sendable, Equatable {
    case keyword
    case function
    case type
    case string
    case number
    case comment
    case identifier
    case quotedIdentifier
    case parameter
    case punctuation
    case whitespace
}

public struct SQLToken: Sendable, Equatable {
    public let kind: SQLTokenKind
    /// UTF-16 range, which is what AppKit text views want.
    public let range: NSRange
    public let text: String

    public init(kind: SQLTokenKind, range: NSRange, text: String) {
        self.kind = kind
        self.range = range
        self.text = text
    }
}

/// Small hand-written lexer. It only has to be good enough to colour the editor and to
/// feed word suggestions, so it classifies rather than parses.
public enum SQLLexer {

    public static func tokenize(_ sql: String, kind: DatabaseKind = .postgres) -> [SQLToken] {
        var tokens: [SQLToken] = []
        let scalars = Array(sql.utf16)
        let characters = Array(sql)
        // UTF-16 offset of each Character, so ranges land correctly on emoji and accents.
        var utf16Offsets: [Int] = []
        utf16Offsets.reserveCapacity(characters.count + 1)
        var running = 0
        for character in characters {
            utf16Offsets.append(running)
            running += String(character).utf16.count
        }
        utf16Offsets.append(running)
        _ = scalars

        var i = 0
        let count = characters.count

        func range(_ from: Int, _ to: Int) -> NSRange {
            NSRange(location: utf16Offsets[from], length: utf16Offsets[to] - utf16Offsets[from])
        }

        func append(_ kind: SQLTokenKind, _ from: Int, _ to: Int) {
            guard to > from else { return }
            tokens.append(SQLToken(kind: kind, range: range(from, to), text: String(characters[from..<to])))
        }

        while i < count {
            let char = characters[i]

            if char.isWhitespace {
                i += 1
                continue
            }

            // Line comments
            if char == "-" && i + 1 < count && characters[i + 1] == "-" {
                let start = i
                while i < count && characters[i] != "\n" { i += 1 }
                append(.comment, start, i)
                continue
            }
            if char == "#" && kind.usesMySQLProtocol {
                let start = i
                while i < count && characters[i] != "\n" { i += 1 }
                append(.comment, start, i)
                continue
            }

            // Block comment
            if char == "/" && i + 1 < count && characters[i + 1] == "*" {
                let start = i
                i += 2
                while i < count {
                    if characters[i] == "*" && i + 1 < count && characters[i + 1] == "/" {
                        i += 2
                        break
                    }
                    i += 1
                }
                append(.comment, start, i)
                continue
            }

            // Strings
            if char == "'" {
                let start = i
                i += 1
                while i < count {
                    if characters[i] == "\\" && kind.usesMySQLProtocol { i += 2; continue }
                    if characters[i] == "'" {
                        if i + 1 < count && characters[i + 1] == "'" { i += 2; continue }
                        i += 1
                        break
                    }
                    i += 1
                }
                append(.string, start, i)
                continue
            }

            // Quoted identifiers
            if char == "\"" || (char == "`" && kind.usesMySQLProtocol) {
                let quote = char
                let start = i
                i += 1
                while i < count {
                    if characters[i] == quote {
                        if i + 1 < count && characters[i + 1] == quote { i += 2; continue }
                        i += 1
                        break
                    }
                    i += 1
                }
                append(.quotedIdentifier, start, i)
                continue
            }

            // Bind parameters: $1, :name, ?
            if char == "$" && i + 1 < count && characters[i + 1].isNumber {
                let start = i
                i += 1
                while i < count && characters[i].isNumber { i += 1 }
                append(.parameter, start, i)
                continue
            }
            if char == "?" {
                append(.parameter, i, i + 1)
                i += 1
                continue
            }

            // Numbers
            if char.isNumber {
                let start = i
                while i < count && (characters[i].isNumber || characters[i] == "." || characters[i] == "e" || characters[i] == "E") { i += 1 }
                append(.number, start, i)
                continue
            }

            // Words
            if char.isLetter || char == "_" {
                let start = i
                while i < count && (characters[i].isLetter || characters[i].isNumber || characters[i] == "_" || characters[i] == "$") { i += 1 }
                let word = String(characters[start..<i]).uppercased()
                let tokenKind: SQLTokenKind
                if SQLKeywords.reserved.contains(word) {
                    tokenKind = .keyword
                } else if SQLKeywords.types.contains(word) {
                    tokenKind = .type
                } else if SQLKeywords.functions.contains(word) {
                    tokenKind = .function
                } else {
                    tokenKind = .identifier
                }
                append(tokenKind, start, i)
                continue
            }

            append(.punctuation, i, i + 1)
            i += 1
        }

        return tokens
    }

    /// The word the caret sits inside or just after, used to drive completion.
    public static func wordRange(in text: String, at utf16Location: Int) -> NSRange? {
        let ns = text as NSString
        guard utf16Location <= ns.length else { return nil }
        var start = utf16Location
        while start > 0 {
            let scalar = ns.character(at: start - 1)
            guard let unicode = Unicode.Scalar(scalar), isWordScalar(unicode) else { break }
            start -= 1
        }
        var end = utf16Location
        while end < ns.length {
            let scalar = ns.character(at: end)
            guard let unicode = Unicode.Scalar(scalar), isWordScalar(unicode) else { break }
            end += 1
        }
        guard end > start else { return NSRange(location: utf16Location, length: 0) }
        return NSRange(location: start, length: end - start)
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }
}
