import Cocoa
import Combine

enum SwitcherStyle: String, Codable, CaseIterable {
    case deck, stage, appIcons, titles, list

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // "thumbnails", the old grid, grew into the deck.
        self = SwitcherStyle(rawValue: raw) ?? .deck
    }
}
/// `auto` sizes the deck's previews by how many windows there are: big for a few, smaller until all of them fit.
enum SwitcherSize: String, Codable, CaseIterable { case auto, small, medium, large }
enum ThemeMode: String, Codable, CaseIterable { case system, dark, light }
enum GlassStyle: String, Codable, CaseIterable { case regular, clear }
enum ScreenChoice: String, Codable, CaseIterable { case mouse, activeWindow, main }

/// Whose windows and where in one setting, as older versions saved it (now `AppScope` and `PlaceScope`).
enum WindowScope: String, Codable, CaseIterable {
    case allWindows, activeApp, currentSpace, currentScreen
}

/// One switcher shortcut: hold `holdModifiers`, press `keyCode` to summon and cycle; add ⇧ to go backwards.
struct ShortcutProfile: Codable, Equatable, Identifiable {
    var id: Int
    var isEnabled: Bool
    var holdModifiers: CarbonModifiers
    var keyCode: UInt32
    /// Which windows it lists and how: see ShortcutOptions.swift, which also reads and writes settings of older versions
    /// (one `scope` and three switches).
    var apps: AppScope = .allApps
    var place: PlaceScope = .allDesktops
    var order: WindowOrder = .recentlyUsed
    /// Only each app's most recently used window.
    var onePerApp = false
    var minimized: ShowOption = .show
    var hiddenApps: ShowOption = .show
    var windowlessApps: ShowOption = .hide
    var showFullscreen = true
    /// Its own style; nil: the one chosen in Appearance.
    var style: SwitcherStyle?
    /// Opens straight into search and stays open after the modifiers are released.
    var startInSearch = false
    /// What letting go of the hold key does.
    var releaseBehavior: ReleaseBehavior = .switchToSelected

    // `holdModifiers` are the keys as macOS reports them, after any change in System Settings → Keyboard → Modifier Keys:
    // what the menus of every app show, and what the shortcut listens to.
    var description: String { KeyCodes.shortcutDescription(modifiers: holdModifiers, keyCode: keyCode) }
    /// Whether this shortcut is the system's own ⌘⇥, which then has to be switched off.
    var usesCommandTab: Bool { keyCode == KeyCodes.tab && holdModifiers.contains(.command) }

    /// Up to nine shortcuts, each with its own keys and filters.
    static let maximum = 9

    /// A shortcut added in Settings: off until it's given keys of its own (the first key no other shortcut uses with the
    /// usual hold key, if there is one), showing every window.
    static func added(id: Int, besides existing: [ShortcutProfile]) -> ShortcutProfile {
        let hold = CarbonModifiers.option
        let free = [KeyCodes.tab, KeyCodes.keyAboveTab, KeyCodes.space].first { key in
            !existing.contains { $0.holdModifiers == hold && $0.keyCode == key }
        }
        return ShortcutProfile(id: id, isEnabled: false, holdModifiers: hold, keyCode: free ?? KeyCodes.tab, scope: .allWindows,
                               showMinimized: true, showHidden: true, showWindowlessApps: false, startInSearch: false)
    }

    /// Out of the box: ⌥⇥, which leaves macOS's own ⌘⇥ alone. ⌘⇥ is one click away in the welcome window and in Settings.
    static var defaults: [ShortcutProfile] {
        let hold = CarbonModifiers.option
        return [
            ShortcutProfile(id: 0, isEnabled: true, holdModifiers: hold, keyCode: KeyCodes.tab, scope: .allWindows,
                            showMinimized: true, showHidden: true, showWindowlessApps: true, startInSearch: false),
            ShortcutProfile(id: 1, isEnabled: true, holdModifiers: hold, keyCode: KeyCodes.keyAboveTab, scope: .activeApp,
                            showMinimized: true, showHidden: true, showWindowlessApps: false, startInSearch: false),
            // ⌘Space belongs to Spotlight.
            ShortcutProfile(id: 2, isEnabled: false, holdModifiers: .option, keyCode: KeyCodes.space, scope: .allWindows,
                            showMinimized: true, showHidden: true, showWindowlessApps: true, startInSearch: true),
        ]
    }
}

