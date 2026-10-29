import Carbon
import XCTest
@testable import Riffle

final class KeyNameTests: XCTestCase {
    private let turkishQ = KeyboardLayout(id: "fixture.TurkishQ", plain: [
        UInt32(kVK_ANSI_Q): "q", UInt32(kVK_ANSI_I): "ı", UInt32(kVK_ANSI_Semicolon): "ş",
        UInt32(kVK_ANSI_LeftBracket): "ğ", UInt32(kVK_ANSI_Grave): " ", UInt32(kVK_ANSI_Comma): "\u{A0}",
    ])

    func testNamedKeysLookTheSameOnEveryLayout() {
        let named: [(Int, String)] = [
            (kVK_Tab, "⇥"), (kVK_Return, "↩"), (kVK_Escape, "⎋"), (kVK_Delete, "⌫"), (kVK_ForwardDelete, "⌦"),
            (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_UpArrow, "↑"), (kVK_DownArrow, "↓"),
            (kVK_Home, "↖"), (kVK_End, "↘"), (kVK_PageUp, "⇞"), (kVK_PageDown, "⇟"), (kVK_F1, "F1"), (kVK_F12, "F12"),
        ]
        for (code, name) in named {
            XCTAssertEqual(KeyCodes.name(for: UInt32(code), on: turkishQ), name)
            XCTAssertEqual(KeyCodes.name(for: UInt32(code), on: nil), name)
        }
        XCTAssertEqual(KeyCodes.name(for: KeyCodes.space, on: turkishQ), L.t("Boşluk", "Space"))
    }

    func testLettersAreTheLayoutsInCapitals() {
        XCTAssertEqual(KeyCodes.name(for: UInt32(kVK_ANSI_Q), on: turkishQ), "Q")
        XCTAssertEqual(KeyCodes.name(for: UInt32(kVK_ANSI_I), on: turkishQ), "I")
        XCTAssertEqual(KeyCodes.name(for: UInt32(kVK_ANSI_Semicolon), on: turkishQ), "Ş")
        XCTAssertEqual(KeyCodes.name(for: UInt32(kVK_ANSI_LeftBracket), on: turkishQ), "Ğ")
    }

    func testKeysWithoutAVisibleCharacterGoByNumber() {
        XCTAssertEqual(KeyCodes.name(for: UInt32(kVK_ANSI_Grave), on: turkishQ), "#\(kVK_ANSI_Grave)")
        XCTAssertEqual(KeyCodes.name(for: UInt32(kVK_ANSI_Comma), on: turkishQ), "#\(kVK_ANSI_Comma)")
        XCTAssertEqual(KeyCodes.name(for: UInt32(kVK_ANSI_Z), on: turkishQ), "#\(kVK_ANSI_Z)")
    }

    func testShortcutsReadModifiersThenKey() {
        XCTAssertEqual(KeyCodes.shortcutDescription(modifiers: [.command, .control], keyCode: KeyCodes.tab), "⌃⌘⇥")
        XCTAssertEqual(KeyCodes.shortcutDescription(modifiers: [], keyCode: UInt32(kVK_F5)), "F5")
        XCTAssertEqual(CarbonModifiers().symbols, "")
    }

    func testEachModifierMapsToItsEventFlag() {
        XCTAssertEqual(CarbonModifiers.command.eventFlags, .command)
        XCTAssertEqual(CarbonModifiers.option.eventFlags, .option)
        XCTAssertEqual(CarbonModifiers.control.eventFlags, .control)
        XCTAssertEqual(CarbonModifiers.shift.eventFlags, .shift)
        XCTAssertEqual(CarbonModifiers().eventFlags, [])
    }

    func testModifiersSaveAsTheirCarbonValue() throws {
        let data = try JSONEncoder().encode([CarbonModifiers.option, [.control, .command]])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\(optionKey),\(controlKey | cmdKey)]")
        XCTAssertEqual(try JSONDecoder().decode([CarbonModifiers].self, from: data), [.option, [.control, .command]])
    }

    func testTabTypesNoCharacter() {
        XCTAssertNil(KeyCodes.character(for: KeyCodes.tab))
    }
}
