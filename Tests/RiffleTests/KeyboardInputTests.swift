import AppKit
import Carbon
import XCTest
@testable import Riffle

/// Real layouts as macOS ships them, read without selecting them. Key positions are ANSI so results don't depend on
/// the keyboard of the Mac running the tests.
private enum Layouts {
    static let ansi: UInt32 = 40
    static let iso: UInt32 = 41

    static func load(_ id: String, keyboardType: UInt32 = ansi) throws -> KeyboardLayout {
        guard let layout = KeyboardLayout.installed("com.apple.keylayout." + id, keyboardType: keyboardType) else {
            throw XCTSkip("keyboard layout \(id) isn't installed")
        }
        return layout
    }
}

private func key(_ code: Int) -> UInt32 { UInt32(code) }

final class PanelKeyLayoutTests: XCTestCase {
    private func keys(_ map: PanelKeyMap) -> [PanelKey: UInt32] {
        map.slots.mapValues(\.keyCode)
    }

    func testDefaultsOnUS() throws {
        let map = PanelKeyBindings().resolved(on: try Layouts.load("US"))
        XCTAssertEqual(keys(map), [.search: key(kVK_ANSI_S), .searchAlternate: key(kVK_ANSI_Slash), .close: key(kVK_ANSI_W),
                                   .minimize: key(kVK_ANSI_M), .fullscreen: key(kVK_ANSI_F), .hide: key(kVK_ANSI_H), .quit: key(kVK_ANSI_Q)])
        XCTAssertEqual(map.slots[.searchAlternate]?.label, "/")
        XCTAssertEqual(map.slots[.close]?.label, "W")
        XCTAssertTrue(map.moves.isEmpty)
    }

    func testDefaultsOnTurkishQ() throws {
        // The letters are where QWERTY has them; "/" is only ⇧7 there, and 7 jumps to the seventh window.
        for keyboardType in [Layouts.ansi, Layouts.iso] {
            let map = PanelKeyBindings().resolved(on: try Layouts.load("Turkish-QWERTY-PC", keyboardType: keyboardType))
            XCTAssertEqual(keys(map), [.search: key(kVK_ANSI_S), .close: key(kVK_ANSI_W), .minimize: key(kVK_ANSI_M),
                                       .fullscreen: key(kVK_ANSI_F), .hide: key(kVK_ANSI_H), .quit: key(kVK_ANSI_Q)])
            XCTAssertNil(map.slots[.searchAlternate])
        }
    }

    func testDefaultsOnFrenchAZERTY() throws {
        let map = PanelKeyBindings().resolved(on: try Layouts.load("French"))
        // AZERTY: W is where QWERTY has Z, Q where it has A, M next to L. "/" is ⇧ on the ":" key, which gets it.
        XCTAssertEqual(keys(map), [.search: key(kVK_ANSI_S), .searchAlternate: key(kVK_ANSI_Period), .close: key(kVK_ANSI_Z),
                                   .minimize: key(kVK_ANSI_Semicolon), .fullscreen: key(kVK_ANSI_F), .hide: key(kVK_ANSI_H),
                                   .quit: key(kVK_ANSI_A)])
        XCTAssertEqual(map.slots[.searchAlternate]?.label, "/")
        XCTAssertEqual(map.slots[.quit]?.label, "Q")
    }

    func testDefaultsOnGermanQWERTZ() throws {
        let map = PanelKeyBindings().resolved(on: try Layouts.load("German"))
        XCTAssertEqual(keys(map), [.search: key(kVK_ANSI_S), .close: key(kVK_ANSI_W), .minimize: key(kVK_ANSI_M),
                                   .fullscreen: key(kVK_ANSI_F), .hide: key(kVK_ANSI_H), .quit: key(kVK_ANSI_Q)])
        // ⇧7 again; the key QWERTY has "/" on types "-" here, and isn't taken over.
        XCTAssertNil(map.slots[.searchAlternate])
    }

