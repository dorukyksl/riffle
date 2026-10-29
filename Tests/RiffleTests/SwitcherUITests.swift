import AppKit
import XCTest
@testable import Riffle

/// Builds the switcher offscreen (never ordered in) for 30 made-up windows and times each kind of rebuild. Prints the
/// medians; it asserts nothing about time, which depends on the machine.
final class SwitcherBuildBenchmark: XCTestCase {
    private static var thirty: [SwitcherItem] = {
        _ = NSApplication.shared
        Prefs.persists = false
        var items = [SwitcherItem]()
        for batch in 0..<4 {
            items += MockRender.items(MockRender.samples, language: .en, firstWID: CGWindowID(30_000 + batch * 100), thumbnailWidth: 320).items
        }
        return Array(items.prefix(30))
    }()

    private func median(_ runs: Int, _ body: () -> Void) -> Double {
        var times = [Double]()
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return times.sorted()[times.count / 2]
    }

    func testDeckBuildTimes() throws {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let items = SwitcherBuildBenchmark.thirty
        let dark = NSAppearance(named: .darkAqua)!
        let previousStyle = Prefs.shared.style
        Prefs.shared.style = .deck
        defer { Prefs.shared.style = previousStyle }
        func show(_ ui: SwitcherUI, _ items: [SwitcherItem], searching: Bool = false, query: String = "") {
            ui.prepareOffscreen(items: items, selected: 1, searching: searching, query: query, screen: screen, appearance: dark)
        }
        // Warm the process-wide caches (icons, fonts, symbols) so every row measures the switcher itself.
        show(SwitcherUI(), items)

        let cold = median(9) { show(SwitcherUI(), items) }
        let ui = SwitcherUI()
        show(ui, items)
        let again = median(9) { show(ui, items) }
        var rotation = 0
        let reordered = median(9) {
            rotation += 1
            let cut = rotation % items.count
            show(ui, Array(items[cut...]) + Array(items[..<cut]))
        }
        var closing = 0
        let oneFewer = median(9) {
            closing += 1
            var fewer = items
            fewer.remove(at: closing % 30)
            show(ui, fewer)
        }
        let queries = ["s", "sa", "saf", "safa", "saf", "sa", "s", ""]
        var step = 0
        let typing = median(15) {
            let query = queries[step % queries.count]
            step += 1
            show(ui, query.isEmpty ? items : FuzzySearch.rank(items, query: query), searching: true, query: query)
        }
        print(String(format: """
            switcher build, 30 windows, deck (median ms):
              first summon (empty switcher)  %7.2f
              summon again, same windows     %7.2f
              summon, order changed          %7.2f
              reload, one window fewer       %7.2f
              search keystrokes              %7.2f
            """, cold, again, reordered, oneFewer, typing))
        show(ui, items)
        XCTAssertEqual(ui.tiles.count, 30)
    }
}

final class TileKeeperTests: XCTestCase {
    private final class Tile {}

    private let look = TileLook(style: .deck, iconSize: 32, titleSize: 16, scale: 2, appearance: "NSAppearanceNameDarkAqua",
                                language: .en, showBadges: true, showSpaceNumbers: true, titleContent: .windowTitle, titleTruncation: .end)

    private func blueprint(_ wid: CGWindowID, title: String = "Doc", minimized: Bool = false, look: TileLook? = nil) -> TileBlueprint {
        let item = SwitcherItem(kind: .window(wid), pid: 7, appName: "App", title: title, icon: NSImage(), isMinimized: minimized,
                                isHidden: false, isFullscreen: false, otherSpaceIndex: nil, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                                bundleID: "com.example.app")
        return TileBlueprint(item, look: look ?? self.look)
    }

