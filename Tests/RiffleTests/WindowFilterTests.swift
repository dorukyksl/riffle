import AppKit
import XCTest
@testable import Riffle

final class WindowFilterTests: XCTestCase {
    private typealias Window = WindowFilter.Window
    private typealias App = WindowFilter.App

    // Safari (two windows), Mail (one minimized), Notes, Music (hidden), Messages and Calendar (no windows).
    private let apps = [
        App(pid: 1, bundleID: "com.apple.Safari", name: "Safari", activationStamp: 50),
        App(pid: 2, bundleID: "com.apple.mail", name: "Mail", activationStamp: 40),
        App(pid: 3, bundleID: "com.apple.Notes", name: "Notes", activationStamp: 30),
        App(pid: 4, bundleID: "com.apple.Music", name: "Music", isHidden: true, activationStamp: 20),
        App(pid: 5, bundleID: "com.apple.MobileSMS", name: "Messages", activationStamp: 60),
        App(pid: 6, bundleID: "com.apple.iCal", name: "Calendar", activationStamp: 5),
    ]
    private let windows = [
        Window(wid: 11, pid: 1, title: "Start Page", focusStamp: 50),
        Window(wid: 12, pid: 1, title: "GitHub", focusStamp: 10),
        Window(wid: 21, pid: 2, title: "Inbox", isMinimized: true, focusStamp: 40),
        Window(wid: 31, pid: 3, title: "Weekend plan", focusStamp: 30),
        Window(wid: 41, pid: 4, title: "Now Playing", focusStamp: 20),
    ]

    private func profile(_ configure: (inout ShortcutProfile) -> Void = { _ in }) -> ShortcutProfile {
        var profile = ShortcutProfile(id: 0, isEnabled: true, holdModifiers: .option, keyCode: KeyCodes.tab)
        configure(&profile)
        return profile
    }

    private func rows(_ profile: ShortcutProfile, windows: [Window]? = nil, apps: [App]? = nil,
                      context: WindowFilter.Context = WindowFilter.Context()) -> [String] {
        WindowFilter.select(windows: windows ?? self.windows, apps: apps ?? self.apps, profile: profile, context: context).map { kind in
            switch kind {
            case .window(let wid): return "w\(wid)"
            case .app(let pid): return "a\(pid)"
            }
        }
    }

    private func context(front: pid_t? = nil, pointer: pid_t? = nil) -> WindowFilter.Context {
        WindowFilter.Context(anchor: WindowFilter.Anchor(frontPID: front, pointerPID: pointer))
    }

    // MARK: - Order

    func testMostRecentlyUsedFirstByDefault() {
        XCTAssertEqual(rows(profile()), ["w11", "w21", "w31", "w41", "w12"])
    }

    func testTodaysFirstShortcutStillListsAppsWithoutWindowsAtTheEnd() {
        let today = ShortcutProfile(id: 0, isEnabled: true, holdModifiers: .option, keyCode: KeyCodes.tab, scope: .allWindows,
                                    showMinimized: true, showHidden: true, showWindowlessApps: true, startInSearch: false)
        // Messages was active more recently than any window was used, and still comes after them.
        XCTAssertEqual(rows(today), ["w11", "w21", "w31", "w41", "w12", "a5", "a6"])
    }

    func testLaunchOrderGoesByAppThenByWindowAge() {
        var launched = apps
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        launched[0].launchDate = start.addingTimeInterval(300)
        launched[1].launchDate = start.addingTimeInterval(100)
        launched[3].launchDate = start.addingTimeInterval(200)
        // Notes has no launch date: after the apps that have one.
        XCTAssertEqual(rows(profile { $0.order = .launchOrder }, apps: launched), ["w21", "w41", "w11", "w12", "w31"])
    }

    func testAlphabeticalByAppThenTitle() {
        var named = apps
        named[2].name = "notes"
        XCTAssertEqual(rows(profile { $0.order = .alphabetical }, apps: named), ["w21", "w41", "w31", "w12", "w11"])
    }

