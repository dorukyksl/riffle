import Carbon
import Cocoa

/// What each key of a keyboard layout types, without and with ⇧. The switcher's one-key commands are bound to physical
/// keys; this finds the key that carries a given character on the layout in use (Turkish Q, AZERTY, QWERTZ, Dvorak…).
struct KeyboardLayout {
    /// The input source id ("com.apple.keylayout.French").
    let id: String
    /// ANSI, ISO or JIS key positions (`LMGetKbdType()`): on ISO keyboards two keys trade places.
    let keyboardType: UInt32
    /// Key code → the printable character the key types with no modifier, and with ⇧ alone.
    let plain: [UInt32: String]
    let shifted: [UInt32: String]

    init(id: String, keyboardType: UInt32 = 0, plain: [UInt32: String], shifted: [UInt32: String] = [:]) {
        self.id = id
        self.keyboardType = keyboardType
        self.plain = plain
        self.shifted = shifted
    }

    init?(source: TISInputSource, keyboardType: UInt32) {
        guard let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
              let dataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        var plain = [UInt32: String](), shifted = [UInt32: String]()
        bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            for keyCode in UInt32(0)..<128 {
                plain[keyCode] = KeyboardLayout.translate(layout, keyCode, modifiers: 0, keyboardType: keyboardType)
                shifted[keyCode] = KeyboardLayout.translate(layout, keyCode, modifiers: UInt32(shiftKey >> 8), keyboardType: keyboardType)
            }
        }
        self.init(id: Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String, keyboardType: keyboardType,
                  plain: plain, shifted: shifted)
    }

    private static func translate(_ layout: UnsafePointer<UCKeyboardLayout>, _ keyCode: UInt32, modifiers: UInt32, keyboardType: UInt32) -> String? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        // A mask, not the bit's number: with dead keys on, a dead key (German ^, French ^ and ¨) types nothing yet and
        // would go by its number.
        let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown), modifiers, keyboardType,
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, 4, &length, &characters)
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        // Return, Tab, arrows, function keys… type control characters: not something a key is known by.
        guard text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }

    /// Latin-script layouts type most of a…z without a modifier; Russian, Greek, Hebrew, Arabic, Thai, Korean… none.
    var typesLatinLetters: Bool {
        let letters = Set("abcdefghijklmnopqrstuvwxyz".map(String.init))
        return Set(plain.values).intersection(letters).count >= 13
    }

    private static var cached: KeyboardLayout?

    /// The layout typing goes through right now (for Japanese, Chinese or Korean input, the layout under the input
    /// method). Main thread only, like all of Text Input Sources.
    static var current: KeyboardLayout? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        let id = Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String
        let keyboardType = UInt32(LMGetKbdType())
        if let cached, cached.id == id, cached.keyboardType == keyboardType { return cached }
        cached = KeyboardLayout(source: source, keyboardType: keyboardType)
        return cached
    }

    /// A layout that ships with macOS, whether or not it's enabled in System Settings.
    static func installed(_ id: String, keyboardType: UInt32) -> KeyboardLayout? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first else { return nil }
        return KeyboardLayout(source: source, keyboardType: keyboardType)
    }
}