    func testAKeptTileComesBackOnlyForTheSameBlueprint() {
        let keeper = TileKeeper<Tile>()
        let tile = Tile()
        keeper.beginBuild()
        keeper.keep(tile, for: blueprint(1))
        // A new title only relabels the tile…
        keeper.beginBuild()
        XCTAssertTrue(keeper.take(blueprint(1, title: "Other")) === tile)
        // …another state, another look or another window needs a new one.
        keeper.beginBuild()
        XCTAssertNil(keeper.take(blueprint(1, minimized: true)))
        var light = look
        light.appearance = "NSAppearanceNameAqua"
        XCTAssertNil(keeper.take(blueprint(1, look: light)))
        var turkish = look
        turkish.language = .tr
        XCTAssertNil(keeper.take(blueprint(1, look: turkish)))
        // A shortcut with a layout of its own never gets tiles made for another one.
        var stage = look
        stage.style = .stage
        XCTAssertNil(keeper.take(blueprint(1, look: stage)))
        XCTAssertNil(keeper.take(blueprint(2)))
        XCTAssertTrue(keeper.take(blueprint(1)) === tile)
    }

    func testATileIsHandedOutOncePerBuild() {
        let keeper = TileKeeper<Tile>()
        let tile = Tile()
        keeper.beginBuild()
        keeper.keep(tile, for: blueprint(1))
        XCTAssertNil(keeper.take(blueprint(1)), "the build that made it already shows it")
        keeper.beginBuild()
        XCTAssertTrue(keeper.take(blueprint(1)) === tile)
        XCTAssertNil(keeper.take(blueprint(1)))
    }

    func testANewTileReplacesTheOneKeptForItsWindow() {
        let keeper = TileKeeper<Tile>()
        let old = Tile()
        let new = Tile()
        keeper.beginBuild()
        keeper.keep(old, for: blueprint(1))
        keeper.keep(new, for: blueprint(1, minimized: true))
        XCTAssertEqual(keeper.count, 1)
        XCTAssertTrue(keeper.holds(new, for: blueprint(1, minimized: true)))
        XCTAssertFalse(keeper.holds(old, for: blueprint(1)))
        XCTAssertFalse(keeper.holds(new, for: blueprint(1)))
    }

    func testADiscardedTileIsNeverHandedOutAgain() {
        let keeper = TileKeeper<Tile>()
        let tile = Tile()
        keeper.beginBuild()
        keeper.keep(tile, for: blueprint(1))
        keeper.discard(tile)
        keeper.beginBuild()
        XCTAssertNil(keeper.take(blueprint(1)))
        XCTAssertEqual(keeper.count, 0)
    }

    func testTrimLetsGoOfTheTilesUsedLongestAgo() {
        let keeper = TileKeeper<Tile>()
        let tiles = (0..<5).map { _ in Tile() }
        for (offset, tile) in tiles.enumerated() {
            keeper.beginBuild()
            keeper.keep(tile, for: blueprint(CGWindowID(offset)))
        }
        // Tile 0 was shown again recently; the last build shows tile 4.
        keeper.beginBuild()
        XCTAssertNotNil(keeper.take(blueprint(0)))
        keeper.beginBuild()
        XCTAssertNotNil(keeper.take(blueprint(4)))
        let released = keeper.trim(to: 2)
        XCTAssertEqual(released.count, 3)
        XCTAssertTrue(released.contains { $0 === tiles[1] } && released.contains { $0 === tiles[2] } && released.contains { $0 === tiles[3] })
        XCTAssertEqual(keeper.count, 2)
        // Never one the current build shows, even past the limit.
        XCTAssertEqual(keeper.trim(to: 0).count, 1)
        XCTAssertTrue(keeper.holds(tiles[4], for: blueprint(4)))
    }
}

