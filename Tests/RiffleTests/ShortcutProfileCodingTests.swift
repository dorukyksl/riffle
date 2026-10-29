import XCTest
@testable import Riffle

final class ShortcutProfileCodingTests: XCTestCase {
    /// Three shortcuts exactly as the version before this one saved them (the owner's own settings, byte for byte).
    private let olderVersionsList = #"[{"holdModifiers":256,"startInSearch":false,"showMinimized":true,"id":0,"scope":"allWindows","showWindowlessApps":true,"showHidden":true,"isEnabled":true,"keyCode":48},{"holdModifiers":256,"startInSearch":false,"showMinimized":true,"id":1,"scope":"activeApp","showWindowlessApps":false,"showHidden":true,"isEnabled":true,"keyCode":10},{"holdModifiers":2048,"startInSearch":true,"showMinimized":true,"id":2,"scope":"allWindows","showWindowlessApps":true,"showHidden":true,"isEnabled":false,"keyCode":49}]"#

    /// The shortcut as the version before this one had it, with its synthesized coding: what an older version reads.
    private struct OlderProfile: Codable, Equatable {
        var id: Int
        var isEnabled: Bool
        var holdModifiers: CarbonModifiers
        var keyCode: UInt32
        var scope: WindowScope
        var showMinimized: Bool
        var showHidden: Bool
        var showWindowlessApps: Bool
        var startInSearch: Bool
    }

    private func decode(_ json: String) -> [ShortcutProfile]? {
        ShortcutProfile.decodeList(from: Data(json.utf8))
    }

    func testOlderVersionsListKeepsEveryShortcut() throws {
        let profiles = try XCTUnwrap(decode(olderVersionsList))
        XCTAssertEqual(profiles, [
            ShortcutProfile(id: 0, isEnabled: true, holdModifiers: .command, keyCode: 48, scope: .allWindows, showMinimized: true,
                            showHidden: true, showWindowlessApps: true, startInSearch: false),
            ShortcutProfile(id: 1, isEnabled: true, holdModifiers: .command, keyCode: 10, scope: .activeApp, showMinimized: true,
                            showHidden: true, showWindowlessApps: false, startInSearch: false),
            ShortcutProfile(id: 2, isEnabled: false, holdModifiers: .option, keyCode: 49, scope: .allWindows, showMinimized: true,
                            showHidden: true, showWindowlessApps: true, startInSearch: true),
        ])
        let first = profiles[0]
        XCTAssertEqual(first.apps, .allApps)
        XCTAssertEqual(first.place, .allDesktops)
        XCTAssertEqual(first.order, .recentlyUsed)
        XCTAssertFalse(first.onePerApp)
        XCTAssertEqual(first.minimized, .show)
        XCTAssertEqual(first.hiddenApps, .show)
        XCTAssertEqual(first.windowlessApps, .showAtEnd)
        XCTAssertTrue(first.showFullscreen)
        XCTAssertNil(first.style)
        XCTAssertEqual(profiles[1].apps, .activeApp)
        XCTAssertEqual(profiles[1].windowlessApps, .hide)
        // Saved before letting go could do anything else: they switch, as they always did.
        XCTAssertEqual(profiles.map(\.releaseBehavior), [.switchToSelected, .switchToSelected, .switchToSelected])
        // The same through the plain decoder, which reads the whole list or nothing.
        XCTAssertEqual(try JSONDecoder().decode([ShortcutProfile].self, from: Data(olderVersionsList.utf8)), profiles)
    }

    func testEveryFieldSurvivesSavingAndLoading() throws {
        let plain = ShortcutProfile(id: 8, isEnabled: true, holdModifiers: .option, keyCode: KeyCodes.tab)
        var profile = plain
        profile.isEnabled = false
        profile.holdModifiers = [.control, .command]
        profile.keyCode = 12
        profile.apps = .otherApps
        profile.place = .thisScreen
        profile.order = .alphabetical
        profile.onePerApp = true
        profile.minimized = .hide
        profile.hiddenApps = .showAtEnd
        profile.windowlessApps = .show
        profile.showFullscreen = false
        profile.style = .list
        profile.startInSearch = true
        profile.releaseBehavior = .keepOpenAndSearch
        // Every field really differs from a plain shortcut, so one the coding forgot couldn't pass unnoticed.
        let fields: [(String, (ShortcutProfile) -> AnyHashable)] = [
            ("isEnabled", { $0.isEnabled }), ("holdModifiers", { $0.holdModifiers }), ("keyCode", { $0.keyCode }),
            ("apps", { $0.apps }), ("place", { $0.place }), ("order", { $0.order }), ("onePerApp", { $0.onePerApp }),
            ("minimized", { $0.minimized }), ("hiddenApps", { $0.hiddenApps }), ("windowlessApps", { $0.windowlessApps }),
            ("showFullscreen", { $0.showFullscreen }), ("style", { $0.style }), ("startInSearch", { $0.startInSearch }),
            ("releaseBehavior", { $0.releaseBehavior }),
        ]
        for (name, field) in fields { XCTAssertNotEqual(field(profile), field(plain), name) }
        let data = try JSONEncoder().encode([profile])
        XCTAssertEqual(try JSONDecoder().decode([ShortcutProfile].self, from: data), [profile])
        XCTAssertEqual(ShortcutProfile.decodeList(from: data), [profile])
    }

