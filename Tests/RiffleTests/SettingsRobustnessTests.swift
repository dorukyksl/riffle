import XCTest
@testable import Riffle

/// Versioned migrations and settings that can't be read, on copies of stored settings (never the real ones).
final class SettingsMigrationTests: XCTestCase {
    /// The owner's shortcuts exactly as an older version saved them.
    private let ownerProfiles = #"[{"holdModifiers":256,"startInSearch":false,"showMinimized":true,"id":0,"scope":"allWindows","showWindowlessApps":true,"showHidden":true,"isEnabled":true,"keyCode":48},{"holdModifiers":256,"startInSearch":false,"showMinimized":true,"id":1,"scope":"activeApp","showWindowlessApps":false,"showHidden":true,"isEnabled":true,"keyCode":10},{"holdModifiers":2048,"startInSearch":true,"showMinimized":true,"id":2,"scope":"allWindows","showWindowlessApps":true,"showHidden":true,"isEnabled":false,"keyCode":49}]"#

    /// The owner's stored settings: no exceptions and no settings version yet.
    private var owner: [String: Any] {
        ["profiles": Data(ownerProfiles.utf8), "language": json(#""tr""#), "style": json(#""deck""#), "theme": json(#""system""#),
         "previewSelectedWindow": json("false"), "didAdoptDeckStyle": true, "didDisableNativeCommandTab": true,
         "didOfferSearchShortcut": true, "hasCompletedOnboarding": true]
    }

    private let ownerShortcuts = [
        ShortcutProfile(id: 0, isEnabled: true, holdModifiers: .command, keyCode: 48, scope: .allWindows, showMinimized: true,
                        showHidden: true, showWindowlessApps: true, startInSearch: false),
        ShortcutProfile(id: 1, isEnabled: true, holdModifiers: .command, keyCode: 10, scope: .activeApp, showMinimized: true,
                        showHidden: true, showWindowlessApps: false, startInSearch: false),
        ShortcutProfile(id: 2, isEnabled: false, holdModifiers: .option, keyCode: 49, scope: .allWindows, showMinimized: true,
                        showHidden: true, showWindowlessApps: true, startInSearch: true),
    ]

    /// A new setup's settings; English stands for "the Mac's own language".
    private let defaults = SettingsSnapshot.defaults(language: .en)

    private func json(_ text: String) -> Data { Data(text.utf8) }

    private func load(_ stored: [String: Any]) -> SettingsLoad { SettingsLoad(stored: stored, defaults: defaults) }

    private func migrate(_ stored: [String: Any]) -> [String: Any] {
        SettingsMigration.migrate(stored, context: .init(defaultProfiles: ShortcutProfile.defaults))
    }

    private func written(_ load: SettingsLoad, _ key: String) -> Any? {
        if case .set(let value)? = load.writes[key] { return value }
        return nil
    }

    private func removes(_ load: SettingsLoad, _ key: String) -> Bool {
        if case .remove? = load.writes[key] { return true }
        return false
    }

    private func decoded<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        (value as? Data).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    // MARK: - The owner's settings

    func testTheOwnersSettingsLoadAsTheyAre() {
        let load = load(owner)
        XCTAssertEqual(load.settings.profiles, ownerShortcuts, "the three shortcuts stay intact")
        XCTAssertEqual(load.settings.profiles.map(\.isEnabled), [true, true, false])
        XCTAssertEqual(load.settings.profiles.map(\.apps), [.allApps, .activeApp, .allApps])
        XCTAssertEqual(load.settings.language, .tr, "the language stays Turkish")
        XCTAssertEqual(load.settings.style, .deck)
        XCTAssertEqual(load.settings.theme, .system)
        XCTAssertFalse(load.settings.previewSelectedWindow)
        XCTAssertEqual(load.settings.appExceptions, [])
        XCTAssertFalse(load.shortcutsPaused)
        XCTAssertTrue(load.unreadable.isEmpty)
        // Nothing the owner chose is written again: only the version is recorded.
        XCTAssertEqual(Set(load.writes.keys), [SettingsMigration.versionKey])
        XCTAssertEqual(written(load, SettingsMigration.versionKey) as? Int, SettingsMigration.latest)
    }

    func testTheOwnersSettingsMigrateToThemselves() {
        let migrated = migrate(owner)
        for (key, value) in owner {
            XCTAssertTrue((migrated[key] as AnyObject).isEqual(value as AnyObject), key)
        }
        XCTAssertEqual(Set(migrated.keys), Set(owner.keys).union([SettingsMigration.versionKey]))
        // And a second launch finds nothing left to do.
        XCTAssertTrue(load(migrated).writes.isEmpty)
    }

    func testTheOwnersSettingsAsPlainValuesReadTheSame() {
        var plain = owner
        plain["language"] = "tr"
        plain["style"] = "deck"
        plain["theme"] = "system"
        plain["previewSelectedWindow"] = false
        let load = load(plain)
        XCTAssertTrue(load.unreadable.isEmpty)
        XCTAssertEqual(load.settings.language, .tr)
        XCTAssertEqual(load.settings.profiles, ownerShortcuts)
        XCTAssertFalse(load.settings.previewSelectedWindow)
        XCTAssertEqual(Set(load.writes.keys), [SettingsMigration.versionKey])
    }

    // MARK: - Each step

    func testStepsRunOnceInOrder() {
        XCTAssertEqual(SettingsMigration.steps.map(\.version), Array(1...SettingsMigration.latest))
        let once = migrate(["profiles": Data(#"[{"id":0}]"#.utf8), "hasCompletedOnboarding": true])
        let twice = migrate(once)
        XCTAssertEqual(NSDictionary(dictionary: once), NSDictionary(dictionary: twice))
        // Settings from a newer Riffle are left alone, version included.
        let newer: [String: Any] = [SettingsMigration.versionKey: 99, "hasCompletedOnboarding": true]
        XCTAssertEqual(NSDictionary(dictionary: migrate(newer)), NSDictionary(dictionary: newer))
    }

    func testANewSetupStartsInTheMacsLanguageWithTheDefaults() {
        let load = load([:])
        XCTAssertEqual(load.settings, defaults)
        XCTAssertNil(load.writes["language"])
        XCTAssertEqual(written(load, "didAdoptDeckStyle") as? Bool, true)
        XCTAssertEqual(written(load, "didOfferSearchShortcut") as? Bool, true)
        XCTAssertEqual(decoded(SwitcherStyle.self, written(load, "style")), .deck)
        // Finishing the welcome window later doesn't make it look like a setup from before languages.
        var later: [String: Any] = [:]
        for case let (key, .set(value)) in load.writes { later[key] = value }
        later["hasCompletedOnboarding"] = true
        XCTAssertEqual(self.load(later).settings.language, .en)
    }

    func testTheStageMovesToTheDeckOnce() {
        let stage = json(#""stage""#)
        let old = migrate(["style": stage, "didAdoptStageStyle": true])
        XCTAssertEqual(decoded(SwitcherStyle.self, old["style"]), .deck)
        XCTAssertEqual(old["didAdoptDeckStyle"] as? Bool, true)
        XCTAssertNil(old["didAdoptStageStyle"])
        // Picked again after the move: it stays.
        let chosen = migrate(["style": stage, "didAdoptDeckStyle": true])
        XCTAssertEqual(decoded(SwitcherStyle.self, chosen["style"]), .stage)
        // Flags as `UserDefaults.bool(forKey:)` reads them.
        XCTAssertEqual(decoded(SwitcherStyle.self, migrate(["style": stage, "didAdoptDeckStyle": "YES"])["style"]), .stage)
        XCTAssertEqual(decoded(SwitcherStyle.self, migrate(["style": stage, "didAdoptDeckStyle": 0])["style"]), .deck)
    }

    func testSetupsFromBeforeTheSearchShortcutGetItOnce() throws {
        let two = try JSONEncoder().encode(Array(ownerShortcuts.prefix(2)))
        let offered = migrate(["profiles": two, "didAdoptDeckStyle": true])
        let profiles = try XCTUnwrap(decoded([ShortcutProfile].self, offered["profiles"]))
        XCTAssertEqual(Array(profiles.prefix(2)), Array(ownerShortcuts.prefix(2)))
        XCTAssertEqual(profiles.count, ShortcutProfile.defaults.count)
        XCTAssertEqual(profiles.last, ShortcutProfile.defaults.last)
        XCTAssertEqual(offered["didOfferSearchShortcut"] as? Bool, true)
        // Removed on purpose since: not offered again.
        let removed = migrate(["profiles": two, "didOfferSearchShortcut": true])
        XCTAssertEqual(decoded([ShortcutProfile].self, removed["profiles"])?.count, 2)
        // No list (or nothing that reads as one) means the defaults: nothing to add.
        XCTAssertNil(migrate([:])["profiles"])
        XCTAssertEqual(migrate(["profiles": json("{}")])["profiles"] as? Data, json("{}"))
    }

    func testSetupsFromBeforeLanguagesKeepTurkish() {
        XCTAssertEqual(load(["hasCompletedOnboarding": false]).settings.language, .tr)
        XCTAssertEqual(load(["hasCompletedOnboarding": true, "language": json(#""de""#)]).settings.language, .de)
        XCTAssertEqual(load(["profiles": Data(ownerProfiles.utf8)]).settings.language, .en)
    }

    func testHiddenAppsBecomeExceptionsOnce() throws {
        let load = load(["excludedBundleIDs": json(#"["com.apple.Music","com.spotify.client"]"#)])
        XCTAssertEqual(load.settings.appExceptions.map(\.bundleID), ["com.apple.Music", "com.spotify.client"])
        XCTAssertEqual(load.settings.appExceptions.map(\.hiding), [.allWindows, .allWindows])
        // Saved, so the rules keep their ids from one launch to the next.
        let saved = try XCTUnwrap(written(load, "appExceptions") as? Data)
        XCTAssertEqual(AppException.decodeList(from: saved), load.settings.appExceptions)
        // Exceptions already there win, even none at all.
        let none = self.load(["appExceptions": json("[]"), "excludedBundleIDs": json(#"["com.apple.Music"]"#)])
        XCTAssertEqual(none.settings.appExceptions, [])
        XCTAssertNil(none.writes["appExceptions"])
    }

    func testHiddenAppsWrittenByAnOlderVersionLaterStillShow() {
        let load = load([SettingsMigration.versionKey: SettingsMigration.latest, "excludedBundleIDs": json(#"["com.apple.Music"]"#)])
        XCTAssertEqual(load.settings.appExceptions.map(\.bundleID), ["com.apple.Music"])
    }

    // MARK: - Values that can't be read

    func testAnUnreadableValueFallsBackAloneAndIsKeptFirst() {
        var stored = owner
        stored["theme"] = json("not json")
        let load = load(stored)
        XCTAssertEqual(load.unreadable["theme"] as? Data, json("not json"))
        XCTAssertEqual(load.settings.theme, .system)
        XCTAssertTrue(removes(load, "theme"))
        // Every other setting is the owner's.
        XCTAssertEqual(load.settings.language, .tr)
        XCTAssertEqual(load.settings.profiles, ownerShortcuts)
        XCTAssertEqual(Set(load.unreadable.keys), ["theme"])
    }

    func testValuesOfTheWrongKindAreUnreadable() {
        let stored: [String: Any] = ["language": json(#""klingon""#), "showDelayMs": json("true"), "showBadges": Date(),
                                     "panelKeys": json(#"{"keys":{"close":"w"}}"#), "shortcutsPaused": json("3"),
                                     "didOfferSearchShortcut": true, "didAdoptDeckStyle": true, "hasCompletedOnboarding": true]
        let load = load(stored)
        XCTAssertEqual(Set(load.unreadable.keys), ["language", "showDelayMs", "showBadges", "panelKeys", "shortcutsPaused"])
        XCTAssertEqual(load.settings.language, .en)
        XCTAssertEqual(load.settings.showDelayMs, 90)
        XCTAssertTrue(load.settings.showBadges)
        XCTAssertEqual(load.settings.panelKeys, PanelKeyBindings())
        XCTAssertFalse(load.shortcutsPaused)
        for key in load.unreadable.keys { XCTAssertTrue(removes(load, key), key) }
    }

    func testADamagedShortcutIsReportedAndTheOthersStay() throws {
        var stored = owner
        stored["profiles"] = Data(#"[{"id":0,"keyCode":48,"holdModifiers":256}, 42, {"id":1,"keyCode":10,"holdModifiers":256}]"#.utf8)
        let load = load(stored)
        XCTAssertNotNil(load.unreadable["profiles"], "a shortcut was lost: that's reported")
        XCTAssertEqual(load.settings.profiles.map(\.id), [0, 1])
        let saved = try XCTUnwrap(written(load, "profiles") as? Data)
        XCTAssertEqual(ShortcutProfile.decodeList(from: saved), load.settings.profiles)
    }

    func testAnUnreadableListGetsTheDefaults() {
        var stored = owner
        stored["profiles"] = json(#"{"not":"a list"}"#)
        stored["appExceptions"] = json("7")
        let load = load(stored)
        XCTAssertEqual(Set(load.unreadable.keys), ["profiles", "appExceptions"])
        XCTAssertEqual(load.settings.profiles, ShortcutProfile.defaults)
        XCTAssertEqual(load.settings.appExceptions, [])
        XCTAssertTrue(removes(load, "profiles"))
        XCTAssertTrue(removes(load, "appExceptions"))
    }

    func testAMissingValueIsNeverUnreadable() {
        XCTAssertTrue(load([:]).unreadable.isEmpty)
        XCTAssertTrue(load(owner).unreadable.isEmpty)
    }

    func testAMigrationWritingOverAnUnreadableValueStillKeepsIt() throws {
        let load = load(["style": json("{{{")])
        XCTAssertEqual(load.unreadable["style"] as? Data, json("{{{"))
        XCTAssertEqual(decoded(SwitcherStyle.self, written(load, "style")), .deck)
    }

    func testOldHiddenAppsAreOnlyCheckedWhileTheyMatter() {
        XCTAssertNotNil(load(["excludedBundleIDs": json("nope")]).unreadable["excludedBundleIDs"])
        XCTAssertNil(load(["excludedBundleIDs": json("nope"), "appExceptions": json("[]")]).unreadable["excludedBundleIDs"])
    }
}

final class SettingsFilesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("riffle-settings-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testUnreadableValuesAreKeptAsTheyWere() throws {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let stamp = SettingsFiles.stamp(date)
        let kept = SettingsFiles.keep(["theme": Data("not json".utf8), "language": "klingon", "showBadges": date],
                                      in: folder, date: date)
        // In settings order, named after the key and the date.
        XCTAssertEqual(kept.map(\.key), ["theme", "language", "showBadges"])
        XCTAssertEqual(kept.map(\.file), ["theme-\(stamp).json", "language-\(stamp).json", "showBadges-\(stamp).json"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("theme-\(stamp).json")), Data("not json".utf8))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("language-\(stamp).json"), encoding: .utf8), #""klingon""#)
        // Not JSON at all: a property list, still raw.
        let plist = try Data(contentsOf: folder.appendingPathComponent("showBadges-\(stamp).json"))
        XCTAssertEqual(try PropertyListSerialization.propertyList(from: plist, format: nil) as? Date, date)
        // The same key twice in a second: never over the first.
        let again = SettingsFiles.keep(["theme": Data("other".utf8)], in: folder, date: date)
        XCTAssertEqual(again.map(\.file), ["theme-\(stamp)-2.json"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("theme-\(stamp).json")), Data("not json".utf8))
    }

    func testNothingIsKeptWhereNothingCanBeWritten() throws {
        // A file where the folder should be.
        try Data().write(to: folder)
        XCTAssertEqual(SettingsFiles.keep(["theme": Data("x".utf8)], in: folder.appendingPathComponent("Recovered")), [])
    }

    func testOnlyTheNewestBackupsStay() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for day in 1...12 {
            let name = String(format: "settings-2026-10-%02d-120000.json", day)
            try Data("{}".utf8).write(to: folder.appendingPathComponent(name))
        }
        try Data().write(to: folder.appendingPathComponent("notes.txt"))
        SettingsFiles.pruneBackups(in: folder, keeping: 10)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(left.count, 11)
        XCTAssertEqual(left.first, "notes.txt")
        XCTAssertEqual(left[1], "settings-2026-10-03-120000.json")
    }
}
