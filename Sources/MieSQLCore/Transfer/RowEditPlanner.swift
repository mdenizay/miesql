import Foundation

/// One pending change made in the result grid.
public enum RowEdit: Sendable, Identifiable {
    case update(rowID: Int, changes: [String: SQLValue], original: [String: SQLValue])
    case insert(rowID: Int, values: [String: SQLValue])
    case delete(rowID: Int, original: [String: SQLValue])

    public var id: String {
        switch self {
        case .update(let rowID, _, _): return "u\(rowID)"
        case .insert(let rowID, _): return "i\(rowID)"
        case .delete(let rowID, _): return "d\(rowID)"
        }
    }
}

public struct PlannedStatement: Sendable, Identifiable {
    public let id = UUID()
    public let sql: String
    public let edit: RowEdit

    public init(sql: String, edit: RowEdit) {
        self.sql = sql
        self.edit = edit
    }
}

public enum RowEditError: LocalizedError {
    case noPrimaryKey(table: String)
    case missingKeyValue(column: String)
    case nothingToDo

    public var errorDescription: String? {
        switch self {
        case .noPrimaryKey(let table):
            return "\(table) has no primary key or unique index, so MieSQL cannot identify a single row to change. Edit it with a SQL statement instead."
        case .missingKeyValue(let column):
            return "The value of key column \"\(column)\" is missing for this row."
        case .nothingToDo:
            return "There is nothing to apply."
        }
    }
}

/// Turns grid edits into SQL. Every generated statement is keyed on the full primary key
/// and is shown to the user before it runs, so an edit can never silently hit more rows
/// than intended.
public struct RowEditPlanner: Sendable {

    private let dialect: SQLDialect
    private let table: TableRef
    private let keyColumns: [String]

    public init(kind: DatabaseKind, table: TableRef, keyColumns: [String]) {
        self.dialect = SQLDialect(kind: kind)
        self.table = table
        self.keyColumns = keyColumns
    }

    public func plan(_ edits: [RowEdit]) throws -> [PlannedStatement] {
        guard !edits.isEmpty else { throw RowEditError.nothingToDo }

        // Inserts do not need a key, so a keyless table can still be appended to.
        let needsKey = edits.contains { edit in
            if case .insert = edit { return false }
            return true
        }
        if needsKey && keyColumns.isEmpty {
            throw RowEditError.noPrimaryKey(table: table.qualifiedName)
        }

        return try edits.map { edit in
            switch edit {
            case .update(_, let changes, let original):
                return PlannedStatement(sql: try updateStatement(changes: changes, original: original), edit: edit)
            case .insert(_, let values):
                return PlannedStatement(sql: insertStatement(values: values), edit: edit)
            case .delete(_, let original):
                return PlannedStatement(sql: try deleteStatement(original: original), edit: edit)
            }
        }
    }

    private func updateStatement(changes: [String: SQLValue], original: [String: SQLValue]) throws -> String {
        let assignments = changes
            .sorted { $0.key < $1.key }
            .map { "\(dialect.quote($0.key)) = \(dialect.literal($0.value))" }
            .joined(separator: ", ")
        return "UPDATE \(dialect.qualified(table)) SET \(assignments) WHERE \(try whereClause(original));"
    }

    private func insertStatement(values: [String: SQLValue]) -> String {
        let sorted = values.sorted { $0.key < $1.key }
        let columns = sorted.map { dialect.quote($0.key) }.joined(separator: ", ")
        let literals = sorted.map { dialect.literal($0.value) }.joined(separator: ", ")
        return "INSERT INTO \(dialect.qualified(table)) (\(columns)) VALUES (\(literals));"
    }

    private func deleteStatement(original: [String: SQLValue]) throws -> String {
        "DELETE FROM \(dialect.qualified(table)) WHERE \(try whereClause(original));"
    }

    /// Always matches on the complete key, and uses `IS NULL` where a key part is NULL so
    /// the comparison behaves as expected.
    private func whereClause(_ original: [String: SQLValue]) throws -> String {
        var predicates: [String] = []
        for column in keyColumns {
            guard let value = original[column] else {
                throw RowEditError.missingKeyValue(column: column)
            }
            if value.isNull {
                predicates.append("\(dialect.quote(column)) IS NULL")
            } else {
                predicates.append("\(dialect.quote(column)) = \(dialect.literal(value))")
            }
        }
        return predicates.joined(separator: " AND ")
    }
}
