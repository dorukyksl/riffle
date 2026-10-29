import Carbon
import Cocoa

/// What a key does inside the switcher.
enum PanelCommand: Equatable {
    case search
    case perform(SwitcherAction)
    case move(TileLayout.Move)
}

/// A key the switcher listens for that can be changed in Settings. Search has two (S and /).
enum PanelKey: String, CaseIterable {
    case search, searchAlternate, close, minimize, fullscreen, hide, quit

    /// Out of the box each one gets the key that types this character.
    var defaultCharacter: Character {
        switch self {
        case .search: return "s"
        case .searchAlternate: return "/"
        case .close: return "w"
        case .minimize: return "m"
        case .fullscreen: return "f"
        case .hide: return "h"
        case .quit: return "q"
        }
    }

    var command: PanelCommand {
        switch self {
        case .search, .searchAlternate: return .search
        case .close: return .perform(.close)
        case .minimize: return .perform(.minimize)
        case .fullscreen: return .perform(.fullscreen)
        case .hide: return .perform(.hide)
        case .quit: return .perform(.quit)
        }
    }

    /// What it does, as Settings lists it.
    var title: String {
        switch self {
        case .search, .searchAlternate: return L.t("Ara (yazmaya başla; tuşu bırakabilirsin)", "Search (start typing; you can let go of the key)")
        case .close: return L.t("Pencereyi kapat", "Close window")
        case .minimize: return L.t("Küçült / geri getir", "Minimize / restore")
        case .fullscreen: return L.t("Tam ekran aç / kapat", "Toggle full screen")
        case .hide: return L.t("Uygulamayı gizle / göster", "Hide / show app")
        case .quit: return L.t("Uygulamadan çık", "Quit app")
        }
    }

    /// What it does, in a sentence.
    var name: String {
        switch self {
        case .search, .searchAlternate: return L.t("Ara", "Search")
        default: return title
        }
    }
}

/// Keys whose job in the switcher is fixed: ⎋, ↩, ⇥, the arrows and 1…9 (keypad included).
enum FixedPanelKeys {
    static let codes: Set<UInt32> = Set([
        kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
        kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5, kVK_ANSI_Keypad6,
        kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9,
    ].map(UInt32.init))
}

/// The one-key commands' keys as chosen in Settings, plus the Vim keys option. Keys are physical key codes, so a choice
/// works on every layout; a key never chosen follows the layout in use (see `resolved(on:)`).
struct PanelKeyBindings: Equatable {
    enum Choice: Equatable {
        case key(UInt32)
        /// Cleared in Settings: no key at all.
        case none
    }

    var custom: [PanelKey: Choice] = [:]
    /// h j k l move the selection.
    var vimKeys = false

    /// The keys in effect on `layout`. Keys picked in Settings come first, then the Vim keys (turning them on is a choice
    /// too), then each default on the key that types its character: unshifted, then with ⇧, and on layouts that type no
    /// Latin letters at all, the key in that letter's QWERTY place. A key that's taken leaves the later one without a key.
    func resolved(on layout: KeyboardLayout?) -> PanelKeyMap {
        var map = PanelKeyMap()
        var taken = FixedPanelKeys.codes
        for slot in PanelKey.allCases {
            guard case .key(let keyCode)? = custom[slot], !taken.contains(keyCode) else { continue }
            map.slots[slot] = .init(keyCode: keyCode, label: KeyCodes.name(for: keyCode, on: layout))
            taken.insert(keyCode)
        }
        var wanted = [(target: PanelKeyMap.Target, character: Character)]()
        if vimKeys { wanted += PanelKeyMap.vimMoves.map { (.move($0.move), $0.character) } }
        wanted += PanelKey.allCases.filter { custom[$0] == nil }.map { (.slot($0), $0.defaultCharacter) }
        for pass in DefaultPass.allCases where pass != .qwertyPlace || !(layout?.typesLatinLetters ?? false) {
            for (target, character) in wanted where !map.contains(target) {
                guard let keyCode = pass.key(typing: character, on: layout, excluding: taken) else { continue }
                // A key found by its shifted or QWERTY character is shown by that character ("/" rather than ":").
                let label = pass == .plain ? KeyCodes.name(for: keyCode, on: layout) : String(character).uppercased()
                map.assign(target, keyCode: keyCode, label: label)
                taken.insert(keyCode)
            }
        }
        return map
    }