    func testByDesktopGoesDesktopByDesktopThenByRecency() {
        var context = WindowFilter.Context()
        context.spaceNumbers = [100: 1, 200: 2, 300: 3]
        context.activeSpaceID = 200
        let windows = [
            Window(wid: 11, pid: 1, spaceIDs: [300], focusStamp: 50),
            Window(wid: 12, pid: 1, spaceIDs: [100], focusStamp: 10),
            Window(wid: 21, pid: 2, isMinimized: true, spaceIDs: [200], focusStamp: 40),
            // Space unknown but on screen: on the active desktop.
            Window(wid: 31, pid: 3, spaceIDs: [], isOnScreen: true, focusStamp: 30),
            // Space unknown and not on screen: last.
            Window(wid: 41, pid: 4, spaceIDs: [], isOnScreen: false, focusStamp: 20),
            // On every desktop: with the first one.
            Window(wid: 32, pid: 3, spaceIDs: [300, 100, 200], focusStamp: 5),
        ]
        XCTAssertEqual(rows(profile { $0.order = .byDesktop }, windows: windows, context: context),
                       ["w12", "w32", "w21", "w31", "w11", "w41"])
    }

    func testTiesAreBrokenTheSameWayEveryTime() {
        let windows = [Window(wid: 9, pid: 1, focusStamp: 7), Window(wid: 3, pid: 2, focusStamp: 7), Window(wid: 5, pid: 3, focusStamp: 7)]
        for _ in 0..<5 { XCTAssertEqual(rows(profile(), windows: windows), ["w3", "w5", "w9"]) }
    }

    // MARK: - Whose windows

    func testActiveAppOnly() {
        XCTAssertEqual(rows(profile { $0.apps = .activeApp }, context: context(front: 1)), ["w11", "w12"])
        XCTAssertEqual(rows(profile { $0.apps = .activeApp }, context: context(front: nil)), [])
    }

    func testAllButTheActiveApp() {
        XCTAssertEqual(rows(profile { $0.apps = .otherApps }, context: context(front: 1)), ["w21", "w31", "w41"])
    }

    func testAppUnderThePointer() {
        XCTAssertEqual(rows(profile { $0.apps = .appUnderPointer }, context: context(front: 1, pointer: 3)), ["w31"])
        XCTAssertEqual(rows(profile { $0.apps = .appUnderPointer }, context: context(front: 1, pointer: nil)), [])
    }

    func testWindowsOfAppsNobodyKnowsAreLeftOut() {
        XCTAssertEqual(rows(profile(), windows: [Window(wid: 99, pid: 99)] + windows), ["w11", "w21", "w31", "w41", "w12"])
    }

    // MARK: - Where

    func testThisDesktopListsOnlyThisDesktopsWindows() {
        var context = WindowFilter.Context()
        context.visibleSpaceIDs = [100]
        let windows = [
            Window(wid: 1, pid: 1, spaceIDs: [100], focusStamp: 9),
            Window(wid: 2, pid: 1, spaceIDs: [200], focusStamp: 8),
            // Minimized on another desktop: out (it used to be listed).
            Window(wid: 3, pid: 2, isMinimized: true, spaceIDs: [200], focusStamp: 7),
            // Minimized here: in.
            Window(wid: 4, pid: 2, isMinimized: true, spaceIDs: [100], focusStamp: 6),
            // Desktop unknown: out (it used to be listed), unless it's on screen.
            Window(wid: 5, pid: 3, isMinimized: true, spaceIDs: [], focusStamp: 5),
            Window(wid: 6, pid: 3, spaceIDs: [], isOnScreen: true, focusStamp: 4),
            Window(wid: 7, pid: 3, spaceIDs: [], isOnScreen: false, focusStamp: 3),
            // On every desktop: in.
            Window(wid: 8, pid: 4, spaceIDs: [200, 100], focusStamp: 2),
        ]
        XCTAssertEqual(rows(profile { $0.place = .thisDesktop }, windows: windows, context: context), ["w1", "w4", "w6", "w8"])
    }

    func testThisDesktopWithoutAnyPictureOfTheSpacesListsEverything() {
        let windows = [Window(wid: 1, pid: 1, spaceIDs: [200], focusStamp: 2), Window(wid: 2, pid: 1, spaceIDs: [], focusStamp: 1)]
        XCTAssertEqual(rows(profile { $0.place = .thisDesktop }, windows: windows), ["w1", "w2"])
    }

