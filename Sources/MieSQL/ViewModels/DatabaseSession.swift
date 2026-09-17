import Foundation
import MieSQLCore

/// One schema node in the sidebar tree. Children load the first time a node is expanded,
/// so opening a server with hundreds of databases stays instant.
struct SchemaNode: Identifiable, Hashable {
    var id: String { "\(database)|\(name)" }
    var database: String
    var name: String
    var tables: [TableRef] = []
    var isLoaded = false
}

struct DatabaseNode: Identifiable, Hashable {
    var id: String { name }
    var name: String
    /// Empty for engines with no schema level; those put their tables in `tables`.
    var schemas: [SchemaNode] = []
    var tables: [TableRef] = []
    var isLoaded = false
    var hasSchemaLevel = false
}

@MainActor
final class DatabaseSession: ObservableObject, Identifiable {

    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var isConnected: Bool { self == .connected }
    }

    nonisolated let id: UUID
    @Published var profile: ConnectionProfile
    @Published private(set) var status: Status = .disconnected
    @Published private(set) var serverInfo: ServerInfo?
    @Published private(set) var databases: [DatabaseNode] = []
    @Published var expandedDatabases: Set<String> = []
    @Published var expandedSchemas: Set<String> = []

    private(set) var driver: (any DatabaseDriver)?

    init(profile: ConnectionProfile) {
        self.id = profile.id
        self.profile = profile
    }

    var kind: DatabaseKind { profile.kind }

    // MARK: - Lifecycle

    func connect(password: String?) async {
        guard status != .connecting else { return }
        status = .connecting

        let credentials = ConnectionCredentials(profile: profile, password: password)
        let newDriver = DriverFactory.makeDriver(for: credentials)

        do {
            let info = try await newDriver.connect()
            driver = newDriver
            serverInfo = info
            status = .connected
            try await loadDatabases()
        } catch {
            await newDriver.disconnect()
            driver = nil
            status = .failed(Self.describe(error))
        }
    }

    func disconnect() async {
        if let driver {
            await driver.disconnect()
        }
        driver = nil
        serverInfo = nil
        databases = []
        expandedDatabases = []
        expandedSchemas = []
        status = .disconnected
    }

    // MARK: - Tree loading

    func loadDatabases() async throws {
        guard let driver else { return }
        let names = try await driver.listDatabases()
        let hasSchemaLevel = kind == .postgres

        databases = names.map { name in
            DatabaseNode(name: name, hasSchemaLevel: hasSchemaLevel)
        }

        // Expand the database the connection opened with, so the tree is useful immediately.
        if let current = serverInfo?.currentDatabase, names.contains(current) {
            expandedDatabases.insert(current)
            try await loadChildren(ofDatabase: current)
        }
    }

    func loadChildren(ofDatabase database: String) async throws {
        guard let driver, let index = databases.firstIndex(where: { $0.name == database }) else { return }
        guard !databases[index].isLoaded else { return }

        if databases[index].hasSchemaLevel {
            let schemas = try await driver.listSchemas(database: database)
            databases[index].schemas = schemas.map { SchemaNode(database: database, name: $0) }
            databases[index].isLoaded = true

            // A single "public" schema is the common case; open it without another click.
            if schemas.count == 1 || schemas.contains("public") {
                let target = schemas.count == 1 ? schemas[0] : "public"
                expandedSchemas.insert("\(database)|\(target)")
                try await loadChildren(ofSchema: target, in: database)
            }
        } else {
            let tables = try await driver.listTables(in: SchemaRef(database: database))
            databases[index].tables = tables
            databases[index].isLoaded = true
        }
    }

    func loadChildren(ofSchema schema: String, in database: String) async throws {
        guard let driver,
              let databaseIndex = databases.firstIndex(where: { $0.name == database }),
              let schemaIndex = databases[databaseIndex].schemas.firstIndex(where: { $0.name == schema })
        else { return }
        guard !databases[databaseIndex].schemas[schemaIndex].isLoaded else { return }

        let tables = try await driver.listTables(in: SchemaRef(database: database, schema: schema))
        databases[databaseIndex].schemas[schemaIndex].tables = tables
        databases[databaseIndex].schemas[schemaIndex].isLoaded = true
    }

    /// Drops cached children so the next expansion re-reads the server.
    func invalidate(database: String) {
        guard let index = databases.firstIndex(where: { $0.name == database }) else { return }
        databases[index].isLoaded = false
        databases[index].tables = []
        databases[index].schemas = databases[index].schemas.map { schema in
            var copy = schema
            copy.isLoaded = false
            copy.tables = []
            return copy
        }
    }

    /// Every table currently loaded, used by the command palette and the export sheet.
    var allLoadedTables: [TableRef] {
        databases.flatMap { database -> [TableRef] in
            database.tables + database.schemas.flatMap(\.tables)
        }
    }

    // MARK: - Queries

    func execute(_ sql: String) async throws -> [QueryResult] {
        guard let driver else {
            throw DatabaseError(message: "Not connected.")
        }
        return try await driver.execute(sql)
    }

    static func describe(_ error: any Error) -> String {
        (error as? DatabaseError)?.errorDescription ?? error.localizedDescription
    }
}
