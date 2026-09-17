import Foundation

public enum AppearanceMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }
}

/// User preferences. Plain Codable JSON rather than UserDefaults so the whole of MieSQL's
/// state sits in one inspectable folder.
public struct AppSettings: Codable, Sendable, Equatable {
    public var appearance: AppearanceMode
    /// BCP-47 language tag, or "system" to follow macOS.
    public var languageCode: String
    public var editorFontSize: Double
    public var gridFontSize: Double
    /// Rows fetched per page in the data browser.
    public var pageSize: Int
    /// Rows a query tab will hold before it stops fetching, as a safety net on huge tables.
    public var maxResultRows: Int
    public var confirmDestructiveStatements: Bool
    public var autoCommit: Bool
    public var queryTimeoutSeconds: Int
    public var historyLimit: Int
    public var showLineNumbers: Bool
    public var wrapLongLines: Bool
    public var restoreTabsOnLaunch: Bool

    public init(
        appearance: AppearanceMode = .system,
        languageCode: String = "system",
        editorFontSize: Double = 13,
        gridFontSize: Double = 12,
        pageSize: Int = 200,
        maxResultRows: Int = 50_000,
        confirmDestructiveStatements: Bool = true,
        autoCommit: Bool = true,
        queryTimeoutSeconds: Int = 0,
        historyLimit: Int = 500,
        showLineNumbers: Bool = true,
        wrapLongLines: Bool = false,
        restoreTabsOnLaunch: Bool = true
    ) {
        self.appearance = appearance
        self.languageCode = languageCode
        self.editorFontSize = editorFontSize
        self.gridFontSize = gridFontSize
        self.pageSize = pageSize
        self.maxResultRows = maxResultRows
        self.confirmDestructiveStatements = confirmDestructiveStatements
        self.autoCommit = autoCommit
        self.queryTimeoutSeconds = queryTimeoutSeconds
        self.historyLimit = historyLimit
        self.showLineNumbers = showLineNumbers
        self.wrapLongLines = wrapLongLines
        self.restoreTabsOnLaunch = restoreTabsOnLaunch
    }

    // Decoding tolerates missing keys so a settings file written by an older build still loads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        appearance = try container.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? defaults.appearance
        languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode) ?? defaults.languageCode
        editorFontSize = try container.decodeIfPresent(Double.self, forKey: .editorFontSize) ?? defaults.editorFontSize
        gridFontSize = try container.decodeIfPresent(Double.self, forKey: .gridFontSize) ?? defaults.gridFontSize
        pageSize = try container.decodeIfPresent(Int.self, forKey: .pageSize) ?? defaults.pageSize
        maxResultRows = try container.decodeIfPresent(Int.self, forKey: .maxResultRows) ?? defaults.maxResultRows
        confirmDestructiveStatements = try container.decodeIfPresent(Bool.self, forKey: .confirmDestructiveStatements) ?? defaults.confirmDestructiveStatements
        autoCommit = try container.decodeIfPresent(Bool.self, forKey: .autoCommit) ?? defaults.autoCommit
        queryTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .queryTimeoutSeconds) ?? defaults.queryTimeoutSeconds
        historyLimit = try container.decodeIfPresent(Int.self, forKey: .historyLimit) ?? defaults.historyLimit
        showLineNumbers = try container.decodeIfPresent(Bool.self, forKey: .showLineNumbers) ?? defaults.showLineNumbers
        wrapLongLines = try container.decodeIfPresent(Bool.self, forKey: .wrapLongLines) ?? defaults.wrapLongLines
        restoreTabsOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .restoreTabsOnLaunch) ?? defaults.restoreTabsOnLaunch
    }
}

public final class SettingsStore: @unchecked Sendable {
    private let fileURL: URL

    public init(fileURL: URL = AppPaths.settingsFile) {
        self.fileURL = fileURL
    }

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    public func save(_ settings: AppSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