    func testEveryOlderScopeBecomesAppsAndPlace() throws {
        let cases: [(String, AppScope, PlaceScope)] = [("allWindows", .allApps, .allDesktops), ("activeApp", .activeApp, .allDesktops),
                                                       ("currentSpace", .allApps, .thisDesktop), ("currentScreen", .allApps, .thisScreen)]
        for (scope, apps, place) in cases {
            let profile = try XCTUnwrap(decode(#"[{"id":0,"scope":"\#(scope)","showMinimized":false,"showHidden":false,"showWindowlessApps":true}]"#)?.first)
            XCTAssertEqual(profile.apps, apps, scope)
            XCTAssertEqual(profile.place, place, scope)
            XCTAssertEqual(profile.minimized, .hide, scope)
            XCTAssertEqual(profile.hiddenApps, .hide, scope)
            // The switch for apps without windows only ever worked with every window on every desktop.
            XCTAssertEqual(profile.windowlessApps, scope == "allWindows" ? .showAtEnd : .hide, scope)
        }
    }

    func testAShortcutWithAlmostNothingTakesTheDefaults() throws {
        let profile = try XCTUnwrap(decode(#"[{"id":3}]"#)?.first)
        XCTAssertEqual(profile.id, 3)
        XCTAssertTrue(profile.isEnabled)
        XCTAssertEqual(profile.keyCode, KeyCodes.tab)
        XCTAssertEqual(profile.holdModifiers, .option)
        XCTAssertEqual(profile.apps, .allApps)
        XCTAssertEqual(profile.place, .allDesktops)
        XCTAssertEqual(profile.minimized, .show)
        XCTAssertEqual(profile.windowlessApps, .hide)
        XCTAssertFalse(profile.startInSearch)
    }

    func testWrongTypesAndUnknownValuesFallBackFieldByField() throws {
        let json = #"[{"id":4,"isEnabled":"yes","keyCode":-1,"holdModifiers":2048,"apps":"everyone","place":"thisDesktop","order":"random","#
            + #""minimized":"sometimes","hiddenApps":"hide","style":"hologram","onePerApp":"true","showFullscreen":false}]"#
        let profile = try XCTUnwrap(decode(json)?.first)
        XCTAssertEqual(profile.id, 4)
        XCTAssertTrue(profile.isEnabled)
        XCTAssertEqual(profile.keyCode, KeyCodes.tab)
        XCTAssertEqual(profile.holdModifiers, .option)
        XCTAssertEqual(profile.apps, .allApps)
        XCTAssertEqual(profile.place, .thisDesktop)
        XCTAssertEqual(profile.order, .recentlyUsed)
        XCTAssertEqual(profile.minimized, .show)
        XCTAssertEqual(profile.hiddenApps, .hide)
        XCTAssertNil(profile.style, "an unknown style means the one chosen in Appearance")
        XCTAssertFalse(profile.onePerApp)
        XCTAssertFalse(profile.showFullscreen)
    }

    func testANewFieldsValueBeatsTheOlderOnes() throws {
        let profile = try XCTUnwrap(decode(#"[{"id":0,"scope":"currentSpace","apps":"otherApps","place":"thisScreen","showMinimized":true,"minimized":"showAtEnd"}]"#)?.first)
        XCTAssertEqual(profile.apps, .otherApps)
        XCTAssertEqual(profile.place, .thisScreen)
        XCTAssertEqual(profile.minimized, .showAtEnd)
        // An unknown new value falls back to what the older field said.
        let partial = try XCTUnwrap(decode(#"[{"id":0,"scope":"activeApp","apps":"future"}]"#)?.first)
        XCTAssertEqual(partial.apps, .activeApp)
    }

    func testADamagedShortcutDoesNotCostTheOthers() throws {
        let profiles = try XCTUnwrap(decode(#"[{"id":0,"keyCode":48}, 42, "nine", null, [], {"id":1,"keyCode":10}]"#))
        XCTAssertEqual(profiles.map(\.id), [0, 1])
        XCTAssertEqual(profiles.map(\.keyCode), [48, 10])
        XCTAssertNil(decode("{}"))
        XCTAssertNil(decode("not json"))
        XCTAssertEqual(decode("[]"), [])
    }

    func testSavedShortcutsReadBackTheSame() throws {
        var profile = ShortcutProfile(id: 7, isEnabled: false, holdModifiers: [.control, .option], keyCode: 12)
        profile.apps = .appUnderPointer
        profile.place = .thisScreen
        profile.order = .byDesktop
        profile.onePerApp = true
        profile.minimized = .showAtEnd
        profile.hiddenApps = .hide
        profile.windowlessApps = .show
        profile.showFullscreen = false
        profile.style = .titles
        profile.startInSearch = true
        let data = try JSONEncoder().encode([profile, ShortcutProfile.defaults[1]])
        XCTAssertEqual(ShortcutProfile.decodeList(from: data), [profile, ShortcutProfile.defaults[1]])
    }

    func testAnOlderVersionCanStillReadWhatIsSaved() throws {
        var thisDesktop = ShortcutProfile(id: 0, isEnabled: true, holdModifiers: .option, keyCode: 48)
        thisDesktop.place = .thisDesktop
        thisDesktop.minimized = .hide
        thisDesktop.windowlessApps = .showAtEnd
        var activeApp = ShortcutProfile(id: 1, isEnabled: true, holdModifiers: .command, keyCode: 10)
        activeApp.apps = .activeApp
        activeApp.hiddenApps = .showAtEnd
        let older = try JSONDecoder().decode([OlderProfile].self, from: JSONEncoder().encode([thisDesktop, activeApp]))
        XCTAssertEqual(older, [
            OlderProfile(id: 0, isEnabled: true, holdModifiers: .option, keyCode: 48, scope: .currentSpace, showMinimized: false,
                         showHidden: true, showWindowlessApps: true, startInSearch: false),
            OlderProfile(id: 1, isEnabled: true, holdModifiers: .command, keyCode: 10, scope: .activeApp, showMinimized: true,
                         showHidden: true, showWindowlessApps: false, startInSearch: false),
        ])
    }

    func testOlderShapeStillBuildsAndReads() {
        var profile = ShortcutProfile(id: 0, isEnabled: true, holdModifiers: .option, keyCode: 48, scope: .currentScreen,
                                      showMinimized: false, showHidden: true, showWindowlessApps: true, startInSearch: true)
        XCTAssertEqual(profile.place, .thisScreen)
        XCTAssertEqual(profile.minimized, .hide)
        XCTAssertEqual(profile.windowlessApps, .hide)
        XCTAssertTrue(profile.startInSearch)
        for scope in WindowScope.allCases {
            profile.scope = scope
            XCTAssertEqual(profile.scope, scope)
        }
        profile.apps = .otherApps
        profile.place = .thisDesktop
        XCTAssertEqual(profile.scope, .currentSpace)
        profile.showHidden = false
        XCTAssertEqual(profile.hiddenApps, .hide)
        profile.showWindowlessApps = true
        XCTAssertEqual(profile.windowlessApps, .showAtEnd)
    }

    func testTheDefaultShortcutsAreTheSameAsBefore() {
        let defaults = ShortcutProfile.defaults
        XCTAssertEqual(defaults.map(\.apps), [.allApps, .activeApp, .allApps])
        XCTAssertEqual(defaults.map(\.place), [.allDesktops, .allDesktops, .allDesktops])
        XCTAssertEqual(defaults.map(\.windowlessApps), [.showAtEnd, .hide, .showAtEnd])
        XCTAssertEqual(defaults.map(\.order), [.recentlyUsed, .recentlyUsed, .recentlyUsed])
        XCTAssertEqual(defaults.map(\.style), [nil, nil, nil])
        let added = ShortcutProfile.added(id: 3, besides: defaults)
        XCTAssertEqual(added.windowlessApps, .hide)
        XCTAssertEqual(added.minimized, .show)
    }
}
