import AppKit
import XCTest
@testable import Riffle

/// The layout engine in Arabic and Hebrew: every arrangement mirrored, the arrow keys following the mirrored order, and
/// left to right exactly as before.
final class RightToLeftLayoutTests: XCTestCase {
    private let screen = CGSize(width: 1400, height: 800)
    /// Window shapes from wide to a portrait page.
    private let shapes: [CGFloat] = [1.6, 1.45, 1.3, 1.7, 1.5, 1.4, 0.78]

    private func layouts(_ style: SwitcherStyle, count: Int, size: SwitcherSize = .medium,
                         available: CGSize? = nil) -> (ltr: TileLayout, rtl: TileLayout) {
        let aspects = (0..<count).map { shapes[$0 % shapes.count] }
        let room = available ?? screen
        return (TileLayout.compute(aspects: aspects, style: style, size: size, available: room),
                TileLayout.compute(aspects: aspects, style: style, size: size, available: room, rightToLeft: true))
    }

    func testMirroredFramesAreReflectionsOfTheLeftToRightOnes() {
        for style in SwitcherStyle.allCases {
            for size in SwitcherSize.allCases {
                for count in [0, 1, 2, 4, 5, 7, 16, 40] {
                    let (ltr, rtl) = layouts(style, count: count, size: size)
                    let name = "\(style), \(size), \(count) windows"
                    XCTAssertFalse(ltr.isRightToLeft, name)
                    XCTAssertTrue(rtl.isRightToLeft, name)
                    // Same sizes, same rows, same items in each: only the places change.
                    XCTAssertEqual(rtl.rows, ltr.rows, name)
                    XCTAssertEqual(rtl.contentSize, ltr.contentSize, name)
                    XCTAssertEqual(rtl.viewportHeight, ltr.viewportHeight, name)
                    XCTAssertEqual(rtl.thumbnailHeight, ltr.thumbnailHeight, name)
                    XCTAssertEqual(rtl.iconSize, ltr.iconSize, name)
                    XCTAssertEqual(rtl.titleSize, ltr.titleSize, name)
                    XCTAssertEqual(rtl.frames.count, ltr.frames.count, name)
                    for (mirrored, original) in zip(rtl.frames, ltr.frames) {
                        XCTAssertEqual(mirrored, CGRect(x: ltr.contentSize.width - original.maxX, y: original.minY,
                                                        width: original.width, height: original.height), name)
                    }
                    // Mirroring back gives the left-to-right layout.
                    XCTAssertEqual(rtl.mirrored().frames, ltr.frames, name)
                    XCTAssertFalse(rtl.mirrored().isRightToLeft, name)
                }
            }
        }
    }

    func testTheFirstTileIsOnTheRightAndRowsStillFillTopToBottom() {
        let (_, deck) = layouts(.deck, count: 16)
        XCTAssertGreaterThan(deck.rows.count, 1)
        for row in deck.rows {
            let lefts = row.map { deck.frames[$0].minX }
            XCTAssertEqual(lefts, lefts.sorted(by: >), "each row runs right to left")
        }
        for (upper, lower) in zip(deck.rows, deck.rows.dropFirst()) {
            XCTAssertLessThan(deck.frames[upper.lowerBound].maxY, deck.frames[lower.lowerBound].minY)
        }
        let (_, strip) = layouts(.stage, count: 5)
        XCTAssertEqual(strip.frames[0].maxX, strip.contentSize.width, "the filmstrip starts at its right end")
        XCTAssertEqual(strip.frames.map(\.minX), strip.frames.map(\.minX).sorted(by: >))
    }

