import Foundation
import MieSQLCore

/// A query editor tab.
@MainActor
final class QueryTabModel: ObservableObject, Identifiable {
    nonisolated let id = UUID()
    nonisolated let sessionID: UUID

    @Published var title: String
    @Published var sql: String
    @Published var results: [QueryResult] = []
    @Published var selectedResultIndex: Int = 0
    @Published var isRunning = false
    @Published var errorMessage: String?
    /// Set when the editor should move the caret, e.g. after inserting from history.
    @Published var pendingCaretReset = false
    /// The database the tab runs against; changing it issues a USE before the next query.
    @Published var database: String

    init(sessionID: UUID, title: String, sql: String = "", database: String = "") {
        self.sessionID = sessionID
        self.title = title
        self.sql = sql
        self.database = database
    }

    var currentResult: QueryResult? {
        guard results.indices.contains(selectedResultIndex) else { return results.first }
        return results[selectedResultIndex]
    }
}

/// A table tab: data browser, structure and DDL for one table.
@MainActor
final class TableTabModel: ObservableObject, Identifiable {

    enum Section: String, CaseIterable, Identifiable {
        case data
        case structure
        case ddl

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .data: return "workspace.tab.data"
            case .structure: return "workspace.tab.structure"
            case .ddl: return "workspace.tab.ddl"
            }
        }
    }

    nonisolated let id = UUID()
    nonisolated let sessionID: UUID
    nonisolated let table: TableRef

    @Published var section: Section = .data
    @Published var result: QueryResult?
    @Published var details: TableDetails?
    @Published var ddl: String = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    // Paging and filtering
    @Published var page = 0
    @Published var pageSize: Int
    @Published var totalRows: Int?
    @Published var filterClause = ""
    @Published var sortColumn: String?
    @Published var sortAscending = true

    // Pending grid edits, applied together.
    @Published var edits = EditBuffer()

    init(sessionID: UUID, table: TableRef, pageSize: Int) {
        self.sessionID = sessionID
        self.table = table
        self.pageSize = pageSize
    }

    var title: String { table.name }

    var offset: Int { page * pageSize }

    var canGoToNextPage: Bool {
        guard let result else { return false }
        if let totalRows { return offset + result.rows.count < totalRows }
        return result.rows.count == pageSize
    }

    var canGoToPreviousPage: Bool { page > 0 }

    /// A table can only be edited when we can name exactly one row.
    var primaryKeyColumns: [String] { details?.primaryKeyColumns ?? [] }
    var isEditable: Bool { !primaryKeyColumns.isEmpty && table.kind == .table }
}

/// Collects grid edits until the user applies them, so nothing reaches the database
/// until it has been reviewed.
struct EditBuffer: Equatable {
    /// rowID → column → new value
    var updates: [Int: [String: SQLValue]] = [:]
    /// Original values for rows being updated or deleted, needed to build the WHERE clause.
    var originals: [Int: [String: SQLValue]] = [:]
    var deletions: Set<Int> = []
    /// Rows added in the grid but not yet inserted.
    var insertions: [Int: [String: SQLValue]] = [:]

    var isEmpty: Bool { updates.isEmpty && deletions.isEmpty && insertions.isEmpty }

    var count: Int { updates.count + deletions.count + insertions.count }

    mutating func recordUpdate(rowID: Int, column: String, value: SQLValue, original: [String: SQLValue]) {
        if insertions[rowID] != nil {
            insertions[rowID]?[column] = value
            return
        }
        originals[rowID] = original
        updates[rowID, default: [:]][column] = value
        // An edit that restores the original value is not a change at all.
        if updates[rowID]?[column] == original[column] {
            updates[rowID]?.removeValue(forKey: column)
            if updates[rowID]?.isEmpty == true {
                updates.removeValue(forKey: rowID)
                originals.removeValue(forKey: rowID)
            }
        }
    }

    mutating func clear() {
        updates.removeAll()
        originals.removeAll()
        deletions.removeAll()
        insertions.removeAll()
    }

    func rowEdits() -> [RowEdit] {
        var edits: [RowEdit] = []
        for (rowID, values) in insertions.sorted(by: { $0.key < $1.key }) {
            edits.append(.insert(rowID: rowID, values: values))
        }
        for (rowID, changes) in updates.sorted(by: { $0.key < $1.key }) where !changes.isEmpty {
            edits.append(.update(rowID: rowID, changes: changes, original: originals[rowID] ?? [:]))
        }
        for rowID in deletions.sorted() {
            edits.append(.delete(rowID: rowID, original: originals[rowID] ?? [:]))
        }
        return edits
    }
}

/// A tab in the workspace. Two shapes, one list.
enum WorkspaceTab: Identifiable {
    case query(QueryTabModel)
    case table(TableTabModel)

    var id: UUID {
        switch self {
        case .query(let model): return model.id
        case .table(let model): return model.id
        }
    }

    var sessionID: UUID {
        switch self {
        case .query(let model): return model.sessionID
        case .table(let model): return model.sessionID
        }
    }

    @MainActor
    var title: String {
        switch self {
        case .query(let model): return model.title
        case .table(let model): return model.title
        }
    }

    @MainActor
    var symbolName: String {
        switch self {
        case .query: return "terminal"
        case .table(let model): return model.table.kind.symbolName
        }
    }
}
