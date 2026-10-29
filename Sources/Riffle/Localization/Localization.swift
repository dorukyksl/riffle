import Foundation

/// The 21 languages Riffle speaks. Raw values are what the setting saves and name the translation tables.
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case en, tr, ar, de, es, fr, he, id, it, ja, ko, nl, pl
    case ptBR = "pt-BR"
    case ru, sv, th, vi
    case zhCN = "zh-CN"
    case zhHK = "zh-HK"
    case zhTW = "zh-TW"

    var id: String { rawValue }

    /// The language's name for itself, as the picker shows it.
    var nativeName: String {
        switch self {
        case .en: return "English"
        case .tr: return "Türkçe"
        case .ar: return "العربية"
        case .de: return "Deutsch"
        case .es: return "Español"
        case .fr: return "Français"
        case .he: return "עברית"
        case .id: return "Bahasa Indonesia"
        case .it: return "Italiano"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .nl: return "Nederlands"
        case .pl: return "Polski"
        case .ptBR: return "Português (Brasil)"
        case .ru: return "Русский"
        case .sv: return "Svenska"
        case .th: return "ไทย"
        case .vi: return "Tiếng Việt"
        case .zhCN: return "简体中文"
        case .zhHK: return "繁體中文（香港）"
        case .zhTW: return "繁體中文（台灣）"
        }
    }

    var isRightToLeft: Bool { self == .ar || self == .he }

    var locale: Locale { Locale(identifier: rawValue) }

    /// In the picker: Latin scripts first, then the others, each group in its own alphabetical order.
    static var pickerOrder: [AppLanguage] {
        let latin: Set<AppLanguage> = [.en, .tr, .de, .es, .fr, .id, .it, .nl, .pl, .ptBR, .sv, .vi]
        let sorted = allCases.sorted { $0.nativeName.localizedStandardCompare($1.nativeName) == .orderedAscending }
        return sorted.filter(latin.contains) + sorted.filter { !latin.contains($0) }
    }

    /// The first of the Mac's preferred languages that Riffle speaks; English otherwise.
    static var system: AppLanguage {
        Locale.preferredLanguages.lazy.compactMap(AppLanguage.matching).first ?? .en
    }

    /// The language for a BCP 47 identifier such as "de-DE", "pt-PT", "zh-Hant-HK" or the old "iw".
    static func matching(_ identifier: String) -> AppLanguage? {
        let lower = identifier.lowercased().replacingOccurrences(of: "_", with: "-")
        let parts = lower.split(separator: "-").map(String.init)
        guard let code = parts.first else { return nil }
        switch code {
        case "zh":
            if parts.contains("hk") || parts.contains("mo") { return .zhHK }
            if parts.contains("hant") || parts.contains("tw") { return .zhTW }
            return .zhCN
        // The only Portuguese there is.
        case "pt": return .ptBR
        // Old codes still sent by some systems.
        case "iw": return .he
        case "in": return .id
        default: return AppLanguage(rawValue: code)
        }
    }
}

/// Every user-facing string is written inline as a Turkish/English pair: `L.t("Ayarlar", "Settings")`. The other
/// languages look the English up in their table (`Translations`); anything missing stays in English.
enum L {
    static func t(_ turkish: String, _ english: String) -> String {
        text(turkish, english, in: Prefs.shared.language)
    }

    /// Text with values in it: `%1$@`, `%2$@`… in both languages, filled with `values` as written (digits stay as they are).
    static func f(_ turkish: String, _ english: String, _ values: CustomStringConvertible...) -> String {
        format(t(turkish, english), values)
    }

    /// Whole sentences one after another, the way the language joins them: Chinese and Japanese end each with 。 and put
    /// no space between them, the others a space.
    static func sentences(_ parts: [String]) -> String {
        sentences(parts, in: Prefs.shared.language)
    }

    static func sentences(_ parts: [String], in language: AppLanguage) -> String {
        let separator = [.ja, .zhCN, .zhHK, .zhTW].contains(language) ? "" : " "
        return parts.filter { !$0.isEmpty }.joined(separator: separator)
    }

    /// Names in a list, the way the language writes one ("A, B and C", "A、B、C").
    static func list(_ items: [String], in language: AppLanguage = Prefs.shared.language) -> String {
        let formatter = ListFormatter()
        formatter.locale = language.locale
        return formatter.string(from: items) ?? items.joined(separator: ", ")
    }

    /// `values` go to `%1$@`, `%2$@`… wherever a language puts them in `template`.
    static func format(_ template: String, _ values: [CustomStringConvertible]) -> String {
        String(format: template, arguments: values.map { $0.description as NSString })
    }

    static func text(_ turkish: String, _ english: String, in language: AppLanguage) -> String {
        switch language {
        case .tr: return turkish
        case .en: return english
        default: return Translations.table(for: language)[english] ?? english
        }
    }
}