    /// Seven cards fall into rows of three and four.
    func testArrowKeysFollowTheMirroredOrderAcrossRows() {
        let (ltr, rtl) = layouts(.deck, count: 7)
        XCTAssertEqual(rtl.rows, [0..<3, 3..<7])
        // ← goes on towards the end of the list, → back towards its start.
        XCTAssertEqual(rtl.target(from: 1, .left), 2)
        XCTAssertEqual(rtl.target(from: 1, .right), 0)
        // Off the left end of a row (its last card) ← goes on to the next row's first card, at that row's right end…
        XCTAssertEqual(rtl.target(from: 2, .left), 3)
        XCTAssertEqual(rtl.frames[3].maxX, rtl.frames[3..<7].map(\.maxX).max())
        // …and → from there comes back to the left end of the row above.
        XCTAssertEqual(rtl.target(from: 3, .right), 2)
        XCTAssertEqual(rtl.frames[2].minX, rtl.frames[0..<3].map(\.minX).min())
        // Around the ends of the list.
        XCTAssertEqual(rtl.target(from: 0, .right), 6)
        XCTAssertEqual(rtl.target(from: 6, .left), 0)
        // Every move is the mirror image of the left-to-right one: ← where → went, → where ← went, ↑ and ↓ alike.
        for index in 0..<7 {
            XCTAssertEqual(rtl.target(from: index, .left), ltr.target(from: index, .right), "card \(index)")
            XCTAssertEqual(rtl.target(from: index, .right), ltr.target(from: index, .left), "card \(index)")
            XCTAssertEqual(rtl.target(from: index, .up), ltr.target(from: index, .up), "card \(index)")
            XCTAssertEqual(rtl.target(from: index, .down), ltr.target(from: index, .down), "card \(index)")
        }
    }

    func testWithinARowTheArrowsMoveTheWayTheyPoint() {
        let cases = [layouts(.deck, count: 16).rtl, layouts(.stage, count: 9).rtl,
                     layouts(.appIcons, count: 11, available: CGSize(width: 520, height: 800)).rtl]
        for layout in cases {
            for row in layout.rows {
                for index in row where index != row.upperBound - 1 {
                    let left = layout.target(from: index, .left)
                    XCTAssertEqual(left, index + 1)
                    XCTAssertLessThanOrEqual(layout.frames[left].maxX, layout.frames[index].minX, "\(layout.style): ← lands on the card to the left")
                    XCTAssertEqual(layout.target(from: left, .right), index, "\(layout.style): → comes back")
                }
            }
        }
    }

    func testOneColumnListsAndTheStageKeepUpAndDown() {
        for style in [SwitcherStyle.titles, .list, .stage] {
            let (ltr, rtl) = layouts(style, count: 6)
            for index in 0..<6 {
                XCTAssertEqual(rtl.target(from: index, .up), ltr.target(from: index, .up), "\(style)")
                XCTAssertEqual(rtl.target(from: index, .down), ltr.target(from: index, .down), "\(style)")
                // ← is the next row, → the one before.
                XCTAssertEqual(rtl.target(from: index, .left), (index + 1) % 6, "\(style)")
                XCTAssertEqual(rtl.target(from: index, .right), (index + 5) % 6, "\(style)")
            }
        }
    }

    /// Taken from the layout as it was before right to left existed: left to right must not move by a point.
    func testLeftToRightIsUnchanged() {
        let deck = TileLayout.compute(aspects: shapes, style: .deck, size: .medium, available: screen)
        XCTAssertFalse(deck.isRightToLeft)
        XCTAssertEqual(deck.rows, [0..<3, 3..<7])
        XCTAssertEqual(deck.contentSize, CGSize(width: 1220, height: 530))
        XCTAssertEqual(deck.frames, [
            CGRect(x: 126, y: 0, width: 350, height: 262), CGRect(x: 482, y: 0, width: 319, height: 262),
            CGRect(x: 807, y: 0, width: 288, height: 262), CGRect(x: 0, y: 268, width: 370, height: 262),
            CGRect(x: 376, y: 268, width: 329, height: 262), CGRect(x: 711, y: 268, width: 308, height: 262),
            CGRect(x: 1025, y: 268, width: 195, height: 262),
        ])
        // ← back, → on, both wrapping at the ends; ↑ and ↓ to the nearest card of the other row.
        XCTAssertEqual(deck.frames.indices.map { deck.target(from: $0, .left) }, [6, 0, 1, 2, 3, 4, 5])
        XCTAssertEqual(deck.frames.indices.map { deck.target(from: $0, .right) }, [1, 2, 3, 4, 5, 6, 0])
        XCTAssertEqual(deck.frames.indices.map { deck.target(from: $0, .up) }, [3, 4, 5, 0, 1, 2, 2])
        XCTAssertEqual(deck.frames.indices.map { deck.target(from: $0, .down) }, [3, 4, 5, 0, 1, 2, 2])

        let strip = TileLayout.compute(aspects: Array(shapes.prefix(5)), style: .stage, size: .medium, available: CGSize(width: 900, height: 800))
        XCTAssertEqual(strip.frames.map(\.minX), [0, 142, 284, 426, 568])
        XCTAssertEqual(strip.contentSize, CGSize(width: 696, height: 80))

        let icons = TileLayout.compute(aspects: Array(repeating: 1.6, count: 7), style: .appIcons, size: .medium,
                                       available: CGSize(width: 520, height: 800))
        XCTAssertEqual(icons.rows, [0..<3, 3..<6, 6..<7])
        XCTAssertEqual(icons.frames.map(\.origin), [CGPoint(x: 0, y: 0), CGPoint(x: 134, y: 0), CGPoint(x: 268, y: 0), CGPoint(x: 0, y: 148),
                                                    CGPoint(x: 134, y: 148), CGPoint(x: 268, y: 148), CGPoint(x: 134, y: 296)])
        XCTAssertEqual(icons.frames.indices.map { icons.target(from: $0, .up) }, [6, 6, 6, 0, 1, 2, 4])
        XCTAssertEqual(icons.frames.indices.map { icons.target(from: $0, .down) }, [3, 4, 5, 6, 6, 6, 1])

        // Asking for left to right is the same as not asking.
        for style in SwitcherStyle.allCases {
            let plain = TileLayout.compute(aspects: shapes, style: style, size: .medium, available: screen)
            let asked = TileLayout.compute(aspects: shapes, style: style, size: .medium, available: screen, rightToLeft: false)
            XCTAssertEqual(asked.frames, plain.frames, "\(style)")
            XCTAssertFalse(asked.isRightToLeft)
        }
    }
}

