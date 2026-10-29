import Foundation

/// The settings a person chooses, by the key each one is stored under (and exported as).
enum SettingsKey: String, CaseIterable, CodingKey {
    case profiles, style, size, theme, glass, screen, language, showDelayMs, showBadges, showSpaceNumbers
    case previewSelectedWindow, titleContent, titleTruncation, pointerFollowsSwitch, panelAnimations
    case mouseHoverSelects, hapticFeedback, showMenuBarIcon, appExceptions, panelKeys
}

/// Every setting a person chooses, all at once: what export, import and "reset all" deal in. Window positions, one-time
/// flags and "pause shortcuts" (a state, switched from the menu bar) aren't part of it.
struct SettingsSnapshot: Equatable {
    var profiles: [ShortcutProfile]
    var style: SwitcherStyle
    var size: SwitcherSize
    var theme: ThemeMode
    var glass: GlassStyle
    var screen: ScreenChoice
    var language: AppLanguage
    var showDelayMs: Int
    var showBadges: Bool
    var showSpaceNumbers: Bool
    var previewSelectedWindow: Bool
    var titleContent: TitleContent
    var titleTruncation: TitleTruncation
    var pointerFollowsSwitch: Bool
    var panelAnimations: Bool
    var mouseHoverSelects: Bool
    var hapticFeedback: Bool
    var showMenuBarIcon: Bool
    var appExceptions: [AppException]
    var panelKeys: PanelKeyBindings

    /// A new setup's settings. Its language is the Mac's own; its shortcuts follow the Mac's Modifier Keys settings.
    static func defaults(language: AppLanguage = .system, profiles: [ShortcutProfile] = ShortcutProfile.defaults) -> SettingsSnapshot {
        SettingsSnapshot(profiles: profiles, style: .deck, size: .auto, theme: .system, glass: .regular, screen: .mouse,
                         language: language, showDelayMs: 90, showBadges: true, showSpaceNumbers: true, previewSelectedWindow: false,
                         titleContent: .windowTitle, titleTruncation: .end, pointerFollowsSwitch: false, panelAnimations: true,
                         mouseHoverSelects: true, hapticFeedback: true, showMenuBarIcon: true, appExceptions: [],
                         panelKeys: PanelKeyBindings())
    }

    /// How long the switcher may wait before it shows, in milliseconds: the range of its slider in General.
    static let showDelayRange = 0...300

    enum Reading: Equatable {
        case read
        /// A list some of whose entries couldn't be read: the others were.
        case partly
        case unreadable
    }

    /// Reads one setting from its JSON. A list keeps the entries it can read; anything else is all or nothing, and
    /// an unreadable value leaves the setting as it was. Numbers are kept in range: a shortcut that's out of it can't be
    /// read, and the appearance delay is brought into its slider's range.
    mutating func read(_ key: SettingsKey, from data: Data) -> Reading {
        func decode<T: Decodable>(_ path: WritableKeyPath<SettingsSnapshot, T>) -> Reading {
            guard let value = try? JSONDecoder().decode(T.self, from: data) else { return .unreadable }
            self[keyPath: path] = value
            return .read
        }
        func list<T>(_ path: WritableKeyPath<SettingsSnapshot, [T]>, _ decodeList: (Data) -> [T]?) -> Reading {
            guard let values = decodeList(data) else { return .unreadable }
            self[keyPath: path] = values
            return values.count == SettingsSnapshot.count(of: data) ? .read : .partly
        }
        switch key {
        case .profiles: return list(\.profiles) { ShortcutProfile.decodeList(from: $0)?.filter(\.isWithinRange) }
        case .appExceptions: return list(\.appExceptions, AppException.decodeList(from:))
        case .style: return decode(\.style)
        case .size: return decode(\.size)
        case .theme: return decode(\.theme)
        case .glass: return decode(\.glass)
        case .screen: return decode(\.screen)
        case .language: return decode(\.language)
        case .showDelayMs:
            guard let delay = try? JSONDecoder().decode(Int.self, from: data) else { return .unreadable }
            let range = SettingsSnapshot.showDelayRange
            showDelayMs = min(max(delay, range.lowerBound), range.upperBound)
            return .read
        case .showBadges: return decode(\.showBadges)
        case .showSpaceNumbers: return decode(\.showSpaceNumbers)
        case .previewSelectedWindow: return decode(\.previewSelectedWindow)
        case .titleContent: return decode(\.titleContent)
        case .titleTruncation: return decode(\.titleTruncation)
        case .pointerFollowsSwitch: return decode(\.pointerFollowsSwitch)
        case .panelAnimations: return decode(\.panelAnimations)
        case .mouseHoverSelects: return decode(\.mouseHoverSelects)
        case .hapticFeedback: return decode(\.hapticFeedback)
        case .showMenuBarIcon: return decode(\.showMenuBarIcon)
        case .panelKeys: return decode(\.panelKeys)
        }
    }

