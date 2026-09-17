import Foundation

/// Everything needed to reach a server, minus the password (that lives in the Keychain).
public struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: DatabaseKind
    public var host: String
    public var port: Int
    public var username: String
    /// Initial database/schema to open. For SQLite this is unused.
    public var database: String
    /// Absolute path to the `.sqlite` file. Only used when `kind == .sqlite`.
    public var filePath: String
    public var sslMode: SSLMode
    /// When true the password is stored in the macOS Keychain and reused silently.
    public var savePassword: Bool
    /// Refuses to run anything that is not a read when enabled — a guard rail for production.
    public var readOnly: Bool
    /// Optional folder shown in the sidebar, e.g. "Production".
    public var folder: String
    /// Hex colour (#RRGGBB) used as an accent so prod connections are visually distinct.
    public var colorHex: String?
    public var connectTimeoutSeconds: Int
    public var notes: String
    public var createdAt: Date
    public var lastConnectedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String = "",
        kind: DatabaseKind = .postgres,
        host: String = "127.0.0.1",
        port: Int? = nil,
        username: String? = nil,
        database: String = "",
        filePath: String = "",
        sslMode: SSLMode = .prefer,
        savePassword: Bool = true,
        readOnly: Bool = false,
        folder: String = "",
        colorHex: String? = nil,
        connectTimeoutSeconds: Int = 10,
        notes: String = "",
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port ?? kind.defaultPort
        self.username = username ?? kind.defaultUser
        self.database = database
        self.filePath = filePath
        self.sslMode = sslMode
        self.savePassword = savePassword
        self.readOnly = readOnly
        self.folder = folder
        self.colorHex = colorHex
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.notes = notes
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    /// Label shown when the user has not named the connection.
    public var displayName: String {
        if !name.isEmpty { return name }
        if kind.isFileBased {
            return (filePath as NSString).lastPathComponent.isEmpty ? kind.displayName : (filePath as NSString).lastPathComponent
        }
        return "\(username)@\(host):\(port)"
    }

    public var subtitle: String {
        if kind.isFileBased { return filePath }
        let db = database.isEmpty ? "" : "/\(database)"
        return "\(host):\(port)\(db)"
    }

    /// Keychain account key. Stable across renames because it is derived from the id.
    public var keychainAccount: String { "connection-\(id.uuidString)" }

    /// Basic sanity check so the editor can disable "Save" on nonsense input.
    public var validationError: String? {
        if kind.isFileBased {
            return filePath.isEmpty ? "A database file must be selected." : nil
        }
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return "Host is required." }
        if !(1...65535).contains(port) { return "Port must be between 1 and 65535." }
        if username.trimmingCharacters(in: .whitespaces).isEmpty { return "Username is required." }
        if kind.usesMySQLProtocol == false && database.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Database is required for PostgreSQL."
        }
        return nil
    }
}
