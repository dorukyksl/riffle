import Cocoa

/// `Riffle --site-images <folder> --windows <folder>`: the switcher as the app draws it, in light mode and English, from
/// the website's sample windows (no permissions needed, never a real window): the reference the website's own copy of
/// the switcher is checked against. `--windows` is `website/img/windows`, where `Scripts/site-assets.sh` writes the
/// sample windows as `<id>-1400.webp`; without it `MockArt` draws them. Every picture is the panel's contents alone,
/// transparent around and between the cells. Writes `<folder>/<name>.png` (`demo-panel`, `deck`, `search`, `hover`,
/// `badge`, and `style-<layout>` for the five layouts) and `<folder>/panels.js`: each picture's size and corner radius,
/// and where the demo panel's cells are. `Scripts/site-images.sh --reference <folder>` runs it.
enum SiteRender {
    /// The website's accent: the rose in the middle of the app icon.
    static let accent = NSColor(srgbRed: 1, green: 0.42, blue: 0.6, alpha: 1)

    private struct Job {
        let name: String
        var style: SwitcherStyle = .deck
        var dark = false
        let windows: [Window]
        var selected = 1
        var query: String? = nil
        var hover: Int? = nil
    }

    /// A window of the website's sample desktop: `id` names its picture, `<id>-1400.webp`.
    struct Window {
        let id: String
        let sample: MockRender.Sample
    }

    private static func window(_ id: String, _ bundleID: String, _ app: String, _ title: String, _ art: MockArt.Kind?,
                               _ size: CGSize, minimized: Bool = false, hidden: Bool = false, fullscreen: Bool = false,
                               space: Int? = nil, badge: String? = nil) -> Window {
        Window(id: id, sample: MockRender.Sample(bundleID: bundleID, app: (app, app), title: (title, title), art: art,
                                                 aspect: size.width / size.height, minimized: minimized, hidden: hidden,
                                                 fullscreen: fullscreen, space: space, windowless: art == nil, badge: badge))
    }

    /// The same windows, titles and states as the website's sample desktop, most recently used first.
    static let windows: [Window] = [
        window("safari-lisbon", "com.apple.Safari", "Safari", "Lisbon: three days on foot", .browser, CGSize(width: 1400, height: 876)),
        window("xcode-sketchpad", "com.apple.dt.Xcode", "Xcode", "Sketchpad.swift", .code, CGSize(width: 1400, height: 980)),
        window("notes-weekend", "com.apple.Notes", "Notes", "Weekend plan", .notes, CGSize(width: 1400, height: 1076), space: 2),
        window("mail-inbox", "com.apple.mail", "Mail", "Inbox", .mail, CGSize(width: 1400, height: 934), badge: "3"),
        window("terminal-build", "com.apple.Terminal", "Terminal", "Build log", .terminal, CGSize(width: 1400, height: 966)),
        window("chrome-kyoto", "com.google.Chrome", "Google Chrome", "Flights to Kyoto", .browser, CGSize(width: 1400, height: 1056),
               fullscreen: true, space: 3),
        window("finder-downloads", "com.apple.finder", "Finder", "Downloads", .finder, CGSize(width: 1400, height: 1000)),
        window("preview-invoice", "com.apple.Preview", "Preview", "Invoice October.pdf", .document, CGSize(width: 1400, height: 1768),
               space: 2),
        window("safari-sourdough", "com.apple.Safari", "Safari", "Sourdough starter, day 4", .browser, CGSize(width: 1400, height: 876)),
        window("notes-books", "com.apple.Notes", "Notes", "Books to read", .notes, CGSize(width: 1400, height: 1076)),
        window("music-now", "com.apple.Music", "Music", "Now Playing", .music, CGSize(width: 1400, height: 904), hidden: true),
        window("finder-projects", "com.apple.finder", "Finder", "Projects", .finder, CGSize(width: 1400, height: 1000), minimized: true),
        window("", "com.apple.MobileSMS", "Messages", "", nil, CGSize(width: 1500, height: 1000), badge: "2"),
    ]

