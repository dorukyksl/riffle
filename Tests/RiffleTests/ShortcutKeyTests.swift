import Carbon
import XCTest
@testable import Riffle

/// A layout as macOS ships it, read without selecting it. ANSI key positions unless asked, so results don't depend on
/// the keyboard of the Mac running the tests.
private func layout(_ id: String, keyboardType: UInt32 = 40) throws -> KeyboardLayout {
    guard let layout = KeyboardLayout.installed("com.apple.keylayout." + id, keyboardType: keyboardType) else {
        throw XCTSkip("keyboard layout \(id) isn't installed")
    }
    return layout
}

private func key(_ code: Int) -> UInt32 { UInt32(code) }

/// Runs `body` with Riffle in `language`, never saving it.
private func speaking<T>(_ language: AppLanguage, _ body: () throws -> T) rethrows -> T {
    let prefs = Prefs.shared
    let persisted = Prefs.persists, before = prefs.language
    Prefs.persists = false
    prefs.language = language
    defer {
        prefs.language = before
        Prefs.persists = persisted
    }
    return try body()
}

/// Dead keys type nothing until the next key, but they still have a character to be known by.
final class DeadKeyNameTests: XCTestCase {
    func testGermanDeadKeysGoByTheirCharacter() throws {
        // The key above Tab on a German keyboard is a dead ^: the second shortcut out of the box is ⌥ on it.
        for keyboardType: UInt32 in [40, 41] {
            let german = try layout("German", keyboardType: keyboardType)
            XCTAssertEqual(german.plain[key(kVK_ISO_Section)], "^")
            XCTAssertEqual(KeyCodes.name(for: key(kVK_ISO_Section), on: german), "^")
            // ´ with ` above it, next to ß.
            XCTAssertEqual(KeyCodes.name(for: key(kVK_ANSI_Equal), on: german), "´")
            XCTAssertEqual(german.shifted[key(kVK_ANSI_Equal)], "`")
        }
    }

    func testFrenchDeadKeysGoByTheirCharacter() throws {
        // ^ with ¨ above it, next to P; ` next to Return.
        let french = try layout("French")
        XCTAssertEqual(KeyCodes.name(for: key(kVK_ANSI_LeftBracket), on: french), "^")
        XCTAssertEqual(french.shifted[key(kVK_ANSI_LeftBracket)], "¨")
        XCTAssertEqual(KeyCodes.name(for: key(kVK_ANSI_Backslash), on: french), "`")
    }

    func testUSKeysAreNamedAsBefore() throws {
        // No dead keys there: nothing changes.
        let us = try layout("US")
        XCTAssertEqual(KeyCodes.name(for: key(kVK_ANSI_Grave), on: us), "`")
        XCTAssertEqual(KeyCodes.name(for: key(kVK_ANSI_Quote), on: us), "'")
        XCTAssertEqual(KeyCodes.name(for: key(kVK_ANSI_6), on: us), "6")
        XCTAssertEqual(us.shifted[key(kVK_ANSI_6)], "^")
        XCTAssertEqual(KeyCodes.name(for: key(kVK_ANSI_Q), on: us), "Q")
    }

    func testNoTypingKeyGoesByItsNumber() throws {
        for id in ["German", "French", "US", "Turkish", "Turkish-QWERTY-PC"] {
            let layout = try layout(id)
            for keyCode in UInt32(0)...key(kVK_ANSI_Grave) {
                XCTAssertNotEqual(KeyCodes.name(for: keyCode, on: layout), "#\(keyCode)", "\(id): key \(keyCode)")
            }
        }
    }
}

/// A shortcut's key can't be one the switcher listens for while the hold key is down: the shortcut would take it away.
final class ShortcutKeyConflictTests: XCTestCase {
    func testKeysOfTheSwitcherAreRefused() throws {
        let us = try layout("US")
        let keys = PanelKeyBindings()
        XCTAssertEqual(keys.conflict(shortcutKey: key(kVK_ANSI_W), on: us), .taken(by: .close))
        XCTAssertEqual(keys.conflict(shortcutKey: key(kVK_ANSI_S), on: us), .taken(by: .search))
        XCTAssertEqual(keys.conflict(shortcutKey: key(kVK_ANSI_Slash), on: us), .taken(by: .searchAlternate))
        XCTAssertEqual(keys.conflict(shortcutKey: key(kVK_ANSI_Q), on: us), .taken(by: .quit))
        for fixed in [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Escape, kVK_LeftArrow, kVK_DownArrow, kVK_ANSI_1, kVK_ANSI_9, kVK_ANSI_Keypad5] {
            XCTAssertEqual(keys.conflict(shortcutKey: key(fixed), on: us), .fixed, "\(fixed)")
        }
    }

    func testKeysTheSwitcherLeavesAloneAreFine() throws {
        let us = try layout("US")
        // ⇥ steps through the windows, which is what a shortcut's own key does there anyway.
        for free in [kVK_Tab, kVK_ANSI_Grave, kVK_ISO_Section, kVK_Space, kVK_ANSI_J, kVK_ANSI_0, kVK_F5] {
            XCTAssertNil(PanelKeyBindings().conflict(shortcutKey: key(free), on: us), "\(free)")
        }
    }

