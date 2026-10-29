import XCTest
@testable import Riffle

final class AppExceptionTests: XCTestCase {
    func testExactIdentifierIgnoresCase() {
        let safari = AppException(bundleID: "com.apple.Safari")
        XCTAssertTrue(safari.matches("com.apple.Safari"))
        XCTAssertTrue(safari.matches("COM.APPLE.SAFARI"))
        XCTAssertFalse(safari.matches("com.apple.SafariTechnologyPreview"))
        XCTAssertFalse(safari.matches("com.apple"))
        XCTAssertFalse(safari.matches(nil))
    }

    func testPrefixCoversWholePartsOnly() {
        let microsoft = AppException(bundleID: "com.microsoft", matchesPrefix: true)
        XCTAssertTrue(microsoft.matches("com.microsoft"))
        XCTAssertTrue(microsoft.matches("com.microsoft.Word"))
        XCTAssertTrue(microsoft.matches("com.microsoft.rdc.macos"))
        XCTAssertFalse(microsoft.matches("com.microsoftedge.app"))
        XCTAssertFalse(microsoft.matches("org.microsoft.Word"))
        // What people type for "everything under it" means the same.
        for typed in ["com.microsoft.", "com.microsoft.*", " com.microsoft* "] {
            XCTAssertTrue(AppException(bundleID: typed, matchesPrefix: true).matches("com.microsoft.Excel"), typed)
        }
    }

    func testAnEmptyIdentifierMatchesNothing() {
        for typed in ["", "  ", "*", "."] {
            XCTAssertFalse(AppException(bundleID: typed, matchesPrefix: true).matches("com.apple.Safari"), typed)
            XCTAssertFalse(AppException(bundleID: typed).matches(""), typed)
        }
    }

    func testWhatEachHidingHides() {
        let all = AppException(bundleID: "a", hiding: .allWindows)
        XCTAssertTrue(all.hidesWindow(titled: "Anything"))
        XCTAssertTrue(all.hidesWindowlessApp)
        let windowless = AppException(bundleID: "a", hiding: .whenWindowless)
        XCTAssertFalse(windowless.hidesWindow(titled: "Anything"))
        XCTAssertTrue(windowless.hidesWindowlessApp)
        let nothing = AppException(bundleID: "a", hiding: .nothing)
        XCTAssertFalse(nothing.hidesWindow(titled: "Anything"))
        XCTAssertFalse(nothing.hidesWindowlessApp)
    }

    func testTitleTextIgnoresCaseAccentsAndTurkishI() {
        let secret = AppException(bundleID: "a", hiding: .titleContains, titleText: " özel GİZLİ ")
        XCTAssertTrue(secret.hidesWindow(titled: "Notlar — Özel gizli liste"))
        XCTAssertTrue(secret.hidesWindow(titled: "OZEL GIZLI"))
        XCTAssertFalse(secret.hidesWindow(titled: "Özel liste"))
        XCTAssertFalse(secret.hidesWindowlessApp)
        XCTAssertFalse(AppException(bundleID: "a", hiding: .titleContains, titleText: "  ").hidesWindow(titled: "Anything"))
    }

    func testTheStrictestShortcutRuleWins() {
        let exceptions = [
            AppException(bundleID: "com.parallels", matchesPrefix: true, hiding: .nothing, ignoresShortcuts: .whileFullscreen),
            AppException(bundleID: "com.parallels.desktop.console", hiding: .nothing, ignoresShortcuts: .always),
            AppException(bundleID: "com.apple.Safari"),
        ]
        XCTAssertEqual(AppException.shortcutRule(for: "com.parallels.desktop.console", in: exceptions), .always)
        XCTAssertEqual(AppException.shortcutRule(for: "com.parallels.vm", in: exceptions), .whileFullscreen)
        XCTAssertEqual(AppException.shortcutRule(for: "com.apple.Safari", in: exceptions), .never)
        XCTAssertEqual(AppException.shortcutRule(for: nil, in: exceptions), .never)
    }

    func testWhenShortcutsAreLeftToTheApp() {
        XCTAssertFalse(AppException.ignoresShortcuts(.never, isFullscreen: true))
        XCTAssertTrue(AppException.ignoresShortcuts(.always, isFullscreen: false))
        XCTAssertTrue(AppException.ignoresShortcuts(.whileFullscreen, isFullscreen: true))
        XCTAssertFalse(AppException.ignoresShortcuts(.whileFullscreen, isFullscreen: false))
    }