/// The panel itself, built offscreen (never ordered in) in English and in Arabic.
final class RightToLeftPanelTests: XCTestCase {
    private var screen: NSScreen!
    private var items = [SwitcherItem]()
    private var savedLanguage = AppLanguage.en
    private var savedStyle = SwitcherStyle.deck
    private let dark = NSAppearance(named: .darkAqua)!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        Prefs.persists = false
        screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        items = MockRender.items(MockRender.rightToLeftSamples, language: .en, firstWID: 33_000, thumbnailWidth: 320).items
        savedLanguage = Prefs.shared.language
        savedStyle = Prefs.shared.style
    }

    override func tearDown() {
        Prefs.shared.language = savedLanguage
        Prefs.shared.style = savedStyle
    }

    private func show(_ ui: SwitcherUI, _ items: [SwitcherItem], query: String? = nil) {
        let shown = query.map { FuzzySearch.rank(items, query: $0) } ?? items
        ui.prepareOffscreen(items: shown, selected: min(1, shown.count - 1), searching: query != nil, query: query ?? "",
                            screen: screen, appearance: dark)
    }

    private func panel(_ style: SwitcherStyle, _ language: AppLanguage, query: String? = nil) -> SwitcherUI {
        Prefs.shared.style = style
        Prefs.shared.language = language
        let ui = SwitcherUI()
        show(ui, items, query: query)
        return ui
    }

    func testEveryArrangementIsTheMirrorImageOfTheLeftToRightOne() {
        for style in SwitcherStyle.allCases {
            for query in [nil, "s"] {
                let ltr = panel(style, .en, query: query)
                let rtl = panel(style, .ar, query: query)
                let name = "\(style)\(query == nil ? "" : ", searching")"
                XCTAssertFalse(ltr.isRightToLeft)
                XCTAssertTrue(rtl.isRightToLeft)
                XCTAssertTrue(rtl.layout?.isRightToLeft == true, name)
                let (size, frames) = ltr.offscreenTileFrames()
                let mirror = rtl.offscreenTileFrames()
                XCTAssertEqual(mirror.size, size, name)
                XCTAssertEqual(mirror.frames.count, frames.count, name)
                // Tiles where they sit in the panel, scrolling included (the filmstrip scrolls to its other end).
                for (mirrored, original) in zip(mirror.frames, frames) {
                    XCTAssertEqual(mirrored, original.mirrored(within: size.width), name)
                }
                if style == .list || style == .stage {
                    XCTAssertEqual(rtl.hero.frame, ltr.hero.frame.mirrored(within: size.width), name)
                }
                XCTAssertEqual(rtl.searchBar.frame, ltr.searchBar.frame, name)
            }
        }
        // The list on the right of its stage.
        let list = panel(.list, .ar)
        XCTAssertGreaterThan(list.offscreenTileFrames().frames[0].minX, list.hero.frame.maxX)
    }

    /// The panel's contents as pixels, once AppKit has attached the views' layers (as `--mock` does).
    private func pixels(_ ui: SwitcherUI) throws -> Data {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        return try XCTUnwrap(XCTUnwrap(ui.captureOffscreen()).dataProvider?.data) as Data
    }

    /// The panel is made once and kept: after a session in Arabic, one in English must look as if there never was one.
    func testLeftToRightAfterRightToLeftDrawsLikeAFreshPanel() throws {
        for style in SwitcherStyle.allCases {
            for query in [nil, "s"] {
                let ui = panel(style, .ar, query: query)
                Prefs.shared.language = .en
                show(ui, items, query: query)
                XCTAssertFalse(ui.isRightToLeft)
                let fresh = panel(style, .en, query: query)
                XCTAssertTrue(try pixels(ui) == (try pixels(fresh)), "\(style)\(query == nil ? "" : ", searching")")
            }
        }
    }

    /// Kept tiles are moved and relabelled by later builds: right to left too, they must draw like new ones.
    func testReusedTilesDrawExactlyLikeNewOnesRightToLeft() throws {
        Prefs.shared.language = .ar
        let scenarios: [(String, [SwitcherItem], String?)] = [
            ("order changed", Array(items[3...] + items[..<3]), nil),
            ("two windows fewer", Array(items.dropFirst(2)), nil),
            ("searching", items, "s"),
            ("back to the start", items, nil),
        ]
        for style in SwitcherStyle.allCases {
            Prefs.shared.style = style
            let ui = SwitcherUI()
            show(ui, items)
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

    /// What a tile shows is mirrored inside it, within a point for what is centered on the picture; the picture itself
    /// is never flipped.
    func testATilesContentsAreMirroredButNotItsPicture() throws {
        for style in SwitcherStyle.allCases {
            for item in items {
                let aspects = [item.isWindowless ? 1.6 : item.aspectRatio]
                let room = CGSize(width: 1400, height: 800)
                let ltrLayout = TileLayout.compute(aspects: aspects, style: style, size: .medium, available: room)
                let rtlLayout = TileLayout.compute(aspects: aspects, style: style, size: .medium, available: room, rightToLeft: true)
                let frame = ltrLayout.frames[0]
                XCTAssertEqual(rtlLayout.frames[0], frame, "one tile fills its row both ways")
                let tiles = [ltrLayout, rtlLayout].map { layout -> TileView in
                    let tile = TileView(index: 0, item: item, frame: frame, layout: layout)
                    if let wid = item.wid { tile.setThumbnail(ThumbnailService.shared.image(for: wid)) }
                    tile.setDockBadge("4")
                    tile.showCardButtons(true)
                    return tile
                }
                let (ltr, rtl) = (tiles[0], tiles[1])
                let name = "\(style), \(item.appName)"
                func close(_ mirrored: CGRect, _ original: CGRect) -> Bool {
                    let expected = original.mirrored(within: frame.width)
                    return abs(mirrored.minX - expected.minX) <= 1 && mirrored.minY == expected.minY && mirrored.size == expected.size
                }
                XCTAssertEqual(rtl.subviews.count, ltr.subviews.count, name)
                for (mirrored, original) in zip(rtl.subviews, ltr.subviews) where !original.isHidden {
                    XCTAssertTrue(close(mirrored.frame, original.frame), "\(name): \(type(of: original)) at \(mirrored.frame), expected \(original.frame.mirrored(within: frame.width))")
                }
                let layers = (ltr.layer?.sublayers ?? []).filter { !$0.isHidden && $0.frame.width > 0 }
                let mirroredLayers = (rtl.layer?.sublayers ?? []).filter { !$0.isHidden && $0.frame.width > 0 }
                XCTAssertEqual(mirroredLayers.count, layers.count, name)
                for (mirrored, original) in zip(mirroredLayers, layers) {
                    XCTAssertTrue(close(mirrored.frame, original.frame), "\(name): layer at \(mirrored.frame), expected \(original.frame.mirrored(within: frame.width))")
                    XCTAssertGreaterThan(mirrored.transform.m11, 0, "\(name): nothing is drawn flipped")
                    XCTAssertGreaterThan(mirrored.affineTransform().a, 0, "\(name): nothing is drawn flipped")
                }
                // The window's picture is the capture itself, shown the right way round.
                if let wid = item.wid, style == .deck || style == .stage, let capture = ThumbnailService.shared.image(for: wid) {
                    let picture = try XCTUnwrap(mirroredLayers.first { $0.contents as AnyObject? === capture }, name)
                    XCTAssertEqual(picture.contentsRect, CGRect(x: 0, y: 0, width: 1, height: 1), name)
                    XCTAssertTrue(CATransform3DIsIdentity(picture.transform), name)
                }
                // The window buttons: the first (quit, or close for Finder) nearest the thumbnail's right corner.
                if let tray = rtl.subviews.compactMap({ $0 as? CardTray }).first, tray.subviews.count > 1 {
                    XCTAssertGreaterThan(tray.subviews[0].frame.minX, tray.subviews[1].frame.minX, name)
                }
            }
        }
    }

    func testBadgesAndChipsPutTheirSymbolFirstInTheReadingDirection() throws {
        for rightToLeft in [false, true] {
            let badge = BadgeView(symbol: "square.on.square", text: "2", tooltip: "On desktop 2", rightToLeft: rightToLeft)
            let chip = Chip(symbol: "square.on.square", text: "Desktop 2", rightToLeft: rightToLeft)
            chip.frame.size = chip.fittingSize
            for view in [badge, chip] as [NSView] {
                view.layoutSubtreeIfNeeded()
                let stack = try XCTUnwrap(view.subviews.first as? NSStackView)
                // The stack fills its capsule whichever way it reads.
                XCTAssertEqual(stack.frame.minX, 0, "\(type(of: view))")
                XCTAssertEqual(stack.frame.width, view.bounds.width, "\(type(of: view))")
                let symbol = try XCTUnwrap(stack.arrangedSubviews.first { $0 is NSImageView }).frame
                let text = try XCTUnwrap(stack.arrangedSubviews.first { $0 is NSTextField }).frame
                if rightToLeft {
                    XCTAssertGreaterThanOrEqual(symbol.minX, text.maxX, "\(type(of: view)): the symbol on the right")
                } else {
                    XCTAssertLessThanOrEqual(symbol.maxX, text.minX, "\(type(of: view)): the symbol on the left")
                }
            }
        }
    }

    func testTheSearchBarReadsRightToLeft() {
        let bar = SearchBarView(frame: NSRect(x: 0, y: 0, width: 600, height: 46))
        bar.countLabel.stringValue = "3 of 9 windows"
        bar.layout()
        let frames = bar.subviews.map(\.frame)
        let alignments = (field: bar.field.alignment, count: bar.countLabel.alignment)
        XCTAssertEqual(alignments.count, .right)
        bar.isRightToLeft = true
        bar.layout()
        // The magnifying glass on the right, the count on the left, the query aligned to the glass.
        for (mirrored, original) in zip(bar.subviews.map(\.frame), frames) {
            XCTAssertEqual(mirrored, original.mirrored(within: 600))
        }
        XCTAssertLessThan(bar.countLabel.frame.maxX, bar.field.frame.minX)
        XCTAssertEqual(bar.field.alignment, .right)
        XCTAssertEqual(bar.countLabel.alignment, .left)
        // And back, exactly as it was made, for a later session in English.
        bar.isRightToLeft = false
        bar.layout()
        XCTAssertEqual(bar.subviews.map(\.frame), frames)
        XCTAssertEqual(bar.field.alignment, alignments.field)
        XCTAssertEqual(bar.countLabel.alignment, alignments.count)
    }

    func testTheStageSlidesTheNextWindowInFromTheWayTheListRuns() {
        XCTAssertEqual(HeroView.slideSubtype(direction: 1, rightToLeft: false), .fromRight)
        XCTAssertEqual(HeroView.slideSubtype(direction: -1, rightToLeft: false), .fromLeft)
        XCTAssertEqual(HeroView.slideSubtype(direction: 1, rightToLeft: true), .fromLeft)
        XCTAssertEqual(HeroView.slideSubtype(direction: -1, rightToLeft: true), .fromRight)
    }
}
