import Foundation

/// What a connection string turned into. `warnings` carries anything that was understood
/// but not honoured exactly, so the editor can say so instead of silently changing meaning.
public struct ParsedConnectionURL: Sendable {
    public var profile: ConnectionProfile
    public var password: String?
    public var warnings: [String]

    public init(profile: ConnectionProfile, password: String?, warnings: [String] = []) {
        self.profile = profile
        self.password = password
        self.warnings = warnings
    }
}

public enum ConnectionURLError: LocalizedError, Equatable {
    case empty
    case unrecognisedFormat
    case unsupportedScheme(String)
    case missingHost
    case missingFilePath
    case invalidPort(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter a connection URL."
        case .unrecognisedFormat:
            return "This does not look like a connection URL. Expected something like postgres://user:password@host:5432/database."
        case .unsupportedScheme(let scheme):
            return "\"\(scheme)\" is not a database MieSQL supports. Use postgres, mysql, mariadb or sqlite."
        case .missingHost:
            return "The URL has no host."
        case .missingFilePath:
            return "The URL has no database file path."
        case .invalidPort(let port):
            return "\"\(port)\" is not a valid port number."
        }
    }
}

/// Reads and writes database connection strings.
///
/// Hand-rolled rather than `URLComponents` because real-world connection strings routinely
/// carry unencoded `@`, `:` and `/` inside the password, which `URLComponents` rejects
/// outright. Splitting on the *last* `@` before the host, and the *first* `:` inside the
/// user info, handles those the way `libpq` and the MySQL clients do.
///
/// Understood forms:
/// - `postgres://user:pass@host:5432/db?sslmode=require`
/// - `mysql://user@host/db`, `mariadb://…`
/// - `jdbc:postgresql://host/db`
/// - `sqlite:///absolute/path.db`, `file:///absolute/path.db`, or a bare filesystem path
/// - libpq keyword form: `host=… port=… dbname=… user=… password=…`
public enum ConnectionURLParser {

    // MARK: - Parsing

    public static func parse(_ rawInput: String) throws -> ParsedConnectionURL {
        let input = clean(rawInput)
        guard !input.isEmpty else { throw ConnectionURLError.empty }

        // `host=… dbname=…` — common in .env files and PostgreSQL docs.
        if !input.contains("://"), input.contains("="), !looksLikePath(input) {
            return try parseKeywordValue(input)
        }

        // A bare path is the friendliest way to add a SQLite file.
        if looksLikePath(input) {
            return sqliteResult(path: expandTilde(input), query: [:])
        }

        var body = input
        // JDBC prefixes wrap an otherwise ordinary URL.
        if body.lowercased().hasPrefix("jdbc:") {
            body = String(body.dropFirst("jdbc:".count))
        }

        guard let schemeEnd = body.range(of: ":") else {
            throw ConnectionURLError.unrecognisedFormat
        }
        let scheme = String(body[body.startIndex..<schemeEnd.lowerBound]).lowercased()
        var remainder = String(body[schemeEnd.upperBound...])
        // `scheme://rest` and `scheme:rest` are both seen in the wild.
        if remainder.hasPrefix("//") {
            remainder = String(remainder.dropFirst(2))
        }

        guard let kind = kind(forScheme: scheme) else {
            throw ConnectionURLError.unsupportedScheme(scheme)
        }

        // Split the query off first; everything before it is authority plus path.
        var authorityAndPath = remainder
        var query: [String: String] = [:]
        if let questionMark = remainder.firstIndex(of: "?") {
            authorityAndPath = String(remainder[remainder.startIndex..<questionMark])
            query = parseQuery(String(remainder[remainder.index(after: questionMark)...]))
        }

        if kind.isFileBased {
            // `sqlite:///abs/path` leaves an empty authority and an absolute path;
            // `sqlite://./rel.db` puts the first segment in the authority.
            var path = authorityAndPath
            if path.hasPrefix("/") == false, path.hasPrefix("~") == false, !path.isEmpty {
                path = "/" + path
                // Restore a relative path that was written without a leading slash.
                if authorityAndPath.hasPrefix(".") { path = authorityAndPath }
            }
            let expanded = expandTilde(percentDecoded(path))
            guard !expanded.isEmpty, expanded != "/" else { throw ConnectionURLError.missingFilePath }
            return sqliteResult(path: expanded, query: query)
        }

        // Authority ends at the first `/` that follows the user info.
        let lastAt = authorityAndPath.lastIndex(of: "@")
        let searchStart = lastAt.map { authorityAndPath.index(after: $0) } ?? authorityAndPath.startIndex
        let pathStart = authorityAndPath[searchStart...].firstIndex(of: "/")

        let authorityEnd = pathStart ?? authorityAndPath.endIndex
        var database = ""
        if let pathStart {
            database = percentDecoded(String(authorityAndPath[authorityAndPath.index(after: pathStart)...]))
        }

        var username = ""
        var password: String?
        // Everything between the user info and the path is host and port. With no `@`,
        // `searchStart` is already the start of the string.
        let hostPort = String(authorityAndPath[searchStart..<authorityEnd])

        if let lastAt {
            let userInfo = authorityAndPath[authorityAndPath.startIndex..<lastAt]
            // The password may itself contain `:`, so only the first one separates.
            if let colon = userInfo.firstIndex(of: ":") {
                username = percentDecoded(String(userInfo[userInfo.startIndex..<colon]))
                password = percentDecoded(String(userInfo[userInfo.index(after: colon)...]))
            } else {
                username = percentDecoded(String(userInfo))
            }
        }

        let (host, port) = try splitHostAndPort(hostPort, default: kind.defaultPort)

        var warnings: [String] = []
        var profile = ConnectionProfile(kind: kind)
        profile.host = host.isEmpty ? "127.0.0.1" : host
        profile.port = port
        profile.username = username
        profile.database = database

        // `postgres://user@host/` means "connect to the database named after the user",
        // which is what libpq does when dbname is omitted.
        if kind == .postgres, profile.database.isEmpty, !username.isEmpty {
            profile.database = username
            warnings.append("No database in the URL, so the username was used — the same default libpq applies.")
        }

        apply(query: query, to: &profile, warnings: &warnings)
        profile.name = suggestedName(for: profile)
        profile.savePassword = password != nil

        return ParsedConnectionURL(profile: profile, password: password, warnings: warnings)
    }