    /// One setting as JSON, the way Prefs stores it.
    func encoded(_ key: SettingsKey) -> Data {
        let encoder = JSONEncoder()
        func encode<T: Encodable>(_ value: T) -> Data { (try? encoder.encode(value)) ?? Data() }
        switch key {
        case .profiles: return encode(profiles)
        case .style: return encode(style)
        case .size: return encode(size)
        case .theme: return encode(theme)
        case .glass: return encode(glass)
        case .screen: return encode(screen)
        case .language: return encode(language)
        case .showDelayMs: return encode(showDelayMs)
        case .showBadges: return encode(showBadges)
        case .showSpaceNumbers: return encode(showSpaceNumbers)
        case .previewSelectedWindow: return encode(previewSelectedWindow)
        case .titleContent: return encode(titleContent)
        case .titleTruncation: return encode(titleTruncation)
        case .pointerFollowsSwitch: return encode(pointerFollowsSwitch)
        case .panelAnimations: return encode(panelAnimations)
        case .mouseHoverSelects: return encode(mouseHoverSelects)
        case .hapticFeedback: return encode(hapticFeedback)
        case .showMenuBarIcon: return encode(showMenuBarIcon)
        case .appExceptions: return encode(appExceptions)
        case .panelKeys: return encode(panelKeys)
        }
    }

    /// How many entries a JSON list has, whether or not they can be read.
    private static func count(of data: Data) -> Int? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [Any])?.count
    }

    /// A stored or exported value as JSON. Prefs stores JSON data; a plain value (written with `defaults write`, or by a
    /// plist editor) becomes JSON first, so it reads as long as it means something of the right type.
    static func jsonData(_ value: Any?) -> Data? {
        guard let value else { return nil }
        if let data = value as? Data { return data }
        guard JSONSerialization.isValidJSONObject([value]) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }
}

extension ShortcutProfile {
    /// Ids are small numbers given out one after another; this leaves room to count on from any of them.
    static let idRange = 0...Int(Int32.max)

    /// Every number in it is one Riffle can use: a hold it can register (see `CarbonModifiers.isValidHold`), a key that
    /// exists, and an id from `idRange`.
    var isWithinRange: Bool {
        holdModifiers.isValidHold && KeyCodes.range.contains(keyCode) && ShortcutProfile.idRange.contains(id)
    }
}

extension SettingsSnapshot: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SettingsKey.self)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(style, forKey: .style)
        try container.encode(size, forKey: .size)
        try container.encode(theme, forKey: .theme)
        try container.encode(glass, forKey: .glass)
        try container.encode(screen, forKey: .screen)
        try container.encode(language, forKey: .language)
        try container.encode(showDelayMs, forKey: .showDelayMs)
        try container.encode(showBadges, forKey: .showBadges)
        try container.encode(showSpaceNumbers, forKey: .showSpaceNumbers)
        try container.encode(previewSelectedWindow, forKey: .previewSelectedWindow)
        try container.encode(titleContent, forKey: .titleContent)
        try container.encode(titleTruncation, forKey: .titleTruncation)
        try container.encode(pointerFollowsSwitch, forKey: .pointerFollowsSwitch)
        try container.encode(panelAnimations, forKey: .panelAnimations)
        try container.encode(mouseHoverSelects, forKey: .mouseHoverSelects)
        try container.encode(hapticFeedback, forKey: .hapticFeedback)
        try container.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
        try container.encode(appExceptions, forKey: .appExceptions)
        try container.encode(panelKeys, forKey: .panelKeys)
    }
}
