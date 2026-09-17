import Foundation

/// A single cell. Values arrive from every driver already rendered to text, which keeps
/// the grid, the exporters and the clipboard on one code path; `isNull` stays distinct
/// from the empty string so `NULL` and `''` never get confused.
public enum SQLValue: Hashable, Sendable {
    case null
    case text(String)

    public var isNull: Bool { if case .null = self { return true }; return false }

    public var stringValue: String {
        switch self {
        case .null: return ""
        case .text(let s): return s
        }
    }

    /// What the grid draws. NULL is shown with a marker rather than blank.
    public var displayValue: String {
        switch self {
        case .null: return "NULL"
        case .text(let s): return s
        }
    }
}

public struct ColumnInfo: Hashable, Sendable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let name: String
    /// Engine specific type name, e.g. `int4`, `VARCHAR`, `TEXT`.
    public let typeName: String
    /// Source table, when the server reports one. Needed for editable result grids.
    public let tableName: String?

    public init(index: Int, name: String, typeName: String, tableName: String? = nil) {
        self.index = index
        self.name = name
        self.typeName = typeName
        self.tableName = tableName
    }

    /// Right-aligns numerics in the grid.
    public var isNumeric: Bool {
        let t = typeName.lowercased()
        return t.contains("int") || t.contains("num") || t.contains("dec")
            || t.contains("float") || t.contains("double") || t.contains("real")
            || t.contains("serial") || t.contains("money")
    }
}

public struct ResultRow: Identifiable, Hashable, Sendable {
    public let id: Int
    public var values: [SQLValue]

    public init(id: Int, values: [SQLValue]) {
        self.id = id
        self.values = values
    }

    public subscript(index: Int) -> SQLValue {
        guard index >= 0 && index < values.count else { return .null }
        return values[index]
    }
}

/// The outcome of one statement. A batch of statements produces one of these each.
public struct QueryResult: Identifiable, Sendable {
    public let id = UUID()
    /// The statement that produced this result, for the history list and tab title.
    public let statement: String
    public let columns: [ColumnInfo]
    public var rows: [ResultRow]
    /// Rows changed by INSERT/UPDATE/DELETE. `nil` for SELECT-shaped results.
    public let rowsAffected: Int?
    public let duration: TimeInterval
    /// Server notices such as PostgreSQL's `NOTICE:` output, surfaced under the grid.
    public let messages: [String]

    public init(
        statement: String,
        columns: [ColumnInfo] = [],
        rows: [ResultRow] = [],
        rowsAffected: Int? = nil,
        duration: TimeInterval = 0,
        messages: [String] = []
    ) {
        self.statement = statement
        self.columns = columns
        self.rows = rows
        self.rowsAffected = rowsAffected
        self.duration = duration
        self.messages = messages
    }

    public var hasResultSet: Bool { !columns.isEmpty }

    /// One-line status shown above the grid.
    public func summary(locale: Locale = .current) -> String {
        let ms = String(format: "%.0f ms", duration * 1000)
        if hasResultSet {
            return "\(rows.count) row\(rows.count == 1 ? "" : "s") · \(ms)"
        }
        if let affected = rowsAffected {
            return "\(affected) row\(affected == 1 ? "" : "s") affected · \(ms)"
        }
        return "OK · \(ms)"
    }
}

/// Raised by the drivers; carries the server's own wording so the user sees the real error.
public struct DatabaseError: LocalizedError, Sendable {
    public let message: String
    /// SQLSTATE or engine error number, when the server supplies one.
    public let code: String?
    public let detail: String?

    public init(message: String, code: String? = nil, detail: String? = nil) {
        self.message = message
        self.code = code
        self.detail = detail
    }

    public var errorDescription: String? {
        var text = message
        if let code, !code.isEmpty { text = "[\(code)] \(text)" }
        if let detail, !detail.isEmpty { text += "\n\(detail)" }
        return text
    }
}
