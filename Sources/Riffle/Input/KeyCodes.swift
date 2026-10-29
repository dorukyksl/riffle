import Carbon
import Cocoa

/// Carbon modifier flags, the representation `RegisterEventHotKey` wants.
struct CarbonModifiers: OptionSet, Codable, Hashable {
    let rawValue: UInt32
    static let command = CarbonModifiers(rawValue: UInt32(cmdKey))
    static let shift = CarbonModifiers(rawValue: UInt32(shiftKey))
    static let option = CarbonModifiers(rawValue: UInt32(optionKey))
    static let control = CarbonModifiers(rawValue: UInt32(controlKey))

    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }

    /// In the order macOS menus print them: ⌃⌥⇧⌘.
    var symbols: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }

    /// The modifiers a hold can be made of: ⇧ is left out, it walks backwards.
    static let holdable: CarbonModifiers = [.control, .option, .command]

    /// Every hold combination, offered as quick picks next to the hold recorder in Settings.
    static let holdChoices: [CarbonModifiers] = [.option, .command, .control, [.control, .option], [.option, .command], [.control, .command],
                                                 [.control, .option, .command]]

    /// Whether a shortcut can be held with these: ⌃ ⌥ ⇧ ⌘ and nothing else, at least one of ⌃ ⌥ ⌘ among them. Without
    /// one, the shortcut's key would switch windows in every app instead of typing.
    var isValidHold: Bool {
        CarbonModifiers([.control, .option, .shift, .command]).isSuperset(of: self) && !intersection(.holdable).isEmpty
    }
}

extension CarbonModifiers {
    init(eventFlags flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
    }

    /// Their names as VoiceOver should say them, in the order of `symbols`.
    var spokenNames: [String] {
        var names = [String]()
        if contains(.control) { names.append(L.t("Control", "Control")) }
        if contains(.option) { names.append(L.t("Option", "Option")) }
        if contains(.shift) { names.append(L.t("Shift", "Shift")) }
        if contains(.command) { names.append(L.t("Command", "Command")) }
        return names
    }
}

/// Recording a hold in Settings: modifiers go down and come up again; once they're all up, the most that were held
/// together is the hold. ⇧ doesn't count, it walks backwards.
struct HoldCapture {
    /// Held right now.
    private(set) var held = CarbonModifiers()
    private var most = CarbonModifiers()

    /// `sent`: the modifiers of a flagsChanged event, as macOS reports them. Returns the hold once every key is up again.
    mutating func update(sent: CarbonModifiers) -> CarbonModifiers? {
        let sent = sent.intersection(.holdable)
        held = sent
        if HoldCapture.count(held) > HoldCapture.count(most) { most = held }
        guard sent.isEmpty, !most.isEmpty else { return nil }
        defer { most = [] }
        return most
    }

    private static func count(_ modifiers: CarbonModifiers) -> Int {
        [CarbonModifiers.control, .option, .command].filter(modifiers.contains).count
    }
}

enum KeyCodes {
    static let tab = UInt32(kVK_Tab)
    static let space = UInt32(kVK_Space)
    /// Every key there is: virtual key codes run from 0 to 127 (the `kVK_` constants).
    static let range = UInt32(0)...UInt32(127)

    /// The physical key above Tab. On ISO keyboards (e.g. Turkish Q) that key is kVK_ISO_Section, not
    /// kVK_ANSI_Grave (which there is the key next to left Shift).
    static var keyAboveTab: UInt32 {
        KBGetLayoutType(Int16(LMGetKbdType())) == UInt32(kKeyboardISO) ? UInt32(kVK_ISO_Section) : UInt32(kVK_ANSI_Grave)
    }

    private static let named: [UInt32: String] = [
        UInt32(kVK_Tab): "⇥", UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Escape): "⎋",
        UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→", UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘", UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]

    /// Human-readable name of a key on the current keyboard layout ("⇥", "\"", "Q"…).
    static func name(for keyCode: UInt32) -> String {
        name(for: keyCode, on: KeyboardLayout.current)
    }

    static func name(for keyCode: UInt32, on layout: KeyboardLayout?) -> String {
        if keyCode == space { return L.t("Boşluk", "Space") }
        if let name = named[keyCode] { return name }
        if let character = layout?.plain[keyCode], !character.trimmingCharacters(in: .whitespaces).isEmpty {
            return character.uppercased()
        }
        return "#\(keyCode)"
    }

    static func character(for keyCode: UInt32) -> String? {
        KeyboardLayout.current?.plain[keyCode]
    }

    static func shortcutDescription(modifiers: CarbonModifiers, keyCode: UInt32) -> String {
        modifiers.symbols + name(for: keyCode)
    }

    /// A key's name as VoiceOver should say it: a word for the keys `name` shows as a symbol ("Tab", "Left Arrow"),
    /// otherwise the same name.
    static func spokenName(for keyCode: UInt32, on layout: KeyboardLayout?) -> String {
        switch Int(keyCode) {
        case kVK_Tab: return L.t("Tab", "Tab")
        case kVK_Return: return L.t("Return", "Return")
        case kVK_Escape: return L.t("Esc", "Escape")
        case kVK_Delete: return L.t("Sil", "Delete")
        case kVK_ForwardDelete: return L.t("İleri Sil", "Forward Delete")
        case kVK_LeftArrow: return L.t("Sol Ok", "Left Arrow")
        case kVK_RightArrow: return L.t("Sağ Ok", "Right Arrow")
        case kVK_UpArrow: return L.t("Yukarı Ok", "Up Arrow")
        case kVK_DownArrow: return L.t("Aşağı Ok", "Down Arrow")
        case kVK_Home: return L.t("Home", "Home")
        case kVK_End: return L.t("End", "End")
        case kVK_PageUp: return L.t("Page Up", "Page Up")
        case kVK_PageDown: return L.t("Page Down", "Page Down")
        default: return name(for: keyCode, on: layout)
        }
    }

    static func spokenName(for keyCode: UInt32) -> String {
        spokenName(for: keyCode, on: KeyboardLayout.current)
    }

    /// A shortcut as VoiceOver should say it: "Option Tab".
    static func spokenDescription(modifiers: CarbonModifiers, keyCode: UInt32) -> String {
        (modifiers.spokenNames + [spokenName(for: keyCode)]).joined(separator: " ")
    }
}