    func testDefaultsOnRussianFallBackToQWERTYPlaces() throws {
        let layout = try Layouts.load("Russian")
        XCTAssertFalse(layout.typesLatinLetters)
        let map = PanelKeyBindings().resolved(on: layout)
        XCTAssertEqual(keys(map), [.search: key(kVK_ANSI_S), .searchAlternate: key(kVK_ANSI_Slash), .close: key(kVK_ANSI_W),
                                   .minimize: key(kVK_ANSI_M), .fullscreen: key(kVK_ANSI_F), .hide: key(kVK_ANSI_H), .quit: key(kVK_ANSI_Q)])
        // Shown by the Latin letter printed next to the Cyrillic one.
        XCTAssertEqual(map.slots[.search]?.label, "S")
    }

    func testLayoutsThatTypeLatinLetters() throws {
        for id in ["US", "Turkish-QWERTY-PC", "French", "German", "Dvorak"] {
            XCTAssertTrue(try Layouts.load(id).typesLatinLetters, id)
        }
        for id in ["Russian", "Greek", "Hebrew", "Arabic", "Thai", "2SetHangul"] {
            XCTAssertFalse(try Layouts.load(id).typesLatinLetters, id)
        }
    }

    func testHebrewSlashKeepsItsKey() throws {
        // Hebrew types "/" on the key QWERTY has Q on: search keeps it, as it always did, and quit has no key there.
        let map = PanelKeyBindings().resolved(on: try Layouts.load("Hebrew"))
        XCTAssertEqual(map.slots[.searchAlternate]?.keyCode, key(kVK_ANSI_Q))
        XCTAssertNil(map.slots[.quit])
        XCTAssertEqual(map.slots[.close]?.keyCode, key(kVK_ANSI_W))
    }

    func testKeypadAndDigitsAreNeverDefaults() throws {
        for id in ["US", "Turkish-QWERTY-PC", "French", "German", "Russian", "Thai"] {
            let map = PanelKeyBindings().resolved(on: try Layouts.load(id))
            for binding in map.slots.values {
                XCTAssertFalse(FixedPanelKeys.codes.contains(binding.keyCode), "\(id): \(binding)")
                XCTAssertFalse((65...92).contains(Int(binding.keyCode)), "\(id): keypad \(binding)")
            }
            XCTAssertEqual(Set(map.slots.values.map(\.keyCode)).count, map.slots.count, "\(id): a key used twice")
        }
    }

    func testWithoutLayoutInformationQWERTYPlacesAreUsed() {
        let map = PanelKeyBindings().resolved(on: nil)
        XCTAssertEqual(map.slots[.close]?.keyCode, key(kVK_ANSI_W))
        XCTAssertEqual(map.slots[.searchAlternate]?.keyCode, key(kVK_ANSI_Slash))
    }

    func testCommandsByKey() throws {
        let map = PanelKeyBindings().resolved(on: try Layouts.load("US"))
        XCTAssertEqual(map.command(for: key(kVK_ANSI_S)), .search)
        XCTAssertEqual(map.command(for: key(kVK_ANSI_Slash)), .search)
        XCTAssertEqual(map.command(for: key(kVK_ANSI_W)), .perform(.close))
        XCTAssertEqual(map.command(for: key(kVK_ANSI_Q)), .perform(.quit))
        XCTAssertNil(map.command(for: key(kVK_ANSI_J)))
    }
}

final class VimKeyTests: XCTestCase {
    private var vim: PanelKeyBindings {
        var bindings = PanelKeyBindings()
        bindings.vimKeys = true
        return bindings
    }

    func testVimKeysOnAZERTYAndQWERTZ() throws {
        for id in ["French", "German", "US", "Turkish-QWERTY-PC"] {
            let map = vim.resolved(on: try Layouts.load(id))
            XCTAssertEqual(map.moves, [key(kVK_ANSI_H): .left, key(kVK_ANSI_J): .down, key(kVK_ANSI_K): .up, key(kVK_ANSI_L): .right], id)
            XCTAssertEqual(map.command(for: key(kVK_ANSI_J)), .move(.down), id)
            // H moves left now: hide has no key until it's given one.
            XCTAssertNil(map.slots[.hide], id)
            XCTAssertEqual(vim.displacedByVimKeys(on: try Layouts.load(id)), [.hide], id)
        }
    }