    func testEveryShortcutOutOfTheBoxIsFine() throws {
        for id in ["US", "German", "French", "Turkish-QWERTY-PC", "Russian"] {
            let layout = try layout(id)
            for profile in ShortcutProfile.defaults {
                XCTAssertNil(PanelKeyBindings().conflict(shortcutKey: profile.keyCode, on: layout), "\(id): \(profile.keyCode)")
            }
        }
    }

    func testVimKeysAndKeysPickedByHandCountToo() throws {
        let us = try layout("US")
        var keys = PanelKeyBindings()
        keys.vimKeys = true
        XCTAssertEqual(keys.conflict(shortcutKey: key(kVK_ANSI_J), on: us), .vimKeys)
        keys.assign(key(kVK_ANSI_X), to: .close, on: us)
        XCTAssertEqual(keys.conflict(shortcutKey: key(kVK_ANSI_X), on: us), .taken(by: .close))
        // W closes no more.
        XCTAssertNil(keys.conflict(shortcutKey: key(kVK_ANSI_W), on: us))
    }

    func testTheKeysFollowTheLayout() throws {
        // AZERTY: closing is on the key QWERTY has Z on, and the key QWERTY has W on types Z.
        let french = try layout("French")
        XCTAssertEqual(PanelKeyBindings().conflict(shortcutKey: key(kVK_ANSI_Z), on: french), .taken(by: .close))
        XCTAssertNil(PanelKeyBindings().conflict(shortcutKey: key(kVK_ANSI_W), on: french))
    }

    func testARefusalSaysWhyInTheSameWordsAsTheSwitcherKeys() {
        speaking(.en) {
            XCTAssertEqual(PanelKeyConflict.taken(by: .close).refusal(of: "W"), "W is already used for “Close window”. Pick another key.")
            XCTAssertEqual(PanelKeyConflict.fixed.refusal(of: "↩"), "↩ already has a fixed job in the switcher. Pick another key.")
            XCTAssertEqual(PanelKeyConflict.vimKeys.refusal(of: "J"), "J is one of the Vim keys. Pick another key.")
        }
        for language in [AppLanguage.tr, .en] {
            speaking(language) {
                let texts = [PanelKeyConflict.fixed, .shortcut, .vimKeys, .taken(by: .close)].map { $0.refusal(of: "W") }
                XCTAssertEqual(Set(texts).count, texts.count)
                for text in texts { XCTAssertTrue(text.contains("W") && !text.contains("%"), text) }
            }
        }
    }
}

/// What VoiceOver says for keys and the buttons that record them.
final class SpokenKeyTests: XCTestCase {
    func testKeysShownAsSymbolsAreSpokenAsWords() throws {
        let us = try layout("US")
        speaking(.en) {
            XCTAssertEqual(KeyCodes.spokenName(for: KeyCodes.tab, on: us), "Tab")
            XCTAssertEqual(KeyCodes.spokenName(for: key(kVK_LeftArrow), on: us), "Left Arrow")
            XCTAssertEqual(KeyCodes.spokenName(for: key(kVK_Return), on: us), "Return")
            XCTAssertEqual(KeyCodes.spokenName(for: KeyCodes.space, on: us), "Space")
            XCTAssertEqual(KeyCodes.spokenName(for: key(kVK_F5), on: us), "F5")
            XCTAssertEqual(KeyCodes.spokenName(for: key(kVK_ANSI_Q), on: us), "Q")
            XCTAssertEqual(KeyCodes.spokenDescription(modifiers: .option, keyCode: KeyCodes.tab), "Option Tab")
            XCTAssertEqual(KeyCodes.spokenDescription(modifiers: [.command, .shift, .control], keyCode: KeyCodes.tab), "Control Shift Command Tab")
        }
        speaking(.tr) {
            XCTAssertEqual(KeyCodes.spokenDescription(modifiers: .command, keyCode: KeyCodes.tab), "Command Tab")
        }
    }

    func testEveryNamedKeyHasAWord() {
        let named = [kVK_Tab, kVK_Return, kVK_Escape, kVK_Delete, kVK_ForwardDelete, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow,
                     kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown]
        for language in [AppLanguage.tr, .en] {
            speaking(language) {
                let words = named.map { KeyCodes.spokenName(for: key($0), on: nil) }
                XCTAssertEqual(Set(words).count, words.count, "\(language)")
                for (code, word) in zip(named, words) {
                    XCTAssertNotEqual(word, KeyCodes.name(for: key(code), on: nil), "\(language): \(code) is spoken as its symbol")
                }
            }
        }
    }

    func testRecorderButtonsSayWhatTheyRecordAndTheKeys() {
        speaking(.en) {
            XCTAssertEqual(KeyRecorder.spokenLabel(for: KeyCodes.tab), "Shortcut key: Tab")
            XCTAssertEqual(HoldRecorder.spokenLabel(for: [.control, .option]), "Keys to hold: Control Option")
            XCTAssertEqual(PanelKeysSection.spokenLabel(for: .close, key: "W"), "Key for “Close window”: W")
            XCTAssertEqual(PanelKeysSection.spokenLabel(for: .quit, key: nil), "Key for “Quit app”: No key")
        }
        speaking(.tr) {
            XCTAssertEqual(KeyRecorder.spokenLabel(for: KeyCodes.tab), "Kısayol tuşu: Tab")
            XCTAssertEqual(HoldRecorder.spokenLabel(for: .option), "Basılı tutulacak tuşlar: Option")
        }
    }
}