    func testExcludedAppsBecomeHiddenAlways() {
        let migrated = AppException.migrated(from: ["com.apple.Music", "com.spotify.client", "COM.APPLE.MUSIC", ""])
        XCTAssertEqual(migrated.map(\.bundleID), ["com.apple.Music", "com.spotify.client"])
        for exception in migrated {
            XCTAssertEqual(exception.hiding, .allWindows)
            XCTAssertFalse(exception.matchesPrefix)
            XCTAssertEqual(exception.ignoresShortcuts, .never)
        }
        XCTAssertEqual(Set(migrated.map(\.id)).count, 2)
    }

    func testDecodingKeepsWhatItCanAndNeverHidesByMistake() throws {
        let json = #"[{"bundleID":"com.x","hiding":"sometimes","ignoresShortcuts":"perhaps"}, 7, "y", "#
            + #"{"bundleID":"com.y","matchesPrefix":true,"hiding":"titleContains","titleText":"Secret","ignoresShortcuts":"whileFullscreen","name":"Y"}]"#
        let exceptions = try XCTUnwrap(AppException.decodeList(from: Data(json.utf8)))
        XCTAssertEqual(exceptions.count, 2)
        XCTAssertEqual(exceptions[0].bundleID, "com.x")
        XCTAssertEqual(exceptions[0].hiding, .nothing)
        XCTAssertEqual(exceptions[0].ignoresShortcuts, .never)
        XCTAssertNotEqual(exceptions[0].id, exceptions[1].id)
        XCTAssertEqual(exceptions[1].hiding, .titleContains)
        XCTAssertEqual(exceptions[1].titleText, "Secret")
        XCTAssertEqual(exceptions[1].ignoresShortcuts, .whileFullscreen)
        XCTAssertTrue(exceptions[1].matchesPrefix)
        XCTAssertEqual(exceptions[1].name, "Y")
        XCTAssertNil(AppException.decodeList(from: Data("{}".utf8)))
    }

    func testSavedExceptionsReadBackTheSame() throws {
        let exceptions = [AppException(bundleID: "com.a", matchesPrefix: true, name: "A", hiding: .titleContains, titleText: "x",
                                       ignoresShortcuts: .always),
                          AppException(bundleID: "com.b")]
        XCTAssertEqual(AppException.decodeList(from: try JSONEncoder().encode(exceptions)), exceptions)
    }

    func testPresetsAreConsistent() {
        let presets = AppException.presets
        XCTAssertGreaterThanOrEqual(presets.count, 10)
        XCTAssertEqual(Set(presets.map { AppException.normalized($0.bundleID) }).count, presets.count)
        for preset in presets {
            let exception = preset.exception
            XCTAssertEqual(exception.ignoresShortcuts, .whileFullscreen, preset.name)
            XCTAssertEqual(exception.hiding, .nothing, preset.name)
            XCTAssertFalse(preset.appIDs.isEmpty, preset.name)
            // Each covers the very apps it names.
            for id in preset.appIDs { XCTAssertTrue(exception.matches(id), "\(preset.name): \(id)") }
        }
        let windowsApp = presets.first { $0.name == "Windows App" }?.exception
        XCTAssertEqual(windowsApp?.matches("com.microsoft.rdc.macos"), true)
        XCTAssertEqual(windowsApp?.matches("com.microsoft.Word"), false)
    }

    func testAddingPresetsTwiceAddsThemOnce() {
        let utm = AppException(bundleID: "com.utmapp.UTM")
        let all = AppException.presets.map(\.exception)
        let once = AppException.adding(all, to: [utm])
        XCTAssertEqual(once.count, all.count)
        // The app that was already there keeps its hiding and gets the preset's shortcut rule.
        XCTAssertEqual(once[0].id, utm.id)
        XCTAssertEqual(once[0].hiding, .allWindows)
        XCTAssertEqual(once[0].ignoresShortcuts, .whileFullscreen)
        XCTAssertEqual(AppException.adding(all, to: once), once)
        // An exact rule and a prefix rule for the same identifier are different rules.
        XCTAssertEqual(AppException.adding([AppException(bundleID: "com.a", matchesPrefix: true)], to: [AppException(bundleID: "com.a")]).count, 2)
    }

    func testAWindowThatFillsADisplayIsFullScreen() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let second = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        XCTAssertTrue(WindowProbe.covers(display, anyOf: [display, second]))
        XCTAssertTrue(WindowProbe.covers(second.insetBy(dx: 0.5, dy: 0.5), anyOf: [display, second]))
        // Zoomed, below the menu bar: not full screen.
        XCTAssertFalse(WindowProbe.covers(CGRect(x: 0, y: 33, width: 1512, height: 949), anyOf: [display, second]))
        XCTAssertFalse(WindowProbe.covers(CGRect(x: 100, y: 100, width: 800, height: 600), anyOf: [display]))
    }
}
