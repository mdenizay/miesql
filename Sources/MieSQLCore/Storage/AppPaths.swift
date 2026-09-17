import Foundation

/// Every file MieSQL writes lives under one folder in Application Support, so "all data
/// stays on this device" is something a user can verify by looking at a single directory.
public enum AppPaths {

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("MieSQL", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static var connectionsFile: URL {
        supportDirectory.appendingPathComponent("connections.json")
    }

    public static var settingsFile: URL {
        supportDirectory.appendingPathComponent("settings.json")
    }

    public static var historyFile: URL {
        supportDirectory.appendingPathComponent("query-history.json")
    }

    public static var snippetsFile: URL {
        supportDirectory.appendingPathComponent("snippets.json")
    }

    public static var logsDirectory: URL {
        let directory = supportDirectory.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
