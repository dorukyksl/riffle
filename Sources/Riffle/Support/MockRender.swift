import Cocoa
import UniformTypeIdentifiers

/// `Riffle --mock <folder>`: renders the switcher with made-up windows into PNGs, offscreen. Needs no permissions,
/// so the design can be checked anywhere (and screenshots for docs never show real windows).
enum MockRender {
    struct Sample {
        let bundleID: String
        let app: (tr: String, en: String)
        let title: (tr: String, en: String)
        /// What the window looks like; nil for an app without windows.
        let art: MockArt.Kind?
        let aspect: CGFloat
        var minimized = false
        var hidden = false
        var fullscreen = false
        var space: Int? = nil
        var windowless = false
        var badge: String? = nil

        func appName(_ language: AppLanguage) -> String { language == .tr ? app.tr : app.en }
        func windowTitle(_ language: AppLanguage) -> String { language == .tr ? title.tr : title.en }
    }

    static let safari = Sample(bundleID: "com.apple.Safari", app: ("Safari", "Safari"),
                               title: ("İstanbul'un en iyi kafeleri", "The best cafés in Istanbul"), art: .browser, aspect: 1.6)
    static let terminal = Sample(bundleID: "com.apple.Terminal", app: ("Terminal", "Terminal"),
                                 title: ("riffle — swift build — 120×40", "riffle — swift build — 120×40"), art: .terminal, aspect: 1.45)
    static let notes = Sample(bundleID: "com.apple.Notes", app: ("Notlar", "Notes"),
                              title: ("Hafta sonu planı", "Weekend plan"), art: .notes, aspect: 1.3,
                              space: 2)
    static let xcode = Sample(bundleID: "com.apple.dt.Xcode", app: ("Xcode", "Xcode"),
                              title: ("Riffle — SwitcherController.swift", "Riffle — SwitcherController.swift"), art: .code, aspect: 1.7,
                              fullscreen: true, space: 3)
    static let mail = Sample(bundleID: "com.apple.mail", app: ("Mail", "Mail"),
                             title: ("Gelen Kutusu — 3 okunmamış", "Inbox — 3 unread"), art: .mail, aspect: 1.5, minimized: true, badge: "3")
    static let finder = Sample(bundleID: "com.apple.finder", app: ("Finder", "Finder"), title: ("İndirilenler", "Downloads"),
                               art: .finder, aspect: 1.4)
    static let music = Sample(bundleID: "com.apple.Music", app: ("Müzik", "Music"), title: ("Şimdi Çalıyor", "Now Playing"),
                              art: .music, aspect: 1.55, hidden: true)
    static let preview = Sample(bundleID: "com.apple.Preview", app: ("Önizleme", "Preview"),
                                title: ("fatura-ekim.pdf", "invoice-october.pdf"), art: .document, aspect: 0.78)
    static let messages = Sample(bundleID: "com.apple.MobileSMS", app: ("Mesajlar", "Messages"), title: ("", ""), art: nil, aspect: 1.5,
                                 windowless: true, badge: "12")

    static let samples: [Sample] = [safari, terminal, notes, xcode, mail, finder, music, preview, messages]

    /// The notes window titled in Arabic: a window's title is in whatever language its document is, so the right-to-left
    /// renders show one in a right-to-left script next to the Latin ones.
    static let arabicNotes = Sample(bundleID: "com.apple.Notes", app: ("Notlar", "Notes"),
                                    title: ("خطة نهاية الأسبوع", "خطة نهاية الأسبوع"), art: .notes, aspect: 1.3, space: 2)

    /// The windows of the right-to-left renders: the same ones, the notes titled in Arabic.
    static let rightToLeftSamples: [Sample] = samples.map { $0.bundleID == notes.bundleID ? arabicNotes : $0 }

    /// What Settings → Exceptions lists in pictures of it, instead of the user's own rules, which name apps they chose.
    static let exceptions = [
        AppException(bundleID: "com.apple.Music", hiding: .allWindows),
        AppException(bundleID: "com.apple.Preview", hiding: .titleContains, titleText: "PDF"),
        AppException(bundleID: "com.apple.ScreenSharing", hiding: .nothing, ignoresShortcuts: .always),
    ]