    func testThisScreen() {
        var context = WindowFilter.Context()
        context.screenRect = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let windows = [
            Window(wid: 1, pid: 1, frame: CGRect(x: 100, y: 100, width: 400, height: 300), focusStamp: 4),
            Window(wid: 2, pid: 1, frame: CGRect(x: 1200, y: 0, width: 400, height: 300), focusStamp: 3),
            Window(wid: 3, pid: 2, frame: CGRect(x: 900, y: 0, width: 400, height: 300), focusStamp: 2),
            Window(wid: 4, pid: 2, frame: .zero, focusStamp: 1),
        ]
        XCTAssertEqual(rows(profile { $0.place = .thisScreen }, windows: windows, context: context), ["w1", "w3"])
    }

    // MARK: - Minimized, hidden, full screen

    func testMinimizedWindows() {
        XCTAssertEqual(rows(profile { $0.minimized = .show }), ["w11", "w21", "w31", "w41", "w12"])
        XCTAssertEqual(rows(profile { $0.minimized = .showAtEnd }), ["w11", "w31", "w41", "w12", "w21"])
        XCTAssertEqual(rows(profile { $0.minimized = .hide }), ["w11", "w31", "w41", "w12"])
    }

    func testWindowsOfHiddenApps() {
        XCTAssertEqual(rows(profile { $0.hiddenApps = .showAtEnd }), ["w11", "w21", "w31", "w12", "w41"])
        XCTAssertEqual(rows(profile { $0.hiddenApps = .hide }), ["w11", "w21", "w31", "w12"])
    }

    func testTheStricterOptionWinsForAMinimizedWindowOfAHiddenApp() {
        let windows = [Window(wid: 1, pid: 4, isMinimized: true, focusStamp: 9), Window(wid: 2, pid: 1, focusStamp: 1)]
        XCTAssertEqual(rows(profile { $0.minimized = .showAtEnd; $0.hiddenApps = .hide }, windows: windows), ["w2"])
        XCTAssertEqual(rows(profile { $0.minimized = .show; $0.hiddenApps = .showAtEnd }, windows: windows), ["w2", "w1"])
        XCTAssertEqual(ShowOption.show.combined(with: .show), .show)
        XCTAssertEqual(ShowOption.showAtEnd.combined(with: .show), .showAtEnd)
        XCTAssertEqual(ShowOption.showAtEnd.combined(with: .hide), .hide)
    }

    func testTheEndKeepsTheChosenOrder() {
        let windows = [
            Window(wid: 1, pid: 1, title: "b", isMinimized: true, focusStamp: 9),
            Window(wid: 2, pid: 1, title: "a", isMinimized: true, focusStamp: 1),
            Window(wid: 3, pid: 3, title: "z", focusStamp: 5),
        ]
        XCTAssertEqual(rows(profile { $0.minimized = .showAtEnd; $0.order = .alphabetical }, windows: windows), ["w3", "w2", "w1"])
    }

    func testFullScreenWindows() {
        let windows = [Window(wid: 1, pid: 1, isFullscreen: true, focusStamp: 2), Window(wid: 2, pid: 2, focusStamp: 1)]
        XCTAssertEqual(rows(profile(), windows: windows), ["w1", "w2"])
        XCTAssertEqual(rows(profile { $0.showFullscreen = false }, windows: windows), ["w2"])
    }

    // MARK: - One window per app

    func testOneWindowPerAppKeepsTheMostRecentOne() {
        XCTAssertEqual(rows(profile { $0.onePerApp = true }), ["w11", "w21", "w31", "w41"])
        XCTAssertEqual(rows(profile { $0.onePerApp = true; $0.order = .alphabetical }), ["w21", "w41", "w31", "w11"])
        // The most recent one even when it goes at the end.
        let windows = [Window(wid: 1, pid: 2, isMinimized: true, focusStamp: 9), Window(wid: 2, pid: 2, focusStamp: 8),
                       Window(wid: 3, pid: 3, focusStamp: 1)]
        XCTAssertEqual(rows(profile { $0.onePerApp = true; $0.minimized = .showAtEnd }, windows: windows), ["w3", "w1"])
    }

    // MARK: - Apps without windows

