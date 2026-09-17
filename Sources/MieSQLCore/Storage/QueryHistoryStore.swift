import Foundation

public struct QueryHistoryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var sql: String
    public var connectionName: String
    public var database: String
    public var executedAt: Date
    public var durationSeconds: Double
    public var succeeded: Bool
    public var rowCount: Int?
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        sql: String,
        connectionName: String,
        database: String,
        executedAt: Date = Date(),
        durationSeconds: Double,
        succeeded: Bool,
        rowCount: Int? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.sql = sql
        self.connectionName = connectionName
        self.database = database
        self.executedAt = executedAt
        self.durationSeconds = durationSeconds
        self.succeeded = succeeded
        self.rowCount = rowCount
        self.errorMessage = errorMessage
    }

    /// First line, clipped, for the history list.
    public var preview: String {
        let flattened = sql
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.count > 120 ? String(flattened.prefix(120)) + "…" : flattened
    }
}

/// Query history, capped and kept on disk. Never leaves the machine.
public final class QueryHistoryStore: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "app.miesql.history")
    private var cached: [QueryHistoryEntry]?

    public init(fileURL: URL = AppPaths.historyFile) {
        self.fileURL = fileURL
    }

    public func load() -> [QueryHistoryEntry] {
        queue.sync {
            if let cached { return cached }
            guard let data = try? Data(contentsOf: fileURL) else {
                cached = []
                return []
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let entries = (try? decoder.decode([QueryHistoryEntry].self, from: data)) ?? []
            cached = entries
            return entries
        }
    }

    public func append(_ entry: QueryHistoryEntry, limit: Int) {
        queue.sync {
            var entries = cached ?? loadUncached()
            entries.insert(entry, at: 0)
            if entries.count > limit {
                entries = Array(entries.prefix(limit))
            }
            cached = entries
            persist(entries)
        }
    }

    public func clear() {
        queue.sync {
            cached = []
            persist([])
        }
    }

    public func remove(ids: Set<UUID>) {
        queue.sync {
            var entries = cached ?? loadUncached()
            entries.removeAll { ids.contains($0.id) }
            cached = entries
            persist(entries)
        }
    }

    private func loadUncached() -> [QueryHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([QueryHistoryEntry].self, from: data)) ?? []
    }

    private func persist(_ entries: [QueryHistoryEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Saved snippets

public struct SQLSnippet: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var sql: String
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, sql: String, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sql = sql
        self.updatedAt = updatedAt
    }
}

public final class SnippetStore: @unchecked Sendable {
    private let fileURL: URL

    public init(fileURL: URL = AppPaths.snippetsFile) {
        self.fileURL = fileURL
    }

    public func load() -> [SQLSnippet] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SQLSnippet].self, from: data)) ?? []
    }

    public func save(_ snippets: [SQLSnippet]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snippets) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
