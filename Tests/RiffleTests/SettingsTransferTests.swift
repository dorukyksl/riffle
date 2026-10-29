import XCTest
@testable import Riffle

/// Export, import and reset: the settings file and what reading it accepts.
final class SettingsArchiveTests: XCTestCase {
    /// Settings that differ from the defaults in every key, so a value the file forgot couldn't pass unnoticed.
    private lazy var custom: SettingsSnapshot = {
        var settings = SettingsSnapshot.defaults(language: .en)
        var search = ShortcutProfile(id: 4, isEnabled: true, holdModifiers: [.control, .option], keyCode: 49)
        search.startInSearch = true
        search.order = .alphabetical
        settings.profiles = [ShortcutProfile.defaults[0], search]
        settings.style = .list
        settings.size = .large
        settings.theme = .dark
        settings.glass = .clear
        settings.screen = .main
        settings.language = .tr
        settings.showDelayMs = 150
        settings.showBadges = false
        settings.showSpaceNumbers = false
        settings.previewSelectedWindow = true
        settings.titleContent = .appAndWindowTitle
        settings.titleTruncation = .middle
        settings.pointerFollowsSwitch = true
        settings.panelAnimations = false
        settings.mouseHoverSelects = false
        settings.hapticFeedback = false
        settings.showMenuBarIcon = false
        settings.appExceptions = [AppException(bundleID: "com.parallels", matchesPrefix: true, name: "Parallels", hiding: .nothing,
                                               ignoresShortcuts: .whileFullscreen),
                                  AppException(bundleID: "com.apple.Music")]
        settings.panelKeys.vimKeys = true
        settings.panelKeys.custom[.close] = .key(13)
        settings.panelKeys.custom[.quit] = PanelKeyBindings.Choice.none
        return settings
    }()