/// Builds the switcher offscreen (never ordered in) the way sessions do, once with a switcher that reuses its tiles and
/// once with a new one, and checks both draw the same pixels.
final class TileReuseTests: XCTestCase {
    private var screen: NSScreen!
    private var items = [SwitcherItem]()
    private var savedStyle = SwitcherStyle.deck
    private var savedBadges = true
    private let dark = NSAppearance(named: .darkAqua)!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        Prefs.persists = false
        screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        items = MockRender.items(MockRender.samples, language: .en, firstWID: 31_000, thumbnailWidth: 320).items
        savedStyle = Prefs.shared.style
        savedBadges = Prefs.shared.showBadges
    }

    override func tearDown() {
        Prefs.shared.style = savedStyle
        Prefs.shared.showBadges = savedBadges
    }

    private func show(_ ui: SwitcherUI, _ items: [SwitcherItem], query: String? = nil) {
        ui.prepareOffscreen(items: items, selected: min(1, items.count - 1), searching: query != nil, query: query ?? "",
                            screen: screen, appearance: dark)
    }

    /// The panel's contents as pixels, once AppKit has attached the views' layers (as `--mock` does).
    private func pixels(_ ui: SwitcherUI) throws -> Data {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        let image = try XCTUnwrap(ui.captureOffscreen())
        return try XCTUnwrap(image.dataProvider?.data) as Data
    }

    private func retitled(_ item: SwitcherItem, _ title: String) -> SwitcherItem {
        var copy = SwitcherItem(kind: item.kind, pid: item.pid, appName: item.appName, title: title, icon: item.icon,
                                isMinimized: item.isMinimized, isHidden: item.isHidden, isFullscreen: item.isFullscreen,
                                otherSpaceIndex: item.otherSpaceIndex, frame: item.frame, bundleID: item.bundleID)
        copy.bundlePath = item.bundlePath
        return copy
    }

    func testReusedTilesDrawExactlyLikeNewOnes() throws {
        let rotated = Array(items[3...] + items[..<3])
        var renamed = items
        renamed[0] = retitled(items[0], "A much longer title than before, to be cut short")
        let scenarios: [(String, [SwitcherItem], String?)] = [
            ("order changed", rotated, nil),
            ("two windows fewer", Array(items.dropFirst(2)), nil),
            ("searching", FuzzySearch.rank(items, query: "s"), "s"),
            ("title changed", renamed, nil),
            ("back to the start", items, nil),
        ]
        for style in SwitcherStyle.allCases {
            Prefs.shared.style = style
            let ui = SwitcherUI()
            show(ui, items)
            // The mouse was resting on a card: its buttons must not come back with it.
            ui.tiles[2].showCardButtons(true)
            for (name, shown, query) in scenarios {
                show(ui, shown, query: query)
                let reused = try pixels(ui)
                let fresh = SwitcherUI()
                show(fresh, shown, query: query)
                XCTAssertTrue(reused == (try pixels(fresh)), "\(style), \(name): the reused tiles draw differently")
            }
        }
    }

    func testUnchangedWindowsKeepTheirTiles() {
        Prefs.shared.style = .deck
        let ui = SwitcherUI()
        show(ui, items)
        let first = Dictionary(uniqueKeysWithValues: ui.tiles.map { ($0.item.id, $0) })
        // Another order and one window fewer: the same tiles, renumbered.
        let shown = Array(items[4...] + items[1..<4])
        show(ui, shown)
        XCTAssertEqual(ui.tiles.map(\.item.id), shown.map(\.id))
        for (index, tile) in ui.tiles.enumerated() {
            XCTAssertTrue(first[tile.item.id] === tile, tile.item.id)
            XCTAssertEqual(tile.index, index)
        }
        // A window that was minimized meanwhile gets a new tile; the rest stay.
        var changed = shown
        let original = changed[2]
        changed[2] = SwitcherItem(kind: original.kind, pid: original.pid, appName: original.appName, title: original.title,
                                  icon: original.icon, isMinimized: !original.isMinimized, isHidden: original.isHidden,
                                  isFullscreen: original.isFullscreen, otherSpaceIndex: original.otherSpaceIndex, frame: original.frame,
                                  bundleID: original.bundleID)
        show(ui, changed)
        XCTAssertFalse(first[original.id] === ui.tiles[2])
        XCTAssertTrue(first[changed[3].id] === ui.tiles[3])
        // Another look (status badges off) makes every tile anew.
        Prefs.shared.showBadges = false
        show(ui, changed)
        XCTAssertFalse(ui.tiles.contains { first[$0.item.id] === $0 })
    }

    func testATileIsOnlyReusedInTheLayoutItWasMadeFor() {
        let ui = SwitcherUI()
        // Every tile seen, with the layout it was made for (held, so no new tile can take an old one's identity).
        var made = [(tile: TileView, style: SwitcherStyle)]()
        for style in SwitcherStyle.allCases + [.deck, .deck] {
            Prefs.shared.style = style
            show(ui, items)
            XCTAssertEqual(ui.tiles.count, items.count)
            for tile in ui.tiles {
                if let earlier = made.first(where: { $0.tile === tile }) {
                    XCTAssertEqual(earlier.style, style, "a tile made for \(earlier.style) was reused for \(style)")
                } else {
                    made.append((tile, style))
                }
            }
        }
        // The last two builds were both the deck: the second reused the first's tiles.
        XCTAssertEqual(made.count, (SwitcherStyle.allCases.count + 1) * items.count)
    }

    func testAShortcutWithItsOwnLayoutNeverGetsAnotherLayoutsTiles() {
        Prefs.shared.style = .deck
        let ui = SwitcherUI()
        show(ui, items)
        let deck = ui.tiles
        ui.styleOverride = .appIcons
        show(ui, items)
        XCTAssertEqual(ui.style, .appIcons)
        XCTAssertFalse(ui.tiles.contains { tile in deck.contains { $0 === tile } })
        let icons = ui.tiles
        ui.styleOverride = nil
        show(ui, items)
        XCTAssertEqual(ui.style, .deck)
        XCTAssertFalse(ui.tiles.contains { tile in icons.contains { $0 === tile } })
    }
}

