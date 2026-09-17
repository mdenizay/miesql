import Foundation

/// Reads and writes the connection list. Writes go through a temporary file so an
/// interrupted save can never leave a half-written connections.json behind.
public final class ConnectionStore: @unchecked Sendable {

    private let fileURL: URL
    private let queue = DispatchQueue(label: "app.miesql.connection-store")

    public init(fileURL: URL = AppPaths.connectionsFile) {
        self.fileURL = fileURL
    }

    public func load() -> [ConnectionProfile] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([ConnectionProfile].self, from: data)) ?? []
        }
    }

    public func save(_ profiles: [ConnectionProfile]) throws {
        try queue.sync {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(profiles)

            let temporaryURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: temporaryURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)

            // The file can hold host names and usernames, so keep it readable only by its owner.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    /// Exports profiles for sharing or backup. Passwords are never included.
    public func exportJSON(_ profiles: [ConnectionProfile]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(profiles)
    }

    public func importJSON(_ data: Data) throws -> [ConnectionProfile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let imported = try decoder.decode([ConnectionProfile].self, from: data)
        // Fresh ids on import, so re-importing the same file never overwrites a live profile
        // or hands one connection another's Keychain entry.
        return imported.map { profile in
            var copy = profile
            copy.id = UUID()
            copy.savePassword = false
            return copy
        }
    }
}
