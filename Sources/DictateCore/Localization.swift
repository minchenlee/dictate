import Foundation

/// UI language. `.system` follows macOS: any Chinese preference shows Traditional Chinese,
/// everything else shows English.
public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case traditionalChinese = "zh-Hant"
}

/// Looks up UI strings in `<code>.lproj/Localizable.strings` inside the app bundle.
/// Keys are the English text, so English needs no table and a missing translation shows English.
/// The language can change at runtime, which `NSLocalizedString` cannot do.
public enum Localizer {
    nonisolated(unsafe) public static var language: AppLanguage = .system {
        didSet { cachedCode = nil }
    }
    /// Tables by language code; tests inject one here instead of reading the bundle.
    nonisolated(unsafe) public static var tables: [String: [String: String]] = [:]
    nonisolated(unsafe) private static var cachedCode: String?

    public static func resolve(_ language: AppLanguage, preferred: [String] = Locale.preferredLanguages) -> String {
        switch language {
        case .english: return "en"
        case .traditionalChinese: return "zh-Hant"
        case .system:
            for code in preferred {
                let lower = code.lowercased()
                if lower.hasPrefix("zh") { return "zh-Hant" }
                if lower.hasPrefix("en") { return "en" }
            }
            return "en"
        }
    }

    public static var code: String {
        if let cachedCode { return cachedCode }
        let code = resolve(language)
        cachedCode = code
        return code
    }

    public static func lookup(_ key: String) -> String {
        let code = code
        guard code != "en" else { return key }
        if tables[code] == nil { tables[code] = loadTable(code) }
        return tables[code]?[key] ?? key
    }

    public static func loadTable(_ code: String, bundle: Bundle = .main) -> [String: String] {
        guard let url = bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: code)
            ?? bundle.resourceURL?.appendingPathComponent("\(code).lproj/Localizable.strings") else { return [:] }
        return parse(url)
    }

    public static func parse(_ url: URL) -> [String: String] {
        (NSDictionary(contentsOf: url) as? [String: String]) ?? [:]
    }
}

/// Localized UI string. The key is the English text.
public func L(_ key: String) -> String {
    Localizer.lookup(key)
}

/// Localized format string, e.g. `L("Hold %@ to talk", label)`.
public func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: Localizer.lookup(key), arguments: args)
}
