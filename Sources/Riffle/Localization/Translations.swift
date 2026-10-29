/// The translations, keyed by the English text. The tables live in `Translations/`, one file per language, written by
/// `Scripts/l10n.py` from `Localization/strings/*.json`; edit the JSON, not the Swift.
enum Translations {
    static func table(for language: AppLanguage) -> [String: String] {
        switch language {
        case .en, .tr: return [:]
        case .ar: return ar
        case .de: return de
        case .es: return es
        case .fr: return fr
        case .he: return he
        case .id: return id
        case .it: return it
        case .ja: return ja
        case .ko: return ko
        case .nl: return nl
        case .pl: return pl
        case .ptBR: return ptBR
        case .ru: return ru
        case .sv: return sv
        case .th: return th
        case .vi: return vi
        case .zhCN: return zhCN
        case .zhHK: return zhHK
        case .zhTW: return zhTW
        }
    }
}