    static func run(outputDirectory: String, windows pictures: String? = nil) {
        let output = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { exit(1) }
        let picturesFolder = pictures.map { URL(fileURLWithPath: $0, isDirectory: true) }
        var cache = [String: CGImage]()
        func picture(_ window: Window) -> CGImage? {
            guard !window.id.isEmpty else { return nil }
            if let cached = cache[window.id] { return cached }
            guard let url = picturesFolder?.appendingPathComponent("\(window.id)-1400.webp"),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            cache[window.id] = image
            return image
        }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        Prefs.persists = false
        Palette.accentOverride = accent
        let prefs = Prefs.shared
        prefs.language = .en
        prefs.size = .medium
        prefs.showBadges = true
        prefs.showSpaceNumbers = true

        let all = Self.windows
        // The demo is the first look at the switcher: eight windows, the most recent ones, nothing selected (the page
        // moves its own selection over them).
        let demo = Array(all.prefix(8))
        let seven = Array(all.prefix(7))
        var jobs = [Job(name: "demo-panel", windows: demo, selected: -1), Job(name: "deck", windows: all),
                    Job(name: "search", windows: all, selected: 0, query: "kyoto"),
                    Job(name: "hover", windows: [all[0]], selected: 0, hover: 0),
                    Job(name: "badge", windows: [all[3]], selected: -1)]
        for (name, style) in [("style-deck", SwitcherStyle.deck), ("style-stage", .stage), ("style-icons", .appIcons),
                              ("style-titles", .titles), ("style-list", .list)] {
            jobs.append(Job(name: name, style: style, windows: seven))
        }

        let ui = SwitcherUI()
        var panels = [String: Any]()
        var nextWID: CGWindowID = 20000
        var queue = jobs
        func next() {
            guard !queue.isEmpty else {
                writePanels(panels, to: output)
                print("site images → \(output.path)")
                exit(0)
            }
            let job = queue.removeFirst()
            prefs.style = job.style
            let samples = job.windows.map(\.sample)
            let (items, badges) = MockRender.items(samples, language: .en, firstWID: nextWID, thumbnailWidth: 1000)
            nextWID += 50
            // The website's sample windows, when given, stand in for the drawn ones.
            for (item, window) in zip(items, job.windows) {
                if let wid = item.wid, let image = picture(window) { ThumbnailService.shared.inject(image, for: wid) }
            }
            let shown = job.query.map { FuzzySearch.rank(items, query: $0) } ?? items
            ui.prepareOffscreen(items: shown, selected: job.selected, searching: job.query != nil, query: job.query ?? "", screen: screen,
                                appearance: NSAppearance(named: job.dark ? .darkAqua : .aqua)!, badges: badges, total: items.count)
            if let hover = job.hover { ui.tiles[safe: hover]?.showCardButtons(true) }
            // Let AppKit attach the new views' layers before rendering them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                defer { next() }
                guard let contents = ui.captureOffscreen(backdrop: false) else { return }
                MockRender.write(contents, output.appendingPathComponent("\(job.name).png"))
                let layout = ui.offscreenTileFrames()
                var panel = describe(layout.size, pixels: CGSize(width: contents.width, height: contents.height), dark: job.dark)
                if job.name == "demo-panel" {
                    let labels = shown.map { $0.title.isEmpty ? $0.appName : "\($0.title), \($0.appName)" }
                    panel["cells"] = cells(layout, windows: job.windows, labels: labels)
                }
                panels[job.name] = panel
            }
        }
        next()
    }

    // MARK: - The pictures' map

    /// Four decimals are plenty, and print as written.
    private static func round(_ value: CGFloat) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.4f", Double(value))) }

    /// A picture's size in pixels, its corner radius and the selection's as fractions of its width, and its appearance.
    private static func describe(_ size: CGSize, pixels: CGSize, dark: Bool) -> [String: Any] {
        ["width": Int(pixels.width), "height": Int(pixels.height), "dark": dark,
         "radius": round(SwitcherUI.cornerRadius / size.width), "plateRadius": round(16 / size.width)]
    }

    /// The cells as fractions of the picture, each with its window.
    private static func cells(_ layout: (size: CGSize, frames: [CGRect]), windows: [Window], labels: [String]) -> [[String: Any]] {
        let size = layout.size
        return layout.frames.enumerated().map { index, frame in
            ["x": round(frame.minX / size.width), "y": round(frame.minY / size.height),
             "w": round(frame.width / size.width), "h": round(frame.height / size.height),
             "id": windows[safe: index]?.id ?? "", "label": labels[safe: index] ?? ""]
        }
    }

    /// `window.RIFFLE_PANELS`, for the page.
    private static func writePanels(_ panels: [String: Any], to output: URL) {
        guard let json = try? JSONSerialization.data(withJSONObject: panels, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: json, encoding: .utf8) else { return }
        let script = "// Written by `Riffle --site-images`: the switcher pictures' sizes, and where the demo panel's cells are.\n" +
            "window.RIFFLE_PANELS = \(text);\n"
        try? script.write(to: output.appendingPathComponent("panels.js"), atomically: true, encoding: .utf8)
    }
}