final class TitleFormatTests: XCTestCase {
    private var savedLanguage = AppLanguage.en

    override func setUp() {
        Prefs.persists = false
        savedLanguage = Prefs.shared.language
        Prefs.shared.language = .en
    }

    override func tearDown() {
        Prefs.shared.language = savedLanguage
    }

    private func window(_ app: String, _ title: String, minimized: Bool = false, space: Int? = nil) -> SwitcherItem {
        SwitcherItem(kind: .window(1), pid: 1, appName: app, title: title, icon: NSImage(), isMinimized: minimized, isHidden: false,
                     isFullscreen: false, otherSpaceIndex: space, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), bundleID: nil)
    }

    private func app(_ name: String) -> SwitcherItem {
        SwitcherItem(kind: .app(2), pid: 2, appName: name, title: "", icon: NSImage(), isMinimized: false, isHidden: false,
                     isFullscreen: false, otherSpaceIndex: nil, frame: .zero, bundleID: nil)
    }

    func testEachSettingPicksTheLabel() {
        let inbox = window("Mail", "Inbox")
        XCTAssertEqual(TitleFormat.title(of: inbox, showing: .windowTitle).text, "Inbox")
        XCTAssertEqual(TitleFormat.title(of: inbox, showing: .appName).text, "Mail")
        XCTAssertEqual(TitleFormat.title(of: inbox, showing: .appAndWindowTitle).text, "Mail — Inbox")
    }

    func testWithoutATitleTheAppNameIsTheLabel() {
        var messages = app("Messages")
        messages.appNameMatches = [0, 1]
        var untitled = window("Finder", "")
        untitled.appNameMatches = [2]
        for content in TitleContent.allCases {
            XCTAssertEqual(TitleFormat.title(of: messages, showing: content), TitleFormat.Label(text: "Messages", matches: [0, 1]))
            XCTAssertEqual(TitleFormat.title(of: untitled, showing: content), TitleFormat.Label(text: "Finder", matches: [2]))
        }
    }

    func testSearchMatchesLandOnTheSameLettersInEveryLabel() {
        let ranked = FuzzySearch.rank([window("Safari", "Görüntü ayarları")], query: "saf gor")
        let item = try! XCTUnwrap(ranked.first)
        for content in TitleContent.allCases {
            let label = TitleFormat.title(of: item, showing: content)
            let letters = Array(label.text)
            let matched = String(label.matches.map { letters[$0] })
            switch content {
            case .windowTitle: XCTAssertEqual(matched, "Gör")
            case .appName: XCTAssertEqual(matched, "Saf")
            case .appAndWindowTitle: XCTAssertEqual(matched, "SafGör")
            }
        }
    }

    func testTheSecondLineSaysWhatTheLabelLeavesOut() {
        let inbox = window("Mail", "Inbox")
        XCTAssertEqual(TitleFormat.listDetail(of: inbox, showing: .windowTitle)?.text, "Mail")
        XCTAssertEqual(TitleFormat.listDetail(of: inbox, showing: .appName)?.text, "Inbox")
        XCTAssertNil(TitleFormat.listDetail(of: inbox, showing: .appAndWindowTitle))
        XCTAssertEqual(TitleFormat.listDetail(of: app("Messages"), showing: .appAndWindowTitle)?.text, "No open windows")
        XCTAssertNil(TitleFormat.listDetail(of: window("Finder", ""), showing: .windowTitle))
        // The stage names the app under a window title, as it always has.
        XCTAssertEqual(TitleFormat.stageDetail(of: inbox, showing: .windowTitle)?.text, "Mail")
        XCTAssertEqual(TitleFormat.stageDetail(of: app("Messages"), showing: .windowTitle)?.text, "Messages")
        XCTAssertEqual(TitleFormat.stageDetail(of: inbox, showing: .appName)?.text, "Inbox")
        XCTAssertNil(TitleFormat.stageDetail(of: inbox, showing: .appAndWindowTitle))
    }

    func testVoiceOverReadsTheLabelFirst() {
        let inbox = window("Mail", "Inbox", minimized: true, space: 2)
        XCTAssertEqual(TitleFormat.spokenDescription(of: inbox, showing: .windowTitle, dockBadge: "3"),
                       "Inbox, Mail, Minimized, On desktop 2, Dock badge: 3")
        XCTAssertEqual(TitleFormat.spokenDescription(of: inbox, showing: .appName), "Mail, Inbox, Minimized, On desktop 2")
        XCTAssertEqual(TitleFormat.spokenDescription(of: inbox, showing: .appAndWindowTitle), "Mail, Inbox, Minimized, On desktop 2")
        XCTAssertEqual(TitleFormat.spokenDescription(of: app("Messages"), showing: .windowTitle), "Messages, No open windows")
        XCTAssertEqual(TitleFormat.spokenDescription(of: window("Finder", ""), showing: .windowTitle), "Finder")
    }

    func testTruncationSettingsMapToLineBreakModes() {
        XCTAssertEqual(TitleTruncation.end.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(TitleTruncation.middle.lineBreakMode, .byTruncatingMiddle)
        XCTAssertEqual(TitleTruncation.start.lineBreakMode, .byTruncatingHead)
        let label = TileView.highlighted("A long title", matches: [], font: .systemFont(ofSize: 13), color: .labelColor, lineBreakMode: .byTruncatingMiddle)
        let paragraph = label.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(paragraph?.lineBreakMode, .byTruncatingMiddle)
    }
}