    private func file(_ settings: SettingsSnapshot = SettingsSnapshot.defaults(language: .en)) throws -> [String: Any] {
        let data = try SettingsArchive(settings: settings, appVersion: "1.4 (52)").encoded()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func read(_ object: Any) -> Result<SettingsArchive, SettingsArchive.Problem> {
        SettingsArchive.read((try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    private func problem(_ result: Result<SettingsArchive, SettingsArchive.Problem>) -> SettingsArchive.Problem? {
        if case .failure(let problem) = result { return problem }
        return nil
    }

    func testEverySettingSurvivesExportAndImport() throws {
        let defaults = SettingsSnapshot.defaults(language: .en)
        for key in SettingsKey.allCases {
            XCTAssertNotEqual(custom.encoded(key), defaults.encoded(key), key.rawValue)
        }
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let data = try SettingsArchive(settings: custom, appVersion: "1.4 (52)", exportedAt: date).encoded()
        let archive = try SettingsArchive.read(data).get()
        XCTAssertEqual(archive.settings, custom)
        XCTAssertEqual(archive.appVersion, "1.4 (52)")
        XCTAssertEqual(archive.formatVersion, SettingsArchive.currentFormatVersion)
        XCTAssertEqual(archive.exportedAt, date)
    }

    func testTheFileCarriesItsFormatAndEverySettingButNothingElse() throws {
        let object = try file(custom)
        XCTAssertEqual(object["format"] as? String, "riffle-settings")
        XCTAssertEqual(object["formatVersion"] as? Int, 1)
        XCTAssertEqual(object["appVersion"] as? String, "1.4 (52)")
        XCTAssertNotNil(object["exportedAt"] as? String)
        let settings = try XCTUnwrap(object["settings"] as? [String: Any])
        XCTAssertEqual(Set(settings.keys), Set(SettingsKey.allCases.map(\.rawValue)))
        // No window frames, one-time flags or states.
        for left in ["hasCompletedOnboarding", "didDisableNativeCommandTab", "didAdoptDeckStyle", "didOfferSearchShortcut",
                     "settingsVersion", "shortcutsPaused", "NSWindow Frame RiffleSettings", "excludedBundleIDs"] {
            XCTAssertNil(settings[left], left)
            XCTAssertNil(object[left], left)
        }
    }

    func testFilesThatArentSettingsAreRefused() {
        XCTAssertEqual(problem(SettingsArchive.read(Data("{\"format\": \"riffle-settings\"".utf8))), .notJSON, "cut short")
        XCTAssertEqual(problem(SettingsArchive.read(Data())), .notJSON)
        XCTAssertEqual(problem(read(["format": "something-else", "formatVersion": 1, "settings": [:]])), .notSettings)
        XCTAssertEqual(problem(read([1, 2, 3])), .notSettings)
        XCTAssertEqual(problem(SettingsArchive.read(Data(count: SettingsArchive.sizeLimit + 1))), .unreadableFile)
    }

    func testANewerFormatIsRefused() throws {
        var object = try file()
        object["formatVersion"] = SettingsArchive.currentFormatVersion + 1
        object["appVersion"] = "9.0 (900)"
        XCTAssertEqual(problem(read(object)), .newerFormat(appVersion: "9.0 (900)"))
        object["formatVersion"] = "1"
        XCTAssertEqual(problem(read(object)), .damaged(nil))
    }

    func testAPartialFileIsRefused() throws {
        var object = try file()
        var settings = try XCTUnwrap(object["settings"] as? [String: Any])
        settings["panelKeys"] = nil
        settings["language"] = nil
        object["settings"] = settings
        XCTAssertEqual(problem(read(object)), .incomplete([.language, .panelKeys]))
        object["settings"] = nil
        XCTAssertEqual(problem(read(object)), .incomplete(SettingsKey.allCases))
    }

    func testADamagedValueIsRefused() throws {
        let cases: [(SettingsKey, Any)] = [
            (.theme, 42), (.language, "klingon"), (.showDelayMs, "fast"), (.showBadges, NSNull()), (.panelKeys, ["keys": ["close": "w"]]),
            // A list with an entry that can't be read is refused whole, not read in part.
            (.profiles, [["id": 0, "keyCode": 48], 7]), (.appExceptions, [["bundleID": "com.a"], "b"]),
            // Shortcuts as Riffle can't keep them.
            (.profiles, []), (.profiles, [["id": 1], ["id": 1]]), (.profiles, (0..<10).map { ["id": $0] }),
        ]
        for (key, value) in cases {
            var object = try file()
            var settings = try XCTUnwrap(object["settings"] as? [String: Any])
            settings[key.rawValue] = value
            object["settings"] = settings
            XCTAssertEqual(problem(read(object)), .damaged(key), "\(key.rawValue): \(value)")
        }
    }

    func testChangesAreSummedUpTheWaySettingsIsGrouped() {
        let current = SettingsSnapshot.defaults(language: .en)
        XCTAssertEqual(current.changes(to: current), [])
        XCTAssertEqual(current.changes(to: custom), [.language(from: .en, to: .tr), .general, .shortcuts(from: 3, to: 2), .panelKeys,
                                                      .appearance, .exceptions(from: 0, to: 2)])
        var sameCount = current
        sameCount.profiles[1].keyCode = 12
        XCTAssertEqual(current.changes(to: sameCount), [.shortcuts(from: 3, to: 3)])
        // The same rules from another Mac (other ids) change nothing.
        var mine = current
        mine.appExceptions = custom.appExceptions
        var theirs = mine
        theirs.appExceptions = custom.appExceptions.map { var rule = $0; rule.id = UUID(); return rule }
        XCTAssertEqual(mine.changes(to: theirs), [])
        theirs.appExceptions[1].hiding = .whenWindowless
        XCTAssertEqual(mine.changes(to: theirs), [.exceptions(from: 2, to: 2)])
    }

    func testEveryChangeAndProblemHasWordsInBothLanguages() {
        let changes: [SettingsChange] = [.shortcuts(from: 3, to: 2), .shortcuts(from: 3, to: 3), .exceptions(from: 0, to: 4),
                                         .exceptions(from: 2, to: 2), .panelKeys, .appearance, .general, .language(from: .tr, to: .en)]
        let problems: [SettingsArchive.Problem] = [.unreadableFile, .notJSON, .notSettings, .newerFormat(appVersion: "9.0"),
                                                   .newerFormat(appVersion: nil), .incomplete([.theme, .profiles]), .damaged(.panelKeys), .damaged(nil),
                                                   .shortcutWithoutHold]
        let prefs = Prefs.shared
        let persisted = Prefs.persists
        let language = prefs.language
        Prefs.persists = false
        defer {
            prefs.language = language
            Prefs.persists = persisted
        }
        for language in [AppLanguage.tr, .en] {
            prefs.language = language
            let texts = changes.map(SettingsTransfer.describe) + problems.map(SettingsTransfer.explanation)
            for text in texts {
                XCTAssertFalse(text.isEmpty)
                XCTAssertFalse(text.contains("%"), text)
            }
            XCTAssertEqual(Set(texts).count, texts.count, "\(language): two different things read the same")
            for key in SettingsLoad.keys where !key.hasPrefix("did") && key != "hasCompletedOnboarding" && key != SettingsMigration.versionKey {
                XCTAssertNotEqual(SettingsTransfer.name(of: key), key, "\(language): \(key) has no name")
            }
        }
    }

    func testResettingGivesANewSetupsSettings() {
        let defaults = SettingsSnapshot.defaults(language: .de)
        XCTAssertEqual(defaults.profiles, ShortcutProfile.defaults)
        XCTAssertEqual(defaults.style, .deck)
        XCTAssertEqual(defaults.size, .auto)
        XCTAssertEqual(defaults.theme, .system)
        XCTAssertEqual(defaults.glass, .regular)
        XCTAssertEqual(defaults.screen, .mouse)
        XCTAssertEqual(defaults.language, .de)
        XCTAssertEqual(defaults.showDelayMs, 90)
        XCTAssertTrue(defaults.showBadges && defaults.showSpaceNumbers && defaults.mouseHoverSelects && defaults.hapticFeedback)
        XCTAssertTrue(defaults.showMenuBarIcon)
        XCTAssertFalse(defaults.previewSelectedWindow)
        XCTAssertEqual(defaults.appExceptions, [])
        XCTAssertEqual(defaults.panelKeys, PanelKeyBindings())
        XCTAssertEqual(SettingsSnapshot.defaults().language, AppLanguage.system)
    }

    func testPrefsHandsOverAndTakesEverySettingAtOnce() {
        let prefs = Prefs.shared
        let persisted = Prefs.persists
        let before = prefs.snapshot
        let paused = prefs.shortcutsPaused
        Prefs.persists = false
        defer {
            prefs.apply(before)
            Prefs.persists = persisted
        }
        prefs.apply(custom)
        XCTAssertEqual(prefs.snapshot, custom)
        // A state, not a setting: left as it was.
        XCTAssertEqual(prefs.shortcutsPaused, paused)
        var tooMany = custom
        tooMany.profiles = (0..<12).map { ShortcutProfile(id: $0 % 3, isEnabled: true, holdModifiers: .option, keyCode: 48) }
        prefs.apply(tooMany)
        XCTAssertEqual(prefs.profiles, Prefs.sanitized(tooMany.profiles))
    }
}

/// Reset and import keep the settings they replace, and give them back.
final class SettingsReplacementTests: XCTestCase {
    private var folder: URL!
    private var before: SettingsSnapshot!
    private var previous: PreviousSettings?
    private var persisted = true

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("riffle-backups-\(UUID().uuidString)", isDirectory: true)
        persisted = Prefs.persists
        Prefs.persists = false
        before = Prefs.shared.snapshot
        previous = Prefs.shared.previousSettings
    }

    override func tearDownWithError() throws {
        Prefs.shared.apply(before)
        Prefs.shared.previousSettings = previous
        Prefs.persists = persisted
        try? FileManager.default.removeItem(at: folder)
    }

    private var changed: SettingsSnapshot {
        var settings = before!
        settings.theme = settings.theme == .dark ? .light : .dark
        settings.showDelayMs += 10
        settings.profiles = [ShortcutProfile(id: 0, isEnabled: true, holdModifiers: .control, keyCode: 48)]
        return settings
    }

    func testTheReplacedSettingsAreBackedUpFirstAndComeBack() throws {
        let prefs = Prefs.shared
        let target = changed
        XCTAssertTrue(SettingsTransfer.replaceAll(with: target, because: .reset, backups: folder))
        XCTAssertEqual(prefs.snapshot, target)
        let notice = try XCTUnwrap(prefs.previousSettings)
        XCTAssertEqual(notice.reason, .reset)
        XCTAssertTrue(notice.file.hasPrefix("settings-") && notice.file.hasSuffix(".json"), notice.file)
        // The backup is an export of what was there before.
        XCTAssertEqual(try SettingsArchive.read(contentsOf: folder.appendingPathComponent(notice.file)).get().settings, before)
        XCTAssertNil(SettingsTransfer.restorePrevious(from: folder))
        XCTAssertEqual(prefs.snapshot, before)
        XCTAssertNil(prefs.previousSettings)
    }

    func testNothingChangesWithoutABackup() throws {
        let prefs = Prefs.shared
        prefs.previousSettings = nil
        // A file where the folder should be: no backup can be written.
        try Data().write(to: folder)
        XCTAssertFalse(SettingsTransfer.replaceAll(with: changed, because: .imported, backups: folder))
        XCTAssertEqual(prefs.snapshot, before)
        XCTAssertNil(prefs.previousSettings)
    }

    func testABackupThatIsGoneChangesNothing() {
        let prefs = Prefs.shared
        prefs.previousSettings = PreviousSettings(file: "settings-gone.json", reason: .imported)
        XCTAssertEqual(SettingsTransfer.restorePrevious(from: folder), .unreadableFile)
        XCTAssertEqual(prefs.snapshot, before)
        XCTAssertNotNil(prefs.previousSettings)
    }
}