    // MARK: - Serialising

    /// Rebuilds a URL from a profile. The password is left out unless asked for, so
    /// "Copy Connection URL" is safe to paste into a ticket.
    public static func string(
        for profile: ConnectionProfile,
        password: String? = nil,
        includePassword: Bool = false
    ) -> String {
        if profile.kind.isFileBased {
            return "sqlite://" + profile.filePath
        }

        var url = scheme(for: profile.kind) + "://"
        if !profile.username.isEmpty {
            url += encode(profile.username)
            if includePassword, let password, !password.isEmpty {
                url += ":" + encode(password)
            }
            url += "@"
        }
        url += profile.host.contains(":") ? "[\(profile.host)]" : profile.host
        if profile.port != profile.kind.defaultPort {
            url += ":\(profile.port)"
        }
        if !profile.database.isEmpty {
            url += "/" + encode(profile.database)
        }

        var parameters: [String] = []
        if profile.sslMode != .prefer {
            parameters.append("sslmode=\(profile.sslMode.rawValue)")
        }
        if profile.readOnly {
            parameters.append("readonly=true")
        }
        if !parameters.isEmpty {
            url += "?" + parameters.joined(separator: "&")
        }
        return url
    }

    /// True when the text stands a chance of parsing, used to decide whether to offer the
    /// clipboard's contents.
    public static func looksLikeConnectionURL(_ text: String) -> Bool {
        let cleaned = clean(text)
        guard !cleaned.isEmpty, cleaned.count < 2048, !cleaned.contains("\n") else { return false }
        if looksLikePath(cleaned) { return true }
        if cleaned.contains("host=") && cleaned.contains("=") { return true }
        guard let schemeEnd = cleaned.range(of: ":") else { return false }
        let scheme = cleaned[cleaned.startIndex..<schemeEnd.lowerBound].lowercased()
        return kind(forScheme: scheme.hasPrefix("jdbc") ? String(scheme.dropFirst(5)) : String(scheme)) != nil
            || cleaned.lowercased().hasPrefix("jdbc:")
    }

    // MARK: - Pieces

    private static func kind(forScheme scheme: String) -> DatabaseKind? {
        switch scheme {
        case "postgres", "postgresql", "psql", "pgsql":
            return .postgres
        case "mysql", "mysqlx":
            return .mysql
        case "mariadb":
            return .mariadb
        case "sqlite", "sqlite3", "file":
            return .sqlite
        default:
            return nil
        }
    }