    private enum DefaultPass: CaseIterable {
        case plain, shifted, qwertyPlace

        /// The main typing block only: a laptop has no keypad, and its / is no use there.
        private static let typingKeys: [UInt32] = (UInt32(0)...UInt32(kVK_ANSI_Grave))
            .filter { ![kVK_Return, kVK_Tab, kVK_Space].map(UInt32.init).contains($0) }
            + [UInt32(kVK_JIS_Yen), UInt32(kVK_JIS_Underscore)]

        private static let qwertyPlaces: [Character: Int] = [
            "s": kVK_ANSI_S, "/": kVK_ANSI_Slash, "w": kVK_ANSI_W, "m": kVK_ANSI_M, "f": kVK_ANSI_F, "h": kVK_ANSI_H,
            "q": kVK_ANSI_Q, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        ]

        func key(typing character: Character, on layout: KeyboardLayout?, excluding taken: Set<UInt32>) -> UInt32? {
            let text = String(character)
            switch self {
            case .plain:
                guard let layout else { return nil }
                return DefaultPass.typingKeys.first { layout.plain[$0] == text && !taken.contains($0) }
            case .shifted:
                guard let layout else { return nil }
                return DefaultPass.typingKeys.first { layout.shifted[$0] == text && !taken.contains($0) }
            case .qwertyPlace:
                guard let place = DefaultPass.qwertyPlaces[character].map(UInt32.init), !taken.contains(place) else { return nil }
                return place
            }
        }
    }

    /// Why a key can't go to `slot`, or nil when it can. `shortcutKeys`: the keys of the enabled switcher shortcuts, which
    /// are pressed together with the hold key while the switcher is open.
    func conflict(assigning keyCode: UInt32, to slot: PanelKey, on layout: KeyboardLayout?,
                  shortcutKeys: Set<UInt32>) -> PanelKeyConflict? {
        if FixedPanelKeys.codes.contains(keyCode) { return .fixed }
        if shortcutKeys.contains(keyCode) { return .shortcut }
        let map = resolved(on: layout)
        if map.moves[keyCode] != nil { return .vimKeys }
        if let owner = map.slot(for: keyCode), owner != slot { return .taken(by: owner) }
        return nil
    }

    /// Why `keyCode` can't be a switcher shortcut's key, or nil when it can. The switcher listens for these keys while
    /// the hold key is down, whatever the modifiers: a shortcut on one would take it away from the switcher. ⇥ is the
    /// exception, as stepping through the windows is what a shortcut's own key does there.
    func conflict(shortcutKey keyCode: UInt32, on layout: KeyboardLayout?) -> PanelKeyConflict? {
        if keyCode == KeyCodes.tab { return nil }
        if FixedPanelKeys.codes.contains(keyCode) { return .fixed }
        let map = resolved(on: layout)
        if map.moves[keyCode] != nil { return .vimKeys }
        if let owner = map.slot(for: keyCode) { return .taken(by: owner) }
        return nil
    }

    /// Gives `slot` a key (nil: no key). Picking the key it would get anyway keeps it following the layout.
    mutating func assign(_ keyCode: UInt32?, to slot: PanelKey, on layout: KeyboardLayout?) {
        guard let keyCode else {
            custom[slot] = PanelKeyBindings.Choice.none
            return
        }
        var automatic = self
        automatic.custom[slot] = nil
        custom[slot] = automatic.resolved(on: layout).slots[slot]?.keyCode == keyCode ? nil : .key(keyCode)
    }

    /// Keys picked in Settings that sit where the Vim keys go on `layout`: turning those on would take them away.
    func vimConflicts(on layout: KeyboardLayout?) -> [PanelKey] {
        var vimOnly = PanelKeyBindings()
        vimOnly.vimKeys = true
        vimOnly.custom = Dictionary(uniqueKeysWithValues: PanelKey.allCases.map { ($0, PanelKeyBindings.Choice.none) })
        let vimKeyCodes = Set(vimOnly.resolved(on: layout).moves.keys)
        return PanelKey.allCases.filter { slot in
            guard case .key(let keyCode)? = custom[slot] else { return false }
            return vimKeyCodes.contains(keyCode)
        }
    }