final class FileDropTests: XCTestCase {
    private let files = [URL(fileURLWithPath: "/tmp/notes.txt"), URL(fileURLWithPath: "/tmp/photo.png")]
    private let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")

    private func item(_ kind: SwitcherItem.Kind, pid: pid_t) -> SwitcherItem {
        SwitcherItem(kind: kind, pid: pid, appName: "TextEdit", title: kind == .app(pid) ? "" : "Notes", icon: NSImage(), isMinimized: false,
                     isHidden: false, isFullscreen: false, otherSpaceIndex: nil, frame: CGRect(x: 0, y: 0, width: 800, height: 600), bundleID: nil)
    }

    private func route(_ item: SwitcherItem, files: [URL]? = nil) -> FileDrop.Route? {
        FileDrop.route(for: item, files: files ?? self.files, ownPID: 10, appURL: { $0 == 500 ? self.textEdit : nil })
    }

    func testFilesOnAWindowOpenWithItsAppAndBringTheWindowForward() {
        XCTAssertEqual(route(item(.window(42), pid: 500)), FileDrop.Route(app: textEdit, window: 42))
    }

    func testAnAppWithoutWindowsTakesFilesToo() {
        XCTAssertEqual(route(item(.app(500), pid: 500)), FileDrop.Route(app: textEdit, window: nil))
    }