    func testAppsWithoutWindowsInTheirPlace() {
        XCTAssertEqual(rows(profile { $0.windowlessApps = .show }), ["a5", "w11", "w21", "w31", "w41", "w12", "a6"])
        XCTAssertEqual(rows(profile { $0.windowlessApps = .show; $0.order = .alphabetical }),
                       ["a6", "w21", "a5", "w41", "w31", "w12", "w11"])
    }

    func testAppsWithoutWindowsAtTheEndOrHidden() {
        XCTAssertEqual(rows(profile { $0.windowlessApps = .showAtEnd; $0.minimized = .showAtEnd }),
                       ["w11", "w31", "w41", "w12", "w21", "a5", "a6"])
        XCTAssertEqual(rows(profile { $0.windowlessApps = .hide }), ["w11", "w21", "w31", "w41", "w12"])
    }

    func testAppsWithoutWindowsFollowWhoseButNotWhere() {
        XCTAssertEqual(rows(profile { $0.windowlessApps = .showAtEnd; $0.apps = .otherApps }, context: context(front: 5)),
                       ["w11", "w21", "w31", "w41", "w12", "a6"])
        // The active app is already in front: never listed for having no windows.
        XCTAssertFalse(profile { $0.apps = .activeApp }.listsWindowlessApps)
        XCTAssertEqual(rows(profile { $0.windowlessApps = .showAtEnd; $0.apps = .activeApp }, context: context(front: 5)), [])
        // The Dock icon under the pointer can be an app without windows.
        XCTAssertEqual(rows(profile { $0.windowlessApps = .showAtEnd; $0.apps = .appUnderPointer }, context: context(front: 1, pointer: 6)),
                       ["a6"])
        // The windows are on no known desktop, so none is listed; the apps without windows still are.
        var here = WindowFilter.Context()
        here.visibleSpaceIDs = [100]
        XCTAssertEqual(rows(profile { $0.windowlessApps = .showAtEnd; $0.place = .thisDesktop }, context: here), ["a5", "a6"])
    }

    func testAppsWithoutWindowsThatCantBeListed() {
        var apps = self.apps
        apps[4].canListWithoutWindows = false
        XCTAssertEqual(rows(profile { $0.windowlessApps = .showAtEnd }, apps: apps), ["w11", "w21", "w31", "w41", "w12", "a6"])
        // A hidden one follows the hidden-app option too.
        apps[5].isHidden = true
        XCTAssertEqual(rows(profile { $0.windowlessApps = .show; $0.hiddenApps = .hide }, apps: apps), ["w11", "w21", "w31", "w12"])
    }

    // MARK: - Exceptions

    func testExceptionHidingAllOfAnAppsWindows() {
        var context = WindowFilter.Context()
        context.exceptions = [AppException(bundleID: "com.apple.Safari"), AppException(bundleID: "com.apple.MobileSMS")]
        XCTAssertEqual(rows(profile { $0.windowlessApps = .showAtEnd }, context: context), ["w21", "w31", "w41", "a6"])
    }

    func testExceptionHidingAnAppOnlyWhileItHasNoWindows() {
        var context = WindowFilter.Context()
        context.exceptions = [AppException(bundleID: "com.apple.MobileSMS", hiding: .whenWindowless),
                              AppException(bundleID: "com.apple.Safari", hiding: .whenWindowless)]
        XCTAssertEqual(rows(profile { $0.windowlessApps = .showAtEnd }, context: context), ["w11", "w21", "w31", "w41", "w12", "a6"])
    }

    func testExceptionHidingWindowsByTitle() {
        var context = WindowFilter.Context()
        context.exceptions = [AppException(bundleID: "com.apple.Safari", hiding: .titleContains, titleText: "github")]
        XCTAssertEqual(rows(profile(), context: context), ["w11", "w21", "w31", "w41"])
    }

    func testExceptionForAFamilyOfApps() {
        var context = WindowFilter.Context()
        context.exceptions = [AppException(bundleID: "com.apple", matchesPrefix: true)]
        XCTAssertEqual(rows(profile { $0.windowlessApps = .showAtEnd }, context: context), [])
        context.exceptions = [AppException(bundleID: "com.apple", matchesPrefix: false)]
        XCTAssertEqual(rows(profile(), context: context), ["w11", "w21", "w31", "w41", "w12"])
    }
}
