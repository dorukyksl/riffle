import Carbon
import AppKit
import XCTest
@testable import Riffle

final class FuzzySearchTests: XCTestCase {
    private func item(_ app: String, _ title: String, wid: CGWindowID) -> SwitcherItem {
        SwitcherItem(kind: .window(wid), pid: 1, appName: app, title: title, icon: NSImage(), isMinimized: false, isHidden: false,
                     isFullscreen: false, otherSpaceIndex: nil, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), bundleID: nil)
    }

    func testTurkishFolding() {
        XCTAssertEqual(String(FuzzySearch.fold("İSTANBUL Görüntü Şeker Ilık")), "istanbul goruntu seker ilik")
    }

    func testDiacriticInsensitiveMatch() {
        let items = [item("Notlar", "Görüntü ayarları", wid: 1), item("Safari", "GitHub", wid: 2)]
        let result = FuzzySearch.rank(items, query: "goruntu")
        XCTAssertEqual(result.map(\.wid), [1])
        XCTAssertEqual(result.first?.titleMatches, Array(0..<7))
    }

    func testAppNameBeatsScatteredTitleMatch() {
        let items = [item("Xcode", "Some Advanced Feature Ideas", wid: 1), item("Safari", "Start Page", wid: 2)]
        XCTAssertEqual(FuzzySearch.rank(items, query: "saf").first?.wid, 2)
    }

    func testEveryTokenMustMatch() {
        let items = [item("Google Chrome", "GitHub — riffle/releases", wid: 1), item("Google Chrome", "YouTube", wid: 2)]
        XCTAssertEqual(FuzzySearch.rank(items, query: "chrome git").map(\.wid), [1])
        XCTAssertTrue(FuzzySearch.rank(items, query: "chrome zzz").isEmpty)
    }

    func testEmptyQueryKeepsOrder() {
        let items = [item("A", "1", wid: 1), item("B", "2", wid: 2)]
        XCTAssertEqual(FuzzySearch.rank(items, query: "  ").map(\.wid), [1, 2])
    }

    func testWordStartBeatsMidWord() {
        let items = [item("Mesajlar", "", wid: 1), item("Terminal", "robin — swift build", wid: 2)]
        XCTAssertEqual(FuzzySearch.rank(items, query: "s").first?.wid, 2)
    }

    func testWordStartsPreferred() {
        let items = [item("Terminal", "robin — zsh", wid: 1), item("Mail", "Inbox — robinsmith", wid: 2)]
        // "rz" = "robin — zsh": two word starts.
        XCTAssertEqual(FuzzySearch.rank(items, query: "rz").first?.wid, 1)
    }
}

final class TileLayoutTests: XCTestCase {
    func testWrapsIntoRowsThatFit() {
        let rows = TileLayout.wrap([100, 100, 100, 100], maxWidth: 320)
        XCTAssertEqual(rows, [0..<3, 3..<4])
    }