    private static func scheme(for kind: DatabaseKind) -> String {
        switch kind {
        case .postgres: return "postgres"
        case .mysql: return "mysql"
        case .mariadb: return "mariadb"
        case .sqlite: return "sqlite"
        }
    }

    private static func splitHostAndPort(_ input: String, default defaultPort: Int) throws -> (String, Int) {
        guard !input.isEmpty else { return ("", defaultPort) }

        // Bracketed IPv6: [::1]:5432
        if input.hasPrefix("["), let closing = input.firstIndex(of: "]") {
            let host = String(input[input.index(after: input.startIndex)..<closing])
            let rest = input[input.index(after: closing)...]
            guard rest.hasPrefix(":") else { return (host, defaultPort) }
            let portText = String(rest.dropFirst())
            guard let port = Int(portText), (1...65535).contains(port) else {
                throw ConnectionURLError.invalidPort(portText)
            }
            return (host, port)
        }

        // A comma-separated host list is a failover list; the first entry is the one to use.
        var candidate = input
        if let comma = candidate.firstIndex(of: ",") {
            candidate = String(candidate[candidate.startIndex..<comma])
        }

        guard let colon = candidate.lastIndex(of: ":") else {
            return (percentDecoded(candidate), defaultPort)
        }
        // A bare, unbracketed IPv6 address has several colons and no port.
        if candidate.filter({ $0 == ":" }).count > 1 {
            return (percentDecoded(candidate), defaultPort)
        }
        let portText = String(candidate[candidate.index(after: colon)...])
        guard let port = Int(portText), (1...65535).contains(port) else {
            throw ConnectionURLError.invalidPort(portText)
        }
        return (percentDecoded(String(candidate[candidate.startIndex..<colon])), port)
    }

    private static func apply(query: [String: String], to profile: inout ConnectionProfile, warnings: inout [String]) {
        for (rawKey, rawValue) in query {
            let key = rawKey.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
            let value = rawValue.lowercased()

            switch key {
            case "sslmode", "ssl", "usessl", "tls", "tlsmode", "sslaccept":
                if let mode = sslMode(from: value, warnings: &warnings) {
                    profile.sslMode = mode
                }
            case "connecttimeout", "timeout", "connecttimeoutms":
                if let seconds = Int(value) {
                    // Some drivers express this in milliseconds; anything huge is clearly that.
                    profile.connectTimeoutSeconds = seconds > 600 ? max(1, seconds / 1000) : max(1, seconds)
                }
            case "mode":
                if value == "ro" { profile.readOnly = true }
            case "readonly", "immutable":
                if ["true", "1", "yes"].contains(value) { profile.readOnly = true }
            case "user", "username", "uid":
                if profile.username.isEmpty { profile.username = rawValue }
            case "password", "pwd":
                // Deliberately ignored here: the caller decides what to do with secrets,
                // and the password from the user-info section already took priority.
                break
            case "dbname", "database", "db":
                if profile.database.isEmpty { profile.database = rawValue }
            case "host", "server", "hostaddr":
                if profile.host.isEmpty || profile.host == "127.0.0.1" { profile.host = rawValue }
            case "port":
                if let port = Int(value), (1...65535).contains(port) { profile.port = port }
            case "applicationname", "appname":
                if profile.name.isEmpty { profile.name = rawValue }
            default:
                continue
            }
        }
    }

    private static func sslMode(from value: String, warnings: inout [String]) -> SSLMode? {
        switch value {
        case "disable", "disabled", "false", "0", "no", "off", "skip":
            return .disable
        case "allow", "prefer", "preferred", "true", "1", "yes", "on":
            return .prefer
        case "require", "required", "skipverify", "skip-verify":
            return .require
        case "verifyca", "verify-ca", "verifyfull", "verify-full", "verifyidentity":
            warnings.append("Certificate verification is not implemented yet, so \"\(value)\" was treated as Require: the connection is encrypted but the server's certificate is not validated.")
            return .require
        default:
            return nil
        }
    }

