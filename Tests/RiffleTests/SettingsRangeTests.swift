import XCTest
@testable import Riffle

/// Numbers in imported files and stored settings: never a crash, and never a value Riffle can't use. An import refuses
/// the file, a launch sets the value aside (Recovered) and goes on with the rest.
final class SettingsRangeTests: XCTestCase {
    private let defaults = SettingsSnapshot.defaults(language: .en)

    private func importing(_ key: SettingsKey, _ value: Any) throws -> Result<SettingsArchive, SettingsArchive.Problem> {
        let data = try SettingsArchive(settings: defaults, appVersion: "1.4 (52)").encoded()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var settings = try XCTUnwrap(object["settings"] as? [String: Any])
        settings[key.rawValue] = value
        object["settings"] = settings
        return SettingsArchive.read(try JSONSerialization.data(withJSONObject: object))
    }

    private func problem(_ result: Result<SettingsArchive, SettingsArchive.Problem>) -> SettingsArchive.Problem? {
        if case .failure(let problem) = result { return problem }
        return nil
    }

    private func load(_ stored: [String: Any]) -> SettingsLoad {
        SettingsLoad(stored: stored, defaults: defaults)
    }

    private func shortcut(id: Int = 0, hold: Int = 2048, key: Int = 48) -> [String: Any] {
        ["id": id, "isEnabled": true, "holdModifiers": hold, "keyCode": key]
    }

    // MARK: - Switcher keys

    func testASwitcherKeyThatIsNoKeyMakesTheFileDamagedNotACrash() throws {
        for number in [5_000_000_000, Int(UInt32.max), 128, Int.max] {
            XCTAssertEqual(problem(try importing(.panelKeys, ["keys": ["close": number], "vimKeys": false])), .damaged(.panelKeys), "\(number)")
        }
        // The last key there is, and "no key".
        let edge = try importing(.panelKeys, ["keys": ["close": 127, "quit": -1], "vimKeys": false]).get()
        XCTAssertEqual(edge.settings.panelKeys.custom, [.close: .key(127), .quit: PanelKeyBindings.Choice.none])
    }

    func testAStoredSwitcherKeyThatIsNoKeyIsSetAside() {
        for stored: Any in [Data(#"{"keys":{"close":5000000000}}"#.utf8), ["keys": ["close": 5_000_000_000]]] {
            let load = load(["panelKeys": stored])
            XCTAssertNotNil(load.unreadable["panelKeys"])
            XCTAssertEqual(load.settings.panelKeys, PanelKeyBindings())
            if case .remove? = load.writes["panelKeys"] {} else { XCTFail("not cleared: \(String(describing: load.writes["panelKeys"]))") }
        }
    }

    // MARK: - Shortcuts

    func testAShortcutWithNothingToHoldIsRefusedSayingSo() throws {
        // Nothing at all, or ⇧ alone (which only walks backwards): plain ⇥ would switch windows in every app.
        for hold in [0, 512] {
            XCTAssertEqual(problem(try importing(.profiles, [shortcut(), shortcut(id: 1, hold: hold)])), .shortcutWithoutHold, "\(hold)")
        }
        let prefs = Prefs.shared
        let persisted = Prefs.persists, language = prefs.language
        Prefs.persists = false
        defer {
            prefs.language = language
            Prefs.persists = persisted
        }
        prefs.language = .en
        XCTAssertEqual(SettingsTransfer.explanation(of: .shortcutWithoutHold),
                       "A shortcut in the file has no ⌃, ⌥ or ⌘ to hold: its key would switch windows in every app instead of typing.")
    }

    func testShortcutNumbersOutOfRangeMakeTheFileDamaged() throws {
        let cases: [[String: Any]] = [
            shortcut(key: 128), shortcut(key: 70_000), shortcut(hold: 2048 | 0x10000), shortcut(id: -1),
        ]
        for bad in cases {
            XCTAssertEqual(problem(try importing(.profiles, [shortcut(id: 1), bad])), .damaged(.profiles), "\(bad)")
        }
        // Ids that counting on from would overflow: refused before anything counts.
        XCTAssertEqual(problem(try importing(.profiles, [shortcut(id: Int.max), shortcut(id: Int.max)])), .damaged(.profiles))
        // ⇧ along with a real hold is fine, as older versions may have saved it.
        XCTAssertNoThrow(try importing(.profiles, [shortcut(hold: 2048 | 512)]).get())
    }

    func testStoredShortcutsOutOfRangeAreSetAsideAndTheOthersStay() throws {
        let stored = try JSONSerialization.data(withJSONObject: [shortcut(id: 0), shortcut(id: 1, hold: 0), shortcut(id: 2, key: 4_000_000_000),
                                                                 shortcut(id: 3, key: 49)])
        let load = load(["profiles": stored])
        XCTAssertEqual(load.settings.profiles.map(\.id), [0, 3])
        XCTAssertTrue(load.settings.profiles.allSatisfy(\.holdModifiers.isValidHold))
        XCTAssertEqual(load.unreadable["profiles"] as? Data, stored, "kept in Recovered as it was")
        guard case .set(let written as Data)? = load.writes["profiles"] else { return XCTFail("the readable shortcuts aren't written back") }
        XCTAssertEqual(ShortcutProfile.decodeList(from: written), load.settings.profiles)
    }

    func testStoredIdsThatWouldOverflowNoLongerCrashALaunch() throws {
        let stored = try JSONSerialization.data(withJSONObject: [shortcut(id: Int.max), shortcut(id: Int.max, key: 50)])
        let load = load(["profiles": stored, "didOfferSearchShortcut": true])
        XCTAssertNotNil(load.unreadable["profiles"])
        XCTAssertEqual(load.settings.profiles, Prefs.sanitized([]))
    }

    // MARK: - The appearance delay

    func testTheDelayIsBroughtIntoTheSlidersRange() throws {
        XCTAssertEqual(SettingsSnapshot.showDelayRange, 0...300)
        for (value, expected) in [(600_000, 300), (-20, 0), (150, 150), (300, 300)] {
            XCTAssertEqual(try importing(.showDelayMs, value).get().settings.showDelayMs, expected, "import \(value)")
            let load = load(["showDelayMs": Data("\(value)".utf8)])
            XCTAssertEqual(load.settings.showDelayMs, expected, "stored \(value)")
            XCTAssertTrue(load.unreadable.isEmpty)
        }
        // A number too big for any integer is as unreadable as text.
        XCTAssertEqual(problem(try importing(.showDelayMs, 1e30)), .damaged(.showDelayMs))
    }
}