/// Persistent settings. Main-thread only; views observe it through `ObservableObject`.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    /// Off for offscreen renders (docs, website): they change the style and language without touching the user's settings.
    static var persists = true
    private let store = UserDefaults.standard

    @Published var profiles: [ShortcutProfile] { didSet { save(profiles, "profiles") } }
    @Published var style: SwitcherStyle { didSet { save(style, "style") } }
    @Published var size: SwitcherSize { didSet { save(size, "size") } }
    @Published var theme: ThemeMode { didSet { save(theme, "theme") } }
    @Published var glass: GlassStyle { didSet { save(glass, "glass") } }
    @Published var screen: ScreenChoice { didSet { save(screen, "screen") } }
    @Published var language: AppLanguage { didSet { save(language, "language") } }
    @Published var showDelayMs: Int { didSet { save(showDelayMs, "showDelayMs") } }
    @Published var showBadges: Bool { didSet { save(showBadges, "showBadges") } }
    @Published var showSpaceNumbers: Bool { didSet { save(showSpaceNumbers, "showSpaceNumbers") } }
    @Published var previewSelectedWindow: Bool { didSet { save(previewSelectedWindow, "previewSelectedWindow") } }
    @Published var titleContent: TitleContent { didSet { save(titleContent, "titleContent") } }
    @Published var titleTruncation: TitleTruncation { didSet { save(titleTruncation, "titleTruncation") } }
    @Published var pointerFollowsSwitch: Bool { didSet { save(pointerFollowsSwitch, "pointerFollowsSwitch") } }
    @Published var panelAnimations: Bool { didSet { save(panelAnimations, "panelAnimations") } }
    @Published var mouseHoverSelects: Bool { didSet { save(mouseHoverSelects, "mouseHoverSelects") } }
    @Published var hapticFeedback: Bool { didSet { save(hapticFeedback, "hapticFeedback") } }
    @Published var showMenuBarIcon: Bool { didSet { save(showMenuBarIcon, "showMenuBarIcon") } }
    @Published var appExceptions: [AppException] {
        didSet {
            save(appExceptions, "appExceptions")
            // What older versions read instead.
            save(excludedBundleIDs, "excludedBundleIDs")
        }
    }
    /// The apps whose windows are always hidden: all that older versions had of the exceptions.
    var excludedBundleIDs: [String] {
        appExceptions.filter { $0.hiding == .allWindows && !$0.matchesPrefix }.map(\.bundleID)
    }
    @Published var shortcutsPaused: Bool { didSet { save(shortcutsPaused, "shortcutsPaused") } }
    @Published var panelKeys: PanelKeyBindings { didSet { save(panelKeys, "panelKeys") } }

    /// Stored settings Riffle couldn't read at launch (kept in Recovered): General tells about them until dismissed.
    @Published var recoveredSettings: [RecoveredSetting] { didSet { save(recoveredSettings, "recoveredSettings") } }
    /// The backup made before the last reset or import: General offers it back until dismissed.
    @Published var previousSettings: PreviousSettings? { didSet { saveOptional(previousSettings, "previousSettings") } }

    /// Remembered so that a crash while ⌘⇥ was taken over can be repaired on the next launch.
    var didDisableNativeCommandTab: Bool {
        get { store.bool(forKey: "didDisableNativeCommandTab") }
        set { store.set(newValue, forKey: "didDisableNativeCommandTab") }
    }

    var hasCompletedOnboarding: Bool {
        get { store.bool(forKey: "hasCompletedOnboarding") }
        set { store.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Chosen in the welcome window: Riffle runs without Screen Recording, and stops asking for it at every launch.
    var continuesWithoutPreviews: Bool {
        get { store.bool(forKey: "continuesWithoutPreviews") }
        set { if Prefs.persists { store.set(newValue, forKey: "continuesWithoutPreviews") } }
    }

    private init() {
        // Migrations, then every value that can be read; the default for each one that can't (see `SettingsLoad`).
        let stored = Dictionary(uniqueKeysWithValues: SettingsLoad.keys.compactMap { key in UserDefaults.standard.object(forKey: key).map { (key, $0) } })
        let load = SettingsLoad(stored: stored, defaults: .defaults())
        let settings = load.settings
        profiles = settings.profiles
        style = settings.style
        size = settings.size
        theme = settings.theme
        glass = settings.glass
        screen = settings.screen
        language = settings.language
        showDelayMs = settings.showDelayMs
        showBadges = settings.showBadges
        showSpaceNumbers = settings.showSpaceNumbers
        previewSelectedWindow = settings.previewSelectedWindow
        titleContent = settings.titleContent
        titleTruncation = settings.titleTruncation
        pointerFollowsSwitch = settings.pointerFollowsSwitch
        panelAnimations = settings.panelAnimations
        mouseHoverSelects = settings.mouseHoverSelects
        hapticFeedback = settings.hapticFeedback
        showMenuBarIcon = settings.showMenuBarIcon
        appExceptions = settings.appExceptions
        shortcutsPaused = load.shortcutsPaused
        panelKeys = settings.panelKeys
        recoveredSettings = UserDefaults.standard.data(forKey: "recoveredSettings")
            .flatMap { try? JSONDecoder().decode([RecoveredSetting].self, from: $0) } ?? []
        previousSettings = UserDefaults.standard.data(forKey: "previousSettings")
            .flatMap { try? JSONDecoder().decode(PreviousSettings.self, from: $0) }
        guard Prefs.persists else { return }
        // A value that can't be read is kept before anything is written over it; one that can't be kept stays as it is.
        let kept = SettingsFiles.keep(load.unreadable)
        for (key, write) in load.writes where load.unreadable[key] == nil || kept.contains(where: { $0.key == key }) {
            switch write {
            case .set(let value): store.set(value, forKey: key)
            case .remove: store.removeObject(forKey: key)
            }
        }
        if !kept.isEmpty {
            // Assignments in init don't run `didSet`.
            recoveredSettings += kept
            save(recoveredSettings, "recoveredSettings")
        }
    }

    /// Every setting a person chooses, as one value (what export, import and reset deal in).
    var snapshot: SettingsSnapshot {
        SettingsSnapshot(profiles: profiles, style: style, size: size, theme: theme, glass: glass, screen: screen, language: language,
                         showDelayMs: showDelayMs, showBadges: showBadges, showSpaceNumbers: showSpaceNumbers,
                         previewSelectedWindow: previewSelectedWindow, titleContent: titleContent, titleTruncation: titleTruncation,
                         pointerFollowsSwitch: pointerFollowsSwitch, panelAnimations: panelAnimations, mouseHoverSelects: mouseHoverSelects,
                         hapticFeedback: hapticFeedback, showMenuBarIcon: showMenuBarIcon, appExceptions: appExceptions, panelKeys: panelKeys)
    }

    /// Puts every setting in place at once.
    func apply(_ settings: SettingsSnapshot) {
        profiles = Prefs.sanitized(settings.profiles)
        style = settings.style
        size = settings.size
        theme = settings.theme
        glass = settings.glass
        screen = settings.screen
        showDelayMs = settings.showDelayMs
        showBadges = settings.showBadges
        showSpaceNumbers = settings.showSpaceNumbers
        previewSelectedWindow = settings.previewSelectedWindow
        titleContent = settings.titleContent
        titleTruncation = settings.titleTruncation
        pointerFollowsSwitch = settings.pointerFollowsSwitch
        panelAnimations = settings.panelAnimations
        mouseHoverSelects = settings.mouseHoverSelects
        hapticFeedback = settings.hapticFeedback
        showMenuBarIcon = settings.showMenuBarIcon
        appExceptions = settings.appExceptions
        panelKeys = settings.panelKeys
        // Last: Settings is laid out again in the new language.
        language = settings.language
    }

    /// At least one shortcut, at most nine, each with an id of its own.
    static func sanitized(_ profiles: [ShortcutProfile]) -> [ShortcutProfile] {
        var result = [ShortcutProfile]()
        var used = Set<Int>()
        for var profile in profiles.prefix(ShortcutProfile.maximum) {
            if used.contains(profile.id) { profile.id = (used.max() ?? -1) + 1 }
            used.insert(profile.id)
            result.append(profile)
        }
        return result.isEmpty ? Array(ShortcutProfile.defaults.prefix(1)) : result
    }

    private func save<T: Codable>(_ value: T, _ key: String) {
        guard Prefs.persists, let data = try? JSONEncoder().encode(value) else { return }
        store.set(data, forKey: key)
    }

    private func saveOptional<T: Codable>(_ value: T?, _ key: String) {
        guard Prefs.persists else { return }
        guard let value else { return store.removeObject(forKey: key) }
        save(value, key)
    }

    func addProfile() {
        guard profiles.count < ShortcutProfile.maximum else { return }
        profiles.append(.added(id: (profiles.map(\.id).max() ?? -1) + 1, besides: profiles))
    }

    func removeProfile(id: Int) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
    }

    /// Every setting back to a new setup's, the language included. Settings → General does this through
    /// `SettingsTransfer`, which keeps a backup first.
    func resetToDefaults() {
        apply(.defaults())
    }
}
