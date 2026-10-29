import XCTest
@testable import Riffle

/// Words in the welcome window and General that follow the language and the shortcuts in use.
final class SettingsWordingTests: XCTestCase {
    private var language = AppLanguage.en
    private var persisted = true

    override func setUp() {
        persisted = Prefs.persists
        Prefs.persists = false
        language = Prefs.shared.language
    }

    override func tearDown() {
        Prefs.shared.language = language
        Prefs.persists = persisted
    }

    func testMillisecondsAreWrittenTheLanguagesWay() throws {
        XCTAssertEqual(L.milliseconds(90, in: .en), "90 ms")
        XCTAssertEqual(L.milliseconds(90, in: .de), "90 ms")
        // The last scan's duration is rounded to whole milliseconds.
        XCTAssertEqual(L.milliseconds(12.4, in: .en), "12 ms")
        for language in AppLanguage.allCases {
            XCTAssertTrue(L.milliseconds(250, in: language).contains("250"), "\(language)")
        }
        // Xcode's test runner writes every unit in English, whatever the locale; Riffle (or any other process) doesn't.
        guard L.milliseconds(90, in: .ru) != "90 ms" else { throw XCTSkip("this test runner writes units in English only") }
        XCTAssertEqual(L.milliseconds(90, in: .ru), "90 мс")
        XCTAssertEqual(L.milliseconds(90, in: .tr), "90\u{202F}msn")
        Prefs.shared.language = .tr
        XCTAssertEqual(L.milliseconds(300), "300\u{202F}msn")
    }

    func testTheDelayIsExplainedWithTheFirstShortcutsKeys() {
        Prefs.shared.language = .en
        XCTAssertEqual(AppearanceDelay.caption(for: ShortcutProfile.defaults),
                       "A quick ⌥⇥ tap switches to the previous window without ever showing the switcher. This sets when the switcher appears.")
        var commandTab = ShortcutProfile.defaults
        commandTab[0].holdModifiers = .command
        XCTAssertTrue(AppearanceDelay.caption(for: commandTab).hasPrefix("A quick ⌘⇥ tap"))
        Prefs.shared.language = .tr
        XCTAssertTrue(AppearanceDelay.caption(for: commandTab).hasPrefix("Hızlı bir ⌘⇥ dokunuşunda"))
    }

    func testTheWelcomeWindowOffersBothShortcutsTheWayMacOSWritesThem() {
        XCTAssertEqual(OnboardingWindow.holdChoices, [.option, .command])
        XCTAssertEqual(OnboardingWindow.holdChoices.map { KeyCodes.shortcutDescription(modifiers: $0, keyCode: KeyCodes.tab) }, ["⌥⇥", "⌘⇥"])
        // A new setup starts on the first.
        XCTAssertEqual(ShortcutProfile.defaults[0].holdModifiers, OnboardingWindow.holdChoices[0])
        Prefs.shared.language = .en
        XCTAssertEqual(OnboardingWindow.holdChoices.map { KeyCodes.spokenDescription(modifiers: $0, keyCode: KeyCodes.tab) },
                       ["Option Tab", "Command Tab"])
    }
}