    func testRifflesOwnWindowsRefuseDrops() {
        XCTAssertNil(FileDrop.route(for: item(.window(7), pid: 10), files: files, ownPID: 10, appURL: { _ in self.textEdit }))
    }

    func testNoFilesOrNoAppMeansNoDrop() {
        XCTAssertNil(route(item(.window(42), pid: 500), files: []))
        XCTAssertNil(route(item(.window(43), pid: 501)), "the app quit, or has no bundle to open files with")
    }

    func testTheCardShowsWhatTheDragAllows() {
        XCTAssertEqual(FileDrop.operation(allowed: .every), .generic)
        // Holding ⌥ leaves Finder only copies.
        XCTAssertEqual(FileDrop.operation(allowed: [.copy, .link]), .copy)
        XCTAssertEqual(FileDrop.operation(allowed: .link), .link)
        XCTAssertEqual(FileDrop.operation(allowed: .move), [])
    }

    func testOnlyFilesAreTakenFromTheDrag() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("RiffleTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([files[0] as NSURL, URL(string: "https://example.com/page")! as NSURL])
        XCTAssertEqual(FileDrop.files(on: pasteboard), [files[0]])
    }

    func testATileTakesDroppedFilesUnlessItIsRiffles() throws {
        _ = NSApplication.shared
        // A running app that takes files: Finder always runs. Nothing is opened: the tile only hands the files on.
        let finder = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let layout = TileLayout.compute(aspects: [1.6], style: .deck, size: .medium, available: CGSize(width: 900, height: 700))
        let recorder = DropRecorder()
        let tile = TileView(index: 0, item: item(.window(42), pid: finder.processIdentifier), frame: layout.frames[0], layout: layout)
        tile.delegate = recorder
        XCTAssertTrue(tile.registeredDraggedTypes.contains(.fileURL))
        let drag = FakeDrag(files: files, allowed: [.copy])
        defer { drag.draggingPasteboard.releaseGlobally() }
        XCTAssertEqual(tile.draggingEntered(drag), .copy)
        XCTAssertEqual(recorder.draggedOver, 1)
        XCTAssertTrue(tile.performDragOperation(drag))
        XCTAssertEqual(recorder.opened, [files])

        let own = TileView(index: 0, item: item(.window(43), pid: ProcessInfo.processInfo.processIdentifier), frame: layout.frames[0], layout: layout)
        own.delegate = recorder
        XCTAssertEqual(own.draggingEntered(drag), [])
        XCTAssertFalse(own.performDragOperation(drag))
        XCTAssertEqual(recorder.draggedOver, 1)
        XCTAssertEqual(recorder.opened.count, 1)
    }
}