    /// Commands left without a key because the Vim keys took theirs.
    func displacedByVimKeys(on layout: KeyboardLayout?) -> [PanelKey] {
        guard vimKeys else { return [] }
        var withoutVim = self
        withoutVim.vimKeys = false
        let with = resolved(on: layout), without = withoutVim.resolved(on: layout)
        return PanelKey.allCases.filter { with.slots[$0] == nil && without.slots[$0] != nil }
    }
}

extension PanelKeyBindings: Codable {
    private enum CodingKeys: String, CodingKey { case keys, vimKeys }

    /// Stored as {"keys": {"close": 13, "searchAlternate": -1}, "vimKeys": false}: -1 is "no key". Unknown names are
    /// skipped, so settings from another version still load; a number that's no key at all makes the whole setting
    /// unreadable, like any other bad value.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keys = try container.decodeIfPresent([String: Int].self, forKey: .keys) ?? [:]
        for (name, value) in keys {
            guard let slot = PanelKey(rawValue: name) else { continue }
            guard value >= 0 else {
                custom[slot] = PanelKeyBindings.Choice.none
                continue
            }
            guard let keyCode = UInt32(exactly: value), KeyCodes.range.contains(keyCode) else {
                throw DecodingError.dataCorruptedError(forKey: .keys, in: container, debugDescription: "\(name): \(value) is no key")
            }
            custom[slot] = .key(keyCode)
        }
        vimKeys = try container.decodeIfPresent(Bool.self, forKey: .vimKeys) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let keys = Dictionary(uniqueKeysWithValues: custom.map { slot, choice -> (String, Int) in
            if case .key(let keyCode) = choice { return (slot.rawValue, Int(keyCode)) }
            return (slot.rawValue, -1)
        })
        try container.encode(keys, forKey: .keys)
        try container.encode(vimKeys, forKey: .vimKeys)
    }
}

enum PanelKeyConflict: Equatable {
    /// ⎋, ↩, ⇥, an arrow or a digit.
    case fixed
    /// The key of a switcher shortcut.
    case shortcut
    case vimKeys
    case taken(by: PanelKey)
}

/// The keys in effect for the one-key commands on one keyboard layout.
struct PanelKeyMap: Equatable {
    struct Binding: Equatable {
        let keyCode: UInt32
        /// The key as Settings shows it.
        let label: String
    }

    enum Target: Equatable {
        case slot(PanelKey)
        case move(TileLayout.Move)
    }

    static let vimMoves: [(character: Character, move: TileLayout.Move)] = [("h", .left), ("j", .down), ("k", .up), ("l", .right)]

    fileprivate(set) var slots = [PanelKey: Binding]()
    /// Vim keys, when on.
    fileprivate(set) var moves = [UInt32: TileLayout.Move]()

    func command(for keyCode: UInt32) -> PanelCommand? {
        if let move = moves[keyCode] { return .move(move) }
        return slot(for: keyCode)?.command
    }

    func slot(for keyCode: UInt32) -> PanelKey? {
        PanelKey.allCases.first { slots[$0]?.keyCode == keyCode }
    }

    fileprivate func contains(_ target: Target) -> Bool {
        switch target {
        case .slot(let slot): return slots[slot] != nil
        case .move(let move): return moves.values.contains(move)
        }
    }

    fileprivate mutating func assign(_ target: Target, keyCode: UInt32, label: String) {
        switch target {
        case .slot(let slot): slots[slot] = Binding(keyCode: keyCode, label: label)
        case .move(let move): moves[keyCode] = move
        }
    }

    private static var cache: (layoutID: String?, keyboardType: UInt32?, bindings: PanelKeyBindings, map: PanelKeyMap)?

    /// The keys in effect right now, on the current layout. Main thread only.
    static func current(_ bindings: PanelKeyBindings) -> PanelKeyMap {
        let layout = KeyboardLayout.current
        if let cache, cache.layoutID == layout?.id, cache.keyboardType == layout?.keyboardType, cache.bindings == bindings {
            return cache.map
        }
        let map = bindings.resolved(on: layout)
        cache = (layout?.id, layout?.keyboardType, bindings, map)
        return map
    }
}