    /// Switcher rows for `samples`, their thumbnails ready in the thumbnail cache, and the Dock badges they show.
    /// Window ids start at `firstWID`; give each set its own range so cached thumbnails don't mix.
    static func items(_ samples: [Sample], language: AppLanguage, firstWID: CGWindowID = 9000,
                      thumbnailWidth: Int = 560) -> (items: [SwitcherItem], badges: [String: String]) {
        var items = [SwitcherItem]()
        var badges = [String: String]()
        for (index, sample) in samples.enumerated() {
            let wid = firstWID + CGWindowID(index)
            let pid = pid_t(1000 + Int(firstWID) + index)
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: sample.bundleID)
            let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(named: NSImage.applicationIconName)!
            let frame = CGRect(x: 0, y: 0, width: 1000 * sample.aspect, height: 1000)
            var item = SwitcherItem(kind: sample.windowless ? .app(pid) : .window(wid), pid: pid, appName: sample.appName(language),
                                    title: sample.windowTitle(language), icon: icon, isMinimized: sample.minimized, isHidden: sample.hidden,
                                    isFullscreen: sample.fullscreen, otherSpaceIndex: sample.space,
                                    frame: sample.windowless ? .zero : frame, bundleID: sample.bundleID)
            item.bundlePath = "/mock/\(sample.bundleID)"
            if let badge = sample.badge { badges[item.bundlePath!] = badge }
            if !sample.windowless, let art = sample.art {
                let width = sample.aspect >= 1 ? thumbnailWidth : Int(CGFloat(thumbnailWidth) * sample.aspect)
                ThumbnailService.shared.inject(MockArt.image(art, width: width, aspect: sample.aspect), for: wid)
            }
            items.append(item)
        }
        return (items, badges)
    }

    static func run(outputDirectory: String) {
        let output = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { exit(1) }
        // Renders switch styles and languages: never into the user's settings.
        Prefs.persists = false
        let language = Prefs.shared.language
        let (items, badges) = MockRender.items(samples, language: language)
        let ui = SwitcherUI()
        let dark = NSAppearance(named: .darkAqua)!
        let light = NSAppearance(named: .aqua)!
        // A busy day: the same windows again, as if a few more were open.
        let many = items + items.prefix(7).enumerated().map { offset, item in
            var copy = SwitcherItem(kind: item.wid.map { .window($0 + 100) } ?? .app(item.pid + 100), pid: item.pid, appName: item.appName,
                                    title: item.title.isEmpty ? item.title : item.title + " (2)", icon: item.icon, isMinimized: false,
                                    isHidden: false, isFullscreen: false, otherSpaceIndex: offset % 3 == 0 ? 2 : nil, frame: item.frame,
                                    bundleID: item.bundleID)
            copy.bundlePath = item.bundlePath
            if let wid = item.wid, let image = ThumbnailService.shared.image(for: wid) { ThumbnailService.shared.inject(image, for: wid + 100) }
            return copy
        }
        // Right to left, in Arabic and Hebrew: the same windows (made after the ones above, in a range of their own).
        let arabic = MockRender.items(rightToLeftSamples, language: .ar, firstWID: 9200).items
        let hebrew = MockRender.items(rightToLeftSamples, language: .he, firstWID: 9300).items
        let renders: [(String, SwitcherStyle, NSAppearance, Bool, String, [SwitcherItem], AppLanguage)] = [
            ("deck-dark", .deck, dark, false, "", items, language),
            ("deck-light", .deck, light, false, "", items, language),
            ("deck-many-dark", .deck, dark, false, "", many, language),
            ("deck-four-light", .deck, light, false, "", Array(items.prefix(4)), language),
            ("deck-search-dark", .deck, dark, true, language == .tr ? "istanbul" : "cafes", items, language),
            ("deck-hover-light", .deck, light, false, "", Array(items.prefix(5)), language),
            ("stage-dark", .stage, dark, false, "", items, language),
            ("icons-dark", .appIcons, dark, false, "", items, language),
            ("titles-light", .titles, light, false, "", items, language),
            ("titles-many-dark", .titles, dark, false, "", many, language),
            ("list-search-light", .list, light, true, "s", items, language),
            // Last, so the renders above come out as they always have.
            ("deck-rtl-dark", .deck, dark, false, "", arabic, .ar),
            ("deck-rtl-hover-light", .deck, light, false, "", Array(arabic.prefix(5)), .ar),
            ("deck-rtl-search-dark", .deck, dark, true, "خطة", arabic, .ar),
            ("stage-rtl-dark", .stage, dark, false, "", arabic, .ar),
            ("icons-rtl-dark", .appIcons, dark, false, "", hebrew, .he),
            ("titles-rtl-light", .titles, light, false, "", hebrew, .he),
            ("list-rtl-light", .list, light, false, "", arabic, .ar),
            ("list-rtl-search-light", .list, light, true, "s", hebrew, .he),
        ]
        var queue = renders
        func next() {
            guard !queue.isEmpty else {
                print("mock renders → \(output.path)")
                exit(0)
            }
            let (name, style, appearance, searching, query, items, language) = queue.removeFirst()
            Prefs.shared.style = style
            Prefs.shared.language = language
            let shown = searching ? FuzzySearch.rank(items, query: query) : items
            ui.prepareOffscreen(items: shown, selected: searching ? 0 : 1, searching: searching, query: query,
                                screen: screen, appearance: appearance, badges: badges, total: items.count)
            // The mouse resting on a card shows its window buttons.
            if name.contains("hover") { ui.tiles[safe: 3]?.showCardButtons(true) }
            // Let AppKit attach the new views' layers before rendering them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if let image = ui.captureOffscreen() { write(image, output.appendingPathComponent("\(name).png")) }
                next()
            }
        }
        next()
    }

    static func write(_ image: CGImage, _ url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