    func testVimKeysOnRussianUseQWERTYPlaces() throws {
        let map = vim.resolved(on: try Layouts.load("Russian"))
        XCTAssertEqual(map.moves, [key(kVK_ANSI_H): .left, key(kVK_ANSI_J): .down, key(kVK_ANSI_K): .up, key(kVK_ANSI_L): .right])
        XCTAssertNil(map.slots[.hide])
    }

    func testVimKeysFollowTheLettersOnDvorak() throws {
        let map = vim.resolved(on: try Layouts.load("Dvorak"))
        XCTAssertEqual(map.moves, [key(kVK_ANSI_J): .left, key(kVK_ANSI_C): .down, key(kVK_ANSI_V): .up, key(kVK_ANSI_P): .right])
    }

    func testOffByDefault() {
        XCTAssertFalse(PanelKeyBindings().vimKeys)
        XCTAssertTrue(PanelKeyBindings().displacedByVimKeys(on: nil).isEmpty)
    }

    func testAKeyPickedByHandBlocksVimKeys() throws {
        let us = try Layouts.load("US")
        var bindings = PanelKeyBindings()
        bindings.assign(key(kVK_ANSI_L), to: .close, on: us)
        XCTAssertEqual(bindings.vimConflicts(on: us), [.close])
        // Hide's default H doesn't count: defaults make way.
        XCTAssertEqual(PanelKeyBindings().vimConflicts(on: us), [])
    }

    func testAKeyPickedByHandBeatsVimKeys() throws {
        // Possible after switching layouts: the hand-picked key wins, that Vim key does nothing.
        let us = try Layouts.load("US")
        var bindings = vim
        bindings.custom[.close] = .key(key(kVK_ANSI_L))
        let map = bindings.resolved(on: us)
        XCTAssertEqual(map.command(for: key(kVK_ANSI_L)), .perform(.close))
        XCTAssertFalse(map.moves.values.contains(.right))
    }
}

final class PanelKeyBindingTests: XCTestCase {
    func testRebindingAndConflicts() throws {
        let us = try Layouts.load("US")
        var bindings = PanelKeyBindings()
        XCTAssertNil(bindings.conflict(assigning: key(kVK_ANSI_X), to: .close, on: us, shortcutKeys: []))
        XCTAssertNil(bindings.conflict(assigning: key(kVK_ANSI_W), to: .close, on: us, shortcutKeys: []))
        XCTAssertEqual(bindings.conflict(assigning: key(kVK_ANSI_Q), to: .close, on: us, shortcutKeys: []), .taken(by: .quit))
        XCTAssertEqual(bindings.conflict(assigning: key(kVK_ANSI_S), to: .searchAlternate, on: us, shortcutKeys: []), .taken(by: .search))
        for fixed in [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Escape, kVK_Tab, kVK_LeftArrow, kVK_DownArrow, kVK_ANSI_1, kVK_ANSI_9, kVK_ANSI_Keypad5] {
            XCTAssertEqual(bindings.conflict(assigning: key(fixed), to: .close, on: us, shortcutKeys: []), .fixed, "\(fixed)")
        }
        XCTAssertNil(bindings.conflict(assigning: key(kVK_ANSI_0), to: .close, on: us, shortcutKeys: []))
        XCTAssertEqual(bindings.conflict(assigning: key(kVK_ANSI_Grave), to: .close, on: us, shortcutKeys: [key(kVK_ANSI_Grave)]), .shortcut)
        bindings.vimKeys = true
        XCTAssertEqual(bindings.conflict(assigning: key(kVK_ANSI_K), to: .close, on: us, shortcutKeys: []), .vimKeys)
        // Hide lost H to the Vim keys; G is free.
        XCTAssertNil(bindings.conflict(assigning: key(kVK_ANSI_G), to: .hide, on: us, shortcutKeys: []))
    }

