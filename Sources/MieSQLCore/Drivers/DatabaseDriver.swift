import Foundation

/// What a driver needs to open a connection. The password is passed in rather than read
/// from the Keychain here, so the core stays testable and free of UI concerns.
public struct ConnectionCredentials: Sendable {
    public let profile: ConnectionProfile
    public let password: String?

    public init(profile: ConnectionProfile, password: String?) {
        self.profile = profile
        self.password = password
    }
}

/// The contract every engine implements. Each conforming type is an actor, so one live
/// connection serialises its own traffic while several connections run in parallel.
public protocol DatabaseDriver: Actor {
    var kind: DatabaseKind { get }
    var isConnected: Bool { get }

    func connect() async throws -> ServerInfo
    func disconnect() async

    /// Runs a script, returning one result per statement.
    func execute(_ sql: String) async throws -> [QueryResult]

    /// Databases visible to this login. SQLite reports a single synthetic entry.
    func listDatabases() async throws -> [String]
    /// Schemas inside a database. Empty for engines without a schema level.
    func listSchemas(database: String) async throws -> [String]
    func listTables(in ref: SchemaRef) async throws -> [TableRef]
    func describe(table: TableRef) async throws -> TableDetails
    /// `CREATE TABLE` text for the DDL tab.
    func createStatement(for table: TableRef) async throws -> String
    /// Switches the active database without reconnecting, where the engine allows it.
    func use(database: String) async throws
}

public extension DatabaseDriver {
    /// Convenience used by the data browser and the exporters.
    func fetchRows(
        table: TableRef,
        whereClause: String = "",
        orderBy: [(column: String, ascending: Bool)] = [],
        limit: Int,
        offset: Int
    ) async throws -> QueryResult {
        let dialect = SQLDialect(kind: kind)
        let sql = dialect.selectStatement(
            table: table,
            whereClause: whereClause,
            orderBy: orderBy,
            limit: limit,
            offset: offset
        )
        let results = try await execute(sql)
        guard let first = results.first else {
            throw DatabaseError(message: "The server returned no result for the row query.")
        }
        return first
    }

    func countRows(table: TableRef, whereClause: String = "") async throws -> Int {
        let dialect = SQLDialect(kind: kind)
        let results = try await execute(dialect.countStatement(table: table, whereClause: whereClause))
        guard let value = results.first?.rows.first?.values.first?.stringValue, let count = Int(value) else {
            return 0
        }
        return count
    }
}

/// Builds the right driver for a profile.
public enum DriverFactory {
    public static func makeDriver(for credentials: ConnectionCredentials) -> any DatabaseDriver {
        switch credentials.profile.kind {
        case .postgres:
            return PostgresDriver(credentials: credentials)
        case .mysql, .mariadb:
            return MySQLDriver(credentials: credentials)
        case .sqlite:
            return SQLiteDriver(credentials: credentials)
        }
    }
}