final class PanelAnimationTests: XCTestCase {
    func testReduceMotionStopsTheMovementButKeepsTheFades() {
        let normal = SwitcherUI.animations(setting: true, reduceMotion: false)
        XCTAssertTrue(normal.motion)
        XCTAssertTrue(normal.fades)
        let reduced = SwitcherUI.animations(setting: true, reduceMotion: true)
        XCTAssertFalse(reduced.motion)
        XCTAssertTrue(reduced.fades)
    }

    func testTheSettingOffMakesEverythingInstant() {
        for reduceMotion in [false, true] {
            let off = SwitcherUI.animations(setting: false, reduceMotion: reduceMotion)
            XCTAssertFalse(off.motion)
            XCTAssertFalse(off.fades)
        }
        Prefs.persists = false
        let saved = Prefs.shared.panelAnimations
        defer { Prefs.shared.panelAnimations = saved }
        Prefs.shared.panelAnimations = false
        XCTAssertFalse(SwitcherUI.animatesMotion)
        XCTAssertFalse(SwitcherUI.animatesFades)
        Prefs.shared.panelAnimations = true
        XCTAssertTrue(SwitcherUI.animatesFades)
        XCTAssertEqual(SwitcherUI.animatesMotion, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func testTheStageSlidesOrUnderReduceMotionDissolves() {
        XCTAssertEqual(HeroView.Transition(moves: true, fades: true), .slide)
        XCTAssertEqual(HeroView.Transition(moves: false, fades: true), .fade)
        XCTAssertEqual(HeroView.Transition(moves: false, fades: false), .instant)
    }
}

final class PointerFollowTests: XCTestCase {
    /// A 1512×982 laptop display, with a 2560×1440 one on its left, tops aligned (top-left origin, like AX).
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let external = CGRect(x: -2560, y: 0, width: 2560, height: 1440)

    func testThePointerGoesToTheMiddleOfTheWindow() {
        let window = CGRect(x: 100, y: 80, width: 900, height: 600)
        XCTAssertEqual(PointerFollow.target(for: window, displays: [laptop, external]), CGPoint(x: 550, y: 380))
        // On the other display too.
        let left = CGRect(x: -2000, y: 200, width: 1000, height: 800)
        XCTAssertEqual(PointerFollow.target(for: left, displays: [laptop, external]), CGPoint(x: -1500, y: 600))
    }

    func testAWindowHangingOffTheScreenGetsThePointerInItsVisiblePart() {
        // Pushed off the laptop's right edge: its middle is off screen, the part on screen is 1512-1300 wide.
        let window = CGRect(x: 1300, y: 100, width: 800, height: 400)
        XCTAssertEqual(PointerFollow.target(for: window, displays: [laptop]), CGPoint(x: 1406, y: 300))
    }

    func testNoPointerMoveForAWindowNoDisplayShows() {
        XCTAssertNil(PointerFollow.target(for: CGRect(x: 5000, y: 5000, width: 800, height: 600), displays: [laptop, external]))
        XCTAssertNil(PointerFollow.target(for: CGRect(x: 100, y: 100, width: 0, height: 0), displays: [laptop]))
    }
}

private final class DropRecorder: TileViewDelegate {
    var draggedOver = 0
    var opened = [[URL]]()
    func tileHovered(_ tile: TileView, at point: NSPoint) {}
    func tileClicked(_ tile: TileView) {}
    func tile(_ tile: TileView, perform action: SwitcherAction) {}
    func tileDraggedOver(_ tile: TileView) { draggedOver += 1 }
    func tile(_ tile: TileView, open files: [URL]) { opened.append(files) }
}

/// A drag of `files` that allows `allowed`, on a pasteboard of its own (never the clipboard).
private final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("RiffleTests-\(UUID().uuidString)"))
    let draggingSourceOperationMask: NSDragOperation

    init(files: [URL], allowed: NSDragOperation) {
        draggingSourceOperationMask = allowed
        super.init()
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(files.map { $0 as NSURL })
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
