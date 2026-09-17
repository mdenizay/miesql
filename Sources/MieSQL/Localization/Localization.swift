import Foundation

/// The languages MieSQL ships with. English is the source language: every key is written
/// in English first, and a missing translation falls back to it rather than showing a key.
///
/// Adding a language means adding a case here and one dictionary in `Translations`.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case turkish = "tr"

    public var id: String { rawValue }

    /// Shown in the language picker, always in the language itself.
    public var displayName: String {
        switch self {
        case .system: return "System"
        case .english: return "English"
        case .turkish: return "Türkçe"
        }
    }

    /// Resolves `.system` against the user's macOS language preferences.
    public static func resolve(_ code: String) -> AppLanguage {
        if let explicit = AppLanguage(rawValue: code), explicit != .system {
            return explicit
        }
        for preferred in Locale.preferredLanguages {
            let base = preferred.split(separator: "-").first.map(String.init) ?? preferred
            if let match = AppLanguage(rawValue: base), match != .system {
                return match
            }
        }
        return .english
    }
}

/// Lookup for the current language. Held by `AppModel` so switching language re-renders
/// every view without a relaunch.
public struct Localizer: Sendable, Equatable {
    public let language: AppLanguage

    public init(language: AppLanguage) {
        self.language = language
    }

    public func callAsFunction(_ key: String) -> String {
        Translations.table[language]?[key] ?? Translations.table[.english]?[key] ?? key
    }

    /// Interpolating variant: `t("rows.count", 12)` fills the `%@` placeholders in order.
    public func callAsFunction(_ key: String, _ arguments: CustomStringConvertible...) -> String {
        var text = callAsFunction(key)
        for argument in arguments {
            guard let range = text.range(of: "%@") else { break }
            text.replaceSubrange(range, with: argument.description)
        }
        return text
    }
}
