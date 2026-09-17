import Foundation

/// The database engines MieSQL can talk to.
public enum DatabaseKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case postgres
    case mysql
    case mariadb
    case sqlite

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .postgres: return "PostgreSQL"
        case .mysql: return "MySQL"
        case .mariadb: return "MariaDB"
        case .sqlite: return "SQLite"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .postgres: return 5432
        case .mysql, .mariadb: return 3306
        case .sqlite: return 0
        }
    }

    /// SQLite lives in a file; the others live behind a socket.
    public var isFileBased: Bool { self == .sqlite }

    /// MySQL and MariaDB share a wire protocol, so they share a driver.
    public var usesMySQLProtocol: Bool { self == .mysql || self == .mariadb }

    public var defaultUser: String {
        switch self {
        case .postgres: return "postgres"
        case .mysql, .mariadb: return "root"
        case .sqlite: return ""
        }
    }

    /// SF Symbol used across the sidebar and connection editor.
    public var symbolName: String {
        switch self {
        case .postgres: return "elephant"
        case .mysql: return "dolphin"
        case .mariadb: return "tortoise"
        case .sqlite: return "shippingbox"
        }
    }

    /// Fallback symbol for macOS versions missing the playful ones above.
    public var fallbackSymbolName: String { "cylinder.split.1x2" }
}

/// How a connection should negotiate TLS.
public enum SSLMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case disable
    case prefer
    case require

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .disable: return "Disable"
        case .prefer: return "Prefer"
        case .require: return "Require"
        }
    }
}