    func testOldGridSettingBecomesTheDeck() throws {
        let decoded = try JSONDecoder().decode([SwitcherStyle].self, from: Data(#"["thumbnails","stage","nonsense"]"#.utf8))
        XCTAssertEqual(decoded, [.deck, .stage, .deck])
    }

    func testDeckShrinksToFitHeight() {
        let available = CGSize(width: 1300, height: 700)
        let few = TileLayout.compute(aspects: Array(repeating: 1.6, count: 4), style: .deck, size: .medium, available: available)
        let many = TileLayout.compute(aspects: Array(repeating: 1.6, count: 40), style: .deck, size: .medium, available: available)
        XCTAssertLessThan(many.thumbnailHeight, few.thumbnailHeight)
        XCTAssertEqual(many.frames.count, 40)
        for frame in many.frames { XCTAssertLessThanOrEqual(frame.maxX, 1300.5) }
        XCTAssertLessThanOrEqual(many.viewportHeight, 700.5)
    }

    func testDeckCellsAreLarge() {
        // A 14" MacBook screen: 16:10 thumbnails at least 170 pt tall, four on one row.
        let layout = TileLayout.compute(aspects: Array(repeating: 1.6, count: 4), style: .deck, size: .medium,
                                        available: CGSize(width: 1330, height: 700))
        XCTAssertGreaterThanOrEqual(layout.thumbnailHeight, 170)
        XCTAssertEqual(layout.rows.count, 1)
        XCTAssertEqual(Set(layout.frames.map(\.height)).count, 1)
    }

    func testUpToFourWindowsSitSideBySide() {
        // Wide windows that would wrap at full size shrink to stay on one row.
        let layout = TileLayout.compute(aspects: [2.0, 2.0, 1.8, 2.2], style: .deck, size: .large, available: CGSize(width: 1300, height: 760))
        XCTAssertEqual(layout.rows, [0..<4])
        XCTAssertLessThanOrEqual(layout.contentSize.width, 1300.5)
        XCTAssertEqual(Set(layout.frames.map(\.minY)), [0])
        // A fifth window brings back the rows.
        let five = TileLayout.compute(aspects: [2.0, 2.0, 1.8, 2.2, 1.6], style: .deck, size: .large, available: CGSize(width: 1300, height: 760))
        XCTAssertGreaterThan(five.rows.count, 1)
    }

    func testDeckRowsAreBalanced() {
        // 8 windows that need two rows: 4 + 4, not 7 + 1, both centered.
        let layout = TileLayout.compute(aspects: Array(repeating: 1.6, count: 8), style: .deck, size: .large,
                                        available: CGSize(width: 1400, height: 900))
        XCTAssertEqual(layout.rows.count, 2)
        XCTAssertEqual(layout.rows[0].count, layout.rows[1].count)
    }

    func testDeckKeepsNarrowWindowsReadable() {
        let layout = TileLayout.compute(aspects: [0.5, 2.2, 1.5], style: .deck, size: .medium, available: CGSize(width: 1400, height: 900))
        // The portrait window's cell is wider than its thumbnail would need, so its title fits; the widest window
        // takes at most a third of the row.
        XCTAssertGreaterThan(layout.frames[0].width, layout.thumbnailHeight * 0.5 + 2 * TileLayout.cellInset)
        XCTAssertLessThanOrEqual(layout.frames[1].width, (1400 - 2 * TileLayout.deckSpacing) / 3 + 1)
    }

    func testBalancedRowsPreferFullerTopRows() {
        let rows = TileLayout.balancedRows(Array(repeating: 100, count: 7), maxWidth: 450, spacing: 10)
        XCTAssertEqual(rows, [0..<4, 4..<7])
    }

    func testArrowNavigationAcrossRows() {
        let layout = TileLayout.compute(aspects: Array(repeating: 1.6, count: 7), style: .deck, size: .medium,
                                        available: CGSize(width: 800, height: 900))
        XCTAssertGreaterThan(layout.rows.count, 1)
        let first = layout.rows[0].lowerBound
        let below = layout.target(from: first, .down)
        XCTAssertTrue(layout.rows[1].contains(below))
        XCTAssertEqual(layout.target(from: below, .up), first)
        XCTAssertEqual(layout.target(from: 0, .left), 6)
        XCTAssertEqual(layout.target(from: 6, .right), 0)
    }

    func testAutomaticSizeGrowsForFewWindowsAndFitsMany() {
        let screen = CGSize(width: 1330, height: 760)
        let few = TileLayout.compute(aspects: Array(repeating: 1.6, count: 3), style: .deck, size: .auto, available: screen)
        let medium = TileLayout.compute(aspects: Array(repeating: 1.6, count: 3), style: .deck, size: .medium, available: screen)
        XCTAssertGreaterThan(few.thumbnailHeight, medium.thumbnailHeight)
        // Twelve windows: smaller cells, but every one of them on screen.
        let twelve = TileLayout.compute(aspects: Array(repeating: 1.6, count: 12), style: .deck, size: .auto, available: screen)
        XCTAssertLessThan(twelve.thumbnailHeight, few.thumbnailHeight)
        XCTAssertFalse(twelve.needsScrolling)
        for frame in twelve.frames {
            XCTAssertLessThanOrEqual(frame.maxX, screen.width + 0.5)
            XCTAssertLessThanOrEqual(frame.maxY, screen.height + 0.5)
        }
        // The header follows the cells down.
        XCTAssertLessThanOrEqual(twelve.iconSize, few.iconSize)
    }

    func testTitlesStyleIsCompactAndScrollsByWholeRows() {
        let layout = TileLayout.compute(aspects: Array(repeating: 1.6, count: 40), style: .titles, size: .auto,
                                        available: CGSize(width: 500, height: 700))
        XCTAssertEqual(Set(layout.frames.map(\.minX)), [0])
        XCTAssertEqual(Set(layout.frames.map(\.width)), [500])
        XCTAssertLessThan(layout.frames[0].height, 44)
        XCTAssertTrue(layout.needsScrolling)
        XCTAssertLessThanOrEqual(layout.viewportHeight, 700)
        // Whole rows: the viewport ends at a row's bottom.
        XCTAssertTrue(layout.frames.contains { abs($0.maxY - layout.viewportHeight) < 0.5 })
        XCTAssertEqual(layout.target(from: 0, .up), 39)
    }

    func testOldSizesStillDecode() throws {
        let decoded = try JSONDecoder().decode([SwitcherSize].self, from: Data(#"["small","medium","large","auto"]"#.utf8))
        XCTAssertEqual(decoded, [.small, .medium, .large, .auto])
    }

    func testListStyleIsOneColumn() {
        let layout = TileLayout.compute(aspects: Array(repeating: 1, count: 5), style: .list, size: .medium, available: CGSize(width: 1400, height: 800))
        XCTAssertEqual(Set(layout.frames.map(\.minX)).count, 1)
        XCTAssertEqual(layout.target(from: 2, .down), 3)
        XCTAssertEqual(layout.target(from: 0, .up), 4)
    }
}

final class ShortcutProfileTests: XCTestCase {
    private func profile(_ id: Int, _ key: UInt32 = KeyCodes.tab) -> ShortcutProfile {
        ShortcutProfile(id: id, isEnabled: true, holdModifiers: .option, keyCode: key, scope: .allWindows,
                        showMinimized: true, showHidden: true, showWindowlessApps: false, startInSearch: false)
    }

    func testSanitizedKeepsIdsUniqueAndCountsInRange() {
        let fixed = Prefs.sanitized([profile(2), profile(2), profile(5), profile(2)])
        XCTAssertEqual(Set(fixed.map(\.id)).count, 4)
        XCTAssertEqual(Prefs.sanitized((0..<12).map { profile($0) }).count, ShortcutProfile.maximum)
        XCTAssertEqual(Prefs.sanitized([]).count, 1)
    }

    func testAddedShortcutStartsOffWithAFreeKey() {
        let existing = [profile(0, KeyCodes.tab), profile(1, KeyCodes.keyAboveTab)]
        let added = ShortcutProfile.added(id: 2, besides: existing)
        XCTAssertFalse(added.isEnabled)
        XCTAssertEqual(added.keyCode, KeyCodes.space)
        XCTAssertEqual(added.id, 2)
    }
}

final class KeyCodeTests: XCTestCase {
    func testModifierSymbolsOrder() {
        XCTAssertEqual(CarbonModifiers([.command, .option, .control, .shift]).symbols, "⌃⌥⇧⌘")
    }

    func testNamedKeys() {
        XCTAssertEqual(KeyCodes.name(for: KeyCodes.tab), "⇥")
        XCTAssertEqual(KeyCodes.name(for: KeyCodes.space), L.t("Boşluk", "Space"))
    }
}

final class WindowEligibilityTests: XCTestCase {
    private let element = AXUIElementCreateApplication(getpid())

    private func snapshot(role: String? = kAXWindowRole, subrole: String?, title: String = "Doc", main: Bool = false, fullscreen: Bool = false) -> AXWindowSnapshot {
        AXWindowSnapshot(element: element, wid: 42, role: role, subrole: subrole, title: title, isMinimized: false,
                         isFullscreen: fullscreen, isMain: main, frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    private func description(layer: Int = 0, size: CGSize = CGSize(width: 800, height: 600)) -> CGWindowDescription {
        CGWindowDescription(wid: 42, pid: 1, layer: layer, bounds: CGRect(origin: .zero, size: size), alpha: 1, isOnScreen: true, name: nil)
    }

    func testStandardWindowAdmitted() {
        XCTAssertTrue(WindowEligibility.admit(snapshot(subrole: kAXStandardWindowSubrole), description()))
    }

    func testPalettesAndSystemDialogsRejected() {
        XCTAssertFalse(WindowEligibility.admit(snapshot(subrole: "AXFloatingWindow"), description()))
        XCTAssertFalse(WindowEligibility.admit(snapshot(subrole: "AXSystemDialog"), description()))
    }

    func testDialogsNeedATitle() {
        XCTAssertTrue(WindowEligibility.admit(snapshot(subrole: kAXDialogSubrole, title: "Save"), description()))
        XCTAssertFalse(WindowEligibility.admit(snapshot(subrole: kAXDialogSubrole, title: ""), description()))
    }

    func testAboveNormalLevelOnlyMainOrFullscreen() {
        XCTAssertFalse(WindowEligibility.admit(snapshot(subrole: kAXStandardWindowSubrole), description(layer: 3)))
        XCTAssertTrue(WindowEligibility.admit(snapshot(subrole: kAXStandardWindowSubrole, main: true), description(layer: 3)))
        XCTAssertTrue(WindowEligibility.admit(snapshot(subrole: kAXStandardWindowSubrole, fullscreen: true), description(layer: 3)))
    }

    func testCustomRootsNeedTitleAndSize() {
        XCTAssertTrue(WindowEligibility.admit(snapshot(subrole: nil, title: "Game"), description()))
        XCTAssertFalse(WindowEligibility.admit(snapshot(subrole: nil, title: ""), description()))
        XCTAssertFalse(WindowEligibility.admit(snapshot(subrole: nil, title: "Tiny"), description(size: CGSize(width: 40, height: 20))))
        XCTAssertFalse(WindowEligibility.admit(snapshot(role: "AXGroup", subrole: nil, title: "Group"), description()))
    }

    func testUnknownToWindowServerRejected() {
        XCTAssertFalse(WindowEligibility.admit(snapshot(subrole: kAXStandardWindowSubrole), nil))
    }
}

final class LocalizationTests: XCTestCase {
    func testSystemLanguagesMapToTheTwentyOne() {
        XCTAssertEqual(AppLanguage.allCases.count, 21)
        XCTAssertEqual(AppLanguage.matching("de-DE"), .de)
        XCTAssertEqual(AppLanguage.matching("pt-PT"), .ptBR)
        XCTAssertEqual(AppLanguage.matching("zh-Hans-CN"), .zhCN)
        XCTAssertEqual(AppLanguage.matching("zh-Hant-TW"), .zhTW)
        XCTAssertEqual(AppLanguage.matching("zh-Hant-HK"), .zhHK)
        XCTAssertEqual(AppLanguage.matching("zh-HK"), .zhHK)
        XCTAssertEqual(AppLanguage.matching("iw-IL"), .he)
        XCTAssertEqual(AppLanguage.matching("tr_TR"), .tr)
        XCTAssertNil(AppLanguage.matching("fi-FI"))
        // Settings saved before there were 21 still load.
        XCTAssertEqual(try JSONDecoder().decode([AppLanguage].self, from: Data(#"["tr","en","pt-BR","zh-TW"]"#.utf8)),
                       [.tr, .en, .ptBR, .zhTW])
    }

    func testEveryTableHasEveryStringWithItsPlaceholders() {
        let english = Set(Translations.table(for: .de).keys)
        XCTAssertGreaterThan(english.count, 100)
        let placeholder = try! NSRegularExpression(pattern: "%(\\d+\\$)?@")
        func placeholders(_ text: String) -> [String] {
            placeholder.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }.sorted()
        }
        for language in AppLanguage.allCases where language != .tr && language != .en {
            let table = Translations.table(for: language)
            XCTAssertEqual(Set(table.keys), english, "\(language.rawValue) has different strings")
            for (key, value) in table {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "\(language.rawValue): empty \(key)")
                XCTAssertEqual(placeholders(value), placeholders(key), "\(language.rawValue): \(key) -> \(value)")
            }
        }
    }

    func testFormatsFillInEveryLanguage() {
        for language in AppLanguage.allCases {
            let template = L.text("%1$@ / %2$@ pencere", "%1$@ of %2$@ windows", in: language)
            let filled = String(format: template, arguments: ["2" as NSString, "12" as NSString])
            XCTAssertTrue(filled.contains("2") && filled.contains("12"), "\(language.rawValue): \(filled)")
            XCTAssertFalse(filled.contains("%"), "\(language.rawValue): \(filled)")
        }
    }
}

final class NotchedScreenTests: XCTestCase {
    /// Notched Mac displays in points, at their default and their most- and least-dense scaled resolutions, with the
    /// camera housing's height in points at that scale.
    private let screens: [(name: String, size: CGSize, notch: CGFloat)] = [
        ("13-inch Air, larger text", CGSize(width: 1147, height: 745), 25),
        ("13-inch Air", CGSize(width: 1470, height: 956), 32),
        ("13-inch Air, more space", CGSize(width: 1710, height: 1112), 37),
        ("14-inch Pro", CGSize(width: 1512, height: 982), 32),
        ("14-inch Pro, more space", CGSize(width: 1800, height: 1169), 38),
        ("15-inch Air", CGSize(width: 1710, height: 1112), 32),
        ("16-inch Pro", CGSize(width: 1728, height: 1117), 32),
        ("16-inch Pro, more space", CGSize(width: 2056, height: 1329), 38),
    ]

    func testThePanelStaysUnderTheNotch() {
        for screen in screens {
            let frame = CGRect(origin: .zero, size: screen.size)
            // With the menu bar showing it already sits under the notch; a full-screen app hides it.
            let withMenuBar = CGRect(x: 0, y: 0, width: frame.width, height: frame.height - screen.notch - 1)
            for visible in [withMenuBar, frame] {
                let usable = SwitcherUI.usableFrame(visible: visible, frame: frame, topInset: screen.notch)
                XCTAssertLessThanOrEqual(usable.maxY, frame.maxY - screen.notch, screen.name)
                for searching in [false, true] {
                    let limits = SwitcherUI.contentLimits(in: usable, searching: searching)
                    // The tallest panel the content allows, centered: its top edge still clears the notch.
                    let panelHeight = limits.height + 2 * SwitcherUI.padding + (searching ? 46 + SwitcherUI.sectionGap : 0)
                    let top = usable.midY + panelHeight / 2
                    XCTAssertLessThan(top, frame.maxY - screen.notch, "\(screen.name), searching: \(searching)")
                }
            }
        }
    }

    func testEveryStyleFitsEveryNotchedScreen() {
        for screen in screens {
            let usable = SwitcherUI.usableFrame(visible: CGRect(origin: .zero, size: screen.size),
                                                frame: CGRect(origin: .zero, size: screen.size), topInset: screen.notch)
            let limits = SwitcherUI.contentLimits(in: usable, searching: false)
            let deckRoom = CGSize(width: limits.width - 2 * TileLayout.deckInset, height: limits.height - 2 * TileLayout.deckInset)
            for count in [1, 2, 3, 4, 5, 8, 12, 20, 40] {
                let aspects: [CGFloat] = (0..<count).map { [1.6, 1.33, 0.78, 2.1][$0 % 4] }
                for size in SwitcherSize.allCases {
                    let deck = TileLayout.compute(aspects: aspects, style: .deck, size: size, available: deckRoom)
                    XCTAssertLessThanOrEqual(deck.contentSize.width, deckRoom.width + 0.5, "\(screen.name) deck \(count) \(size)")
                    XCTAssertLessThanOrEqual(deck.viewportHeight, deckRoom.height + 0.5, "\(screen.name) deck \(count) \(size)")
                    let icons = TileLayout.compute(aspects: aspects, style: .appIcons, size: size, available: limits)
                    XCTAssertLessThanOrEqual(icons.contentSize.width, limits.width + 0.5, "\(screen.name) icons \(count)")
                    XCTAssertLessThanOrEqual(icons.viewportHeight, limits.height + 0.5, "\(screen.name) icons \(count)")
                    let titles = TileLayout.compute(aspects: aspects, style: .titles, size: size,
                                                    available: CGSize(width: min(720, limits.width), height: limits.height))
                    XCTAssertLessThanOrEqual(titles.viewportHeight, limits.height + 0.5, "\(screen.name) titles \(count)")
                }
            }
        }
    }
}
