import Foundation

/// Looks up user-facing text. The Simplified Chinese source text is the key;
/// English lives in the app bundle's en.lproj/Localizable.strings
/// (`python3 scripts/localize.py check` lists anything missing).
/// Without a bundle (tests, command-line tools) the Chinese key is returned.
@inlinable
public func L(_ key: String.LocalizationValue) -> String {
    String(localized: key)
}

/// The language the interface is showing, for text built outside the strings table
/// (the AI tutor's reply language, date styles).
public enum AppLanguage: String, Sendable {
    case chinese = "zh-Hans", english = "en"

    /// Fixed for the life of the process (switching languages relaunches the app).
    public static let current: AppLanguage = {
        let bundle = Bundle.main
        guard bundle.localizations.contains("en") else { return .chinese }
        return bundle.preferredLocalizations.first?.hasPrefix("zh") == true ? .chinese : .english
    }()

    /// Dates and numbers in the interface language: Chinese formats for Chinese,
    /// otherwise the user's own English region (or US English).
    public var displayLocale: Locale {
        if self == .chinese { return Locale(identifier: "zh_CN") }
        let current = Locale.current
        return current.language.languageCode == .english ? current : Locale(identifier: "en_US")
    }

    /// The name Claude is told to answer in.
    public var replyLanguage: String { self == .chinese ? "Simplified Chinese" : "English" }
}
