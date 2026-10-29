import Foundation

/// Whose windows a shortcut lists.
enum AppScope: String, Codable, CaseIterable {
    case allApps, activeApp, otherApps, appUnderPointer

    init(from decoder: Decoder) throws {
        self = AppScope(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .allApps
    }
}

/// Where those windows may be.
enum PlaceScope: String, Codable, CaseIterable {
    case allDesktops, thisDesktop, thisScreen

    init(from decoder: Decoder) throws {
        self = PlaceScope(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .allDesktops
    }
}

enum WindowOrder: String, Codable, CaseIterable {
    /// Most recently used first: the order Riffle always had.
    case recentlyUsed
    /// Apps in the order they were launched, each app's windows in the order they were opened.
    case launchOrder
    /// By app name, then by window title.
    case alphabetical
    /// Desktop by desktop as Mission Control numbers them, most recently used first on each.
    case byDesktop

    init(from decoder: Decoder) throws {
        self = WindowOrder(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .recentlyUsed
    }
}

/// Listed in its place, moved to the end of the list, or left out.
enum ShowOption: String, Codable, CaseIterable {
    case show, showAtEnd, hide

    init(from decoder: Decoder) throws {
        self = ShowOption(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .show
    }

    /// For a row two options apply to (a minimized window of a hidden app): leaving out wins over the end, the end over
    /// its place.
    func combined(with other: ShowOption) -> ShowOption {
        if self == .hide || other == .hide { return .hide }
        if self == .showAtEnd || other == .showAtEnd { return .showAtEnd }
        return .show
    }
}

/// Decodes one element of a list on its own: a damaged element becomes nil instead of failing the whole list.
struct LossyElement<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension ShortcutProfile {
    /// The shape shortcuts had when one `scope` stood for both whose windows and where, and three switches for the rest.
    /// Older code and older settings keep meaning what they meant.
    init(id: Int, isEnabled: Bool, holdModifiers: CarbonModifiers, keyCode: UInt32, scope: WindowScope, showMinimized: Bool,
         showHidden: Bool, showWindowlessApps: Bool, startInSearch: Bool) {
        self.init(id: id, isEnabled: isEnabled, holdModifiers: holdModifiers, keyCode: keyCode)
        self.scope = scope
        minimized = showMinimized ? .show : .hide
        hiddenApps = showHidden ? .show : .hide
        // The switch only ever worked with every window on every desktop.
        windowlessApps = showWindowlessApps && scope == .allWindows ? .showAtEnd : .hide
        self.startInSearch = startInSearch
    }

    /// The closest single setting of older versions, which read only that.
    var scope: WindowScope {
        get {
            if apps == .activeApp { return .activeApp }
            switch place {
            case .allDesktops: return .allWindows
            case .thisDesktop: return .currentSpace
            case .thisScreen: return .currentScreen
            }
        }
        set {
            switch newValue {
            case .allWindows: (apps, place) = (.allApps, .allDesktops)
            case .activeApp: (apps, place) = (.activeApp, .allDesktops)
            case .currentSpace: (apps, place) = (.allApps, .thisDesktop)
            case .currentScreen: (apps, place) = (.allApps, .thisScreen)
            }
        }
    }

    var showMinimized: Bool {
        get { minimized != .hide }
        set { minimized = newValue ? .show : .hide }
    }

    var showHidden: Bool {
        get { hiddenApps != .hide }
        set { hiddenApps = newValue ? .show : .hide }
    }

    var showWindowlessApps: Bool {
        get { windowlessApps != .hide }
        set { windowlessApps = newValue ? .showAtEnd : .hide }
    }

    /// Apps without windows can join every list but the active app's own (that app is already in front).
    var listsWindowlessApps: Bool { apps != .activeApp }

    private enum CodingKeys: String, CodingKey {
        case id, isEnabled, holdModifiers, keyCode, apps, place, order, onePerApp, minimized, hiddenApps, windowlessApps
        case showFullscreen, style, startInSearch, releaseBehavior
        // What older versions wrote and read.
        case scope, showMinimized, showHidden, showWindowlessApps
    }

    /// Every field is read on its own: one that's missing, of the wrong type or unknown to this version takes its default
    /// (or what the older fields said) and never costs the rest of the shortcut.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
        }
        func choice<T: RawRepresentable>(_ key: CodingKeys) -> T? where T.RawValue == String {
            (value(key) as String?).flatMap(T.init(rawValue:))
        }
        self.init(id: value(.id) ?? 0, isEnabled: value(.isEnabled) ?? true,
                  holdModifiers: value(.holdModifiers) ?? .option, keyCode: value(.keyCode) ?? KeyCodes.tab)
        let oldScope: WindowScope? = choice(.scope)
        if let oldScope { scope = oldScope }
        apps = choice(.apps) ?? apps
        place = choice(.place) ?? place
        order = choice(.order) ?? .recentlyUsed
        onePerApp = value(.onePerApp) ?? false
        minimized = choice(.minimized) ?? ((value(.showMinimized) as Bool?) == false ? .hide : .show)
        hiddenApps = choice(.hiddenApps) ?? ((value(.showHidden) as Bool?) == false ? .hide : .show)
        let oldWindowless = (value(.showWindowlessApps) as Bool?) == true && (oldScope ?? .allWindows) == .allWindows
        windowlessApps = choice(.windowlessApps) ?? (oldWindowless ? .showAtEnd : .hide)
        showFullscreen = value(.showFullscreen) ?? true
        // Unknown means "as in Appearance", not some other style.
        style = choice(.style)
        startInSearch = value(.startInSearch) ?? false
        // Saved before it existed: switch on release, as shortcuts always did. A value from a newer version falls back
        // in `ReleaseBehavior`'s own decoding.
        releaseBehavior = value(.releaseBehavior) ?? .switchToSelected
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(holdModifiers, forKey: .holdModifiers)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(apps, forKey: .apps)
        try container.encode(place, forKey: .place)
        try container.encode(order, forKey: .order)
        try container.encode(onePerApp, forKey: .onePerApp)
        try container.encode(minimized, forKey: .minimized)
        try container.encode(hiddenApps, forKey: .hiddenApps)
        try container.encode(windowlessApps, forKey: .windowlessApps)
        try container.encode(showFullscreen, forKey: .showFullscreen)
        try container.encodeIfPresent(style, forKey: .style)
        try container.encode(startInSearch, forKey: .startInSearch)
        try container.encode(releaseBehavior, forKey: .releaseBehavior)
        // An older version reads only these, and without them would start over with its default shortcuts.
        try container.encode(scope, forKey: .scope)
        try container.encode(showMinimized, forKey: .showMinimized)
        try container.encode(showHidden, forKey: .showHidden)
        try container.encode(showWindowlessApps, forKey: .showWindowlessApps)
    }

    /// A saved list, read shortcut by shortcut: a damaged one is dropped, the others stay. Nil when it isn't a list.
    static func decodeList(from data: Data) -> [ShortcutProfile]? {
        (try? JSONDecoder().decode([LossyElement<ShortcutProfile>].self, from: data))?.compactMap(\.value)
    }
}