    func testAssignedKeysArePhysicalAndWorkOnEveryLayout() throws {
        let us = try Layouts.load("US"), french = try Layouts.load("French"), russian = try Layouts.load("Russian")
        var bindings = PanelKeyBindings()
        bindings.assign(key(kVK_ANSI_X), to: .close, on: us)
        XCTAssertEqual(bindings.custom[.close], .key(key(kVK_ANSI_X)))
        for layout in [us, french, russian] {
            let map = bindings.resolved(on: layout)
            XCTAssertEqual(map.slots[.close]?.keyCode, key(kVK_ANSI_X), layout.id)
            XCTAssertEqual(map.command(for: key(kVK_ANSI_X)), .perform(.close), layout.id)
        }
        // Picking the key a command would get anyway puts it back on the layout's default.
        bindings.assign(key(kVK_ANSI_W), to: .close, on: us)
        XCTAssertNil(bindings.custom[.close])
        XCTAssertEqual(bindings.resolved(on: french).slots[.close]?.keyCode, key(kVK_ANSI_Z))
    }

    func testClearedKeys() throws {
        let us = try Layouts.load("US")
        var bindings = PanelKeyBindings()
        bindings.assign(nil, to: .searchAlternate, on: us)
        let map = bindings.resolved(on: us)
        XCTAssertNil(map.slots[.searchAlternate])
        XCTAssertNil(map.command(for: key(kVK_ANSI_Slash)))
        XCTAssertEqual(map.command(for: key(kVK_ANSI_S)), .search)
    }

    func testAKeyPickedByHandWinsOverADefaultOnAnotherLayout() throws {
        // Close moved to the key next to L on a US layout; on AZERTY that key types M, which minimize would want.
        let us = try Layouts.load("US"), french = try Layouts.load("French")
        var bindings = PanelKeyBindings()
        bindings.assign(key(kVK_ANSI_Semicolon), to: .close, on: us)
        let map = bindings.resolved(on: french)
        XCTAssertEqual(map.command(for: key(kVK_ANSI_Semicolon)), .perform(.close))
        XCTAssertNil(map.slots[.minimize])
    }