    /// libpq's `host=localhost port=5432 dbname=app` form.
    private static func parseKeywordValue(_ input: String) throws -> ParsedConnectionURL {
        var pairs: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var quote: Character?
        var iterator = input.startIndex

        func commit() {
            let trimmedKey = key.trimmingCharacters(in: .whitespaces)
            if !trimmedKey.isEmpty { pairs[trimmedKey.lowercased()] = value }
            key = ""
            value = ""
            readingKey = true
        }

        while iterator < input.endIndex {
            let character = input[iterator]
            if let active = quote {
                if character == "\\", input.index(after: iterator) < input.endIndex {
                    iterator = input.index(after: iterator)
                    value.append(input[iterator])
                } else if character == active {
                    quote = nil
                } else {
                    value.append(character)
                }
            } else if readingKey {
                if character == "=" {
                    readingKey = false
                } else if character.isWhitespace {
                    if !key.isEmpty { commit() }
                } else {
                    key.append(character)
                }
            } else {
                if character == "'" || character == "\"" {
                    quote = character
                } else if character.isWhitespace {
                    commit()
                } else {
                    value.append(character)
                }
            }
            iterator = input.index(after: iterator)
        }
        if !key.isEmpty { commit() }

        guard !pairs.isEmpty else { throw ConnectionURLError.unrecognisedFormat }

        var warnings: [String] = []
        var profile = ConnectionProfile(kind: .postgres)
        profile.host = pairs["host"] ?? pairs["hostaddr"] ?? "127.0.0.1"
        profile.port = pairs["port"].flatMap(Int.init) ?? DatabaseKind.postgres.defaultPort
        profile.username = pairs["user"] ?? pairs["username"] ?? ""
        profile.database = pairs["dbname"] ?? pairs["database"] ?? profile.username

        var queryLike: [String: String] = [:]
        for (pairKey, pairValue) in pairs where !["host", "hostaddr", "port", "user", "username", "dbname", "database", "password"].contains(pairKey) {
            queryLike[pairKey] = pairValue
        }
        apply(query: queryLike, to: &profile, warnings: &warnings)

        let password = pairs["password"]
        profile.savePassword = password != nil
        profile.name = suggestedName(for: profile)

        return ParsedConnectionURL(profile: profile, password: password, warnings: warnings)
    }

    private static func sqliteResult(path: String, query: [String: String]) -> ParsedConnectionURL {
        var warnings: [String] = []
        var profile = ConnectionProfile(kind: .sqlite)
        profile.filePath = path
        profile.savePassword = false
        apply(query: query, to: &profile, warnings: &warnings)
        profile.name = suggestedName(for: profile)
        return ParsedConnectionURL(profile: profile, password: nil, warnings: warnings)
    }

    private static func suggestedName(for profile: ConnectionProfile) -> String {
        if profile.kind.isFileBased {
            return (profile.filePath as NSString).deletingPathExtension.components(separatedBy: "/").last ?? "SQLite"
        }
        if !profile.database.isEmpty { return profile.database }
        return profile.host
    }

    // MARK: - Text helpers

    private static func clean(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate a value copied straight out of a shell or .env file.
        for wrapper in ["\"", "'", "`"] where text.hasPrefix(wrapper) && text.hasSuffix(wrapper) && text.count > 1 {
            text = String(text.dropFirst().dropLast())
        }
        for prefix in ["DATABASE_URL=", "database_url=", "export DATABASE_URL="] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            return clean(text)
        }
        return text
    }

    private static func looksLikePath(_ input: String) -> Bool {
        guard !input.contains("://") else { return false }
        if input.hasPrefix("/") || input.hasPrefix("~/") || input.hasPrefix("./") { return true }
        let lowered = input.lowercased()
        return [".sqlite", ".sqlite3", ".db"].contains { lowered.hasSuffix($0) }
    }

    private static func expandTilde(_ path: String) -> String {
        path.hasPrefix("~") ? (path as NSString).expandingTildeInPath : path
    }

    private static func parseQuery(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            guard let equals = pair.firstIndex(of: "=") else {
                result[percentDecoded(String(pair))] = ""
                continue
            }
            let key = percentDecoded(String(pair[pair.startIndex..<equals]))
            let value = percentDecoded(String(pair[pair.index(after: equals)...]))
            result[key] = value
        }
        return result
    }

    private static func percentDecoded(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    private static func encode(_ value: String) -> String {
        // Only the unreserved set is left alone, which keeps `@`, `:`, `/` and `?` safe
        // wherever the component lands.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