    func testSavedAndLoaded() throws {
        var bindings = PanelKeyBindings()
        bindings.custom = [.close: .key(7), .searchAlternate: .none]
        bindings.vimKeys = true
        let data = try JSONEncoder().encode(bindings)
        XCTAssertEqual(try JSONDecoder().decode(PanelKeyBindings.self, from: data), bindings)
        // Nothing saved yet, or names this version doesn't know: defaults, the rest kept.
        XCTAssertEqual(try JSONDecoder().decode(PanelKeyBindings.self, from: Data("{}".utf8)), PanelKeyBindings())
        let other = try JSONDecoder().decode(PanelKeyBindings.self, from: Data(#"{"keys":{"teleport":3,"quit":12}}"#.utf8))
        XCTAssertEqual(other.custom, [.quit: .key(12)])
        XCTAssertFalse(other.vimKeys)
    }

    func testKeyNamesFollowTheLayout() throws {
        XCTAssertEqual(KeyCodes.name(for: key(kVK_ANSI_Z), on: try Layouts.load("French")), "W")
        XCTAssertEqual(KeyCodes.name(for: key(kVK_ANSI_Z), on: try Layouts.load("German")), "Y")
        XCTAssertEqual(KeyCodes.name(for: key(kVK_ANSI_S), on: try Layouts.load("Russian")), "Ы")
        XCTAssertEqual(KeyCodes.name(for: KeyCodes.tab, on: nil), "⇥")
        XCTAssertEqual(KeyCodes.name(for: key(kVK_ANSI_S), on: nil), "#1")
    }
}

final class ReleaseBehaviorTests: XCTestCase {
    private func profile(_ behavior: ReleaseBehavior = .switchToSelected) -> ShortcutProfile {
        var profile = ShortcutProfile(id: 4, isEnabled: true, holdModifiers: [.control, .option], keyCode: KeyCodes.tab, scope: .allWindows,
                                      showMinimized: true, showHidden: false, showWindowlessApps: false, startInSearch: false)
        profile.releaseBehavior = behavior
        return profile
    }

    func testDefaultIsSwitching() {
        XCTAssertEqual(profile().releaseBehavior, .switchToSelected)
        XCTAssertTrue(ShortcutProfile.defaults.allSatisfy { $0.releaseBehavior == .switchToSelected })
    }

    func testSavedAndLoaded() throws {
        let saved = [profile(.keepOpen), profile(.keepOpenAndSearch)]
        XCTAssertEqual(try JSONDecoder().decode([ShortcutProfile].self, from: JSONEncoder().encode(saved)), saved)
    }

    func testShortcutsSavedBeforeTheSettingStillLoad() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile(.keepOpen))) as? [String: Any])
        object["releaseBehavior"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: [object])
        let loaded = try JSONDecoder().decode([ShortcutProfile].self, from: legacy)
        XCTAssertEqual(loaded.first?.releaseBehavior, .switchToSelected)
        XCTAssertEqual(loaded.first?.holdModifiers, [.control, .option])
        // A value from a newer version.
        object["releaseBehavior"] = "somethingNew"
        let newer = try JSONDecoder().decode([ShortcutProfile].self, from: JSONSerialization.data(withJSONObject: [object]))
        XCTAssertEqual(newer.first?.releaseBehavior, .switchToSelected)
    }

    func testSwitchOnRelease() {
        var state = HoldRelease(isSticky: false, isSearching: false)
        XCTAssertEqual(state.release(.switchToSelected), .switchToSelection)
    }

    func testKeepOpen() {
        var state = HoldRelease(isSticky: false, isSearching: false)
        XCTAssertEqual(state.release(.keepOpen), .stayOpen)
        XCTAssertEqual(state, HoldRelease(isSticky: true, isSearching: false, isReleased: true))
        // Held and let go again (⌥⇥ once more to move on): still open, ↩ or a click decides.
        XCTAssertEqual(state.release(.keepOpen), .none)
        XCTAssertTrue(state.isSticky)
    }

    func testKeepOpenAndSearch() {
        var state = HoldRelease(isSticky: false, isSearching: false)
        XCTAssertEqual(state.release(.keepOpenAndSearch), .startSearching)
        XCTAssertEqual(state, HoldRelease(isSticky: true, isSearching: true, isReleased: true))
        XCTAssertEqual(state.release(.keepOpenAndSearch), .none)
        // Already searching (S pressed while holding): just stays.
        var searching = HoldRelease(isSticky: true, isSearching: true)
        XCTAssertEqual(searching.release(.keepOpenAndSearch), .none)
        var notSticky = HoldRelease(isSticky: false, isSearching: true)
        XCTAssertEqual(notSticky.release(.keepOpenAndSearch), .stayOpen)
    }

    func testStickySessionsIgnoreTheBehaviour() {
        // Opened from the menu bar, or a search-first shortcut: they stay open whatever the shortcut says.
        for behavior in ReleaseBehavior.allCases {
            var menuBar = HoldRelease(isSticky: true, isSearching: false)
            XCTAssertEqual(menuBar.release(behavior), .none, "\(behavior)")
            XCTAssertEqual(menuBar, HoldRelease(isSticky: true, isSearching: false, isReleased: true))
            var searchFirst = HoldRelease(isSticky: true, isSearching: true)
            XCTAssertEqual(searchFirst.release(behavior), .none, "\(behavior)")
        }
    }

    func testQuickTap() {
        // The key is already up when the switcher is summoned: the same release, before anything is on screen.
        var tap = HoldRelease(isSticky: false, isSearching: false)
        XCTAssertEqual(tap.release(.switchToSelected), .switchToSelection)
        var keep = HoldRelease(isSticky: false, isSearching: false)
        XCTAssertEqual(keep.release(.keepOpen), .stayOpen)
        XCTAssertTrue(keep.isSticky)
        var search = HoldRelease(isSticky: false, isSearching: false)
        XCTAssertEqual(search.release(.keepOpenAndSearch), .startSearching)
    }
}

final class HoldReadingTests: XCTestCase {
    private let option: NSEvent.ModifierFlags = .option

    func testWithoutTapOnlyTheKeyboardStateCountsAndItIsPolled() {
        XCTAssertEqual(HoldReading(hold: option, hardware: .option, events: nil, secureInput: false), reading(held: true, polling: true))
        XCTAssertEqual(HoldReading(hold: option, hardware: [], events: nil, secureInput: false), reading(held: false, polling: true))
    }

    func testAgreeingEvidenceNeedsNoPolling() {
        XCTAssertEqual(HoldReading(hold: option, hardware: [.option, .shift], events: [.option, .shift], secureInput: false),
                       reading(held: true, polling: false))
        XCTAssertEqual(HoldReading(hold: option, hardware: [], events: [], secureInput: false), reading(held: false, polling: false))
    }

    func testDisagreementCountsAsHeldAndIsPolled() {
        // A remapping tool's synthesized ⌥ shows up only in events…
        XCTAssertEqual(HoldReading(hold: option, hardware: [], events: .option, secureInput: false), reading(held: true, polling: true))
        // …and the keyboard state can be a beat behind an event (or the tap missed one).
        XCTAssertEqual(HoldReading(hold: option, hardware: .option, events: [], secureInput: false), reading(held: true, polling: true))
    }

    func testSecureInputIsPolled() {
        XCTAssertEqual(HoldReading(hold: option, hardware: .option, events: .option, secureInput: true), reading(held: true, polling: true))
    }

    func testCombinationsAreReleasedWhenAnyKeyGoesUp() {
        let hold: NSEvent.ModifierFlags = [.control, .option, .command]
        XCTAssertTrue(HoldReading(hold: hold, hardware: hold, events: hold, secureInput: false).isHeld)
        XCTAssertFalse(HoldReading(hold: hold, hardware: [.control, .option], events: [.control, .option], secureInput: false).isHeld)
    }

    func testNothingToHold() {
        XCTAssertEqual(HoldReading(hold: [], hardware: .option, events: .option, secureInput: false), reading(held: false, polling: false))
    }

    private func reading(held: Bool, polling: Bool) -> HoldReading {
        HoldReading(hold: .option, hardware: held ? .option : [], events: polling ? nil : (held ? .option : []), secureInput: false)
    }
}

final class HoldCombinationTests: XCTestCase {
    func testEveryCombinationOfControlOptionCommandIsOffered() {
        let choices = CarbonModifiers.holdChoices
        XCTAssertEqual(choices.count, 7)
        XCTAssertEqual(Set(choices.map(\.rawValue)).count, 7)
        for choice in choices {
            XCTAssertFalse(choice.isEmpty)
            XCTAssertTrue(CarbonModifiers.holdable.isSuperset(of: choice))
        }
    }

    func testRecordingAHold() {
        var capture = HoldCapture()
        // ⌃ down, ⌥ down, ⌃ up, ⌥ up: both were held together.
        XCTAssertNil(capture.update(sent: .control))
        XCTAssertNil(capture.update(sent: [.control, .option]))
        XCTAssertEqual(capture.held, [.control, .option])
        XCTAssertNil(capture.update(sent: .option))
        XCTAssertEqual(capture.update(sent: []), [.control, .option])
        // ⇧ alone records nothing; ⇧ with ⌘ records ⌘.
        XCTAssertNil(capture.update(sent: .shift))
        XCTAssertNil(capture.update(sent: []))
        XCTAssertNil(capture.update(sent: [.shift, .command]))
        XCTAssertEqual(capture.update(sent: []), .command)
        // All three.
        XCTAssertNil(capture.update(sent: [.control, .option, .command]))
        XCTAssertEqual(capture.update(sent: []), [.control, .option, .command])
    }

    func testEventFlagsRoundTrip() {
        for choice in CarbonModifiers.holdChoices + [[.shift], [.shift, .command]] {
            XCTAssertEqual(CarbonModifiers(eventFlags: choice.eventFlags), choice)
        }
        XCTAssertEqual(CarbonModifiers(eventFlags: [.option, .capsLock, .function]), .option)
    }
}
