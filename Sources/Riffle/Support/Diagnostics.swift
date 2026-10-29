import Cocoa
import ScreenCaptureKit
import UniformTypeIdentifiers

/// `Riffle --diag <folder>`: a self-test that runs with Riffle's own permissions. It inventories windows, measures
/// thumbnails, shows the real switcher in every style and photographs Settings, writing everything to <folder>. Used to
/// verify a build end to end without anyone pressing keys. Nothing leaves the Mac, nothing written names a window or an
/// app (`DiagnosticRecord`), and the settings it changes on the way are never saved.
enum Diagnostics {
    private static var output = URL(fileURLWithPath: NSTemporaryDirectory())
    private static var report = [String: Any]()
    private static var steps = [(String, () -> Void)]()

    static func run(outputDirectory: String) {
        // First, before anything reads the settings: a run cut short must not leave the user with another style.
        Prefs.persists = false
        Log.echoToStdout = true
        output = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        report["version"] = "\(AppInfo.version) (\(AppInfo.build))"
        report["accessibility"] = Permissions.accessibility
        report["screenRecording"] = Permissions.screenRecording
        report["eventTap"] = ModifierMonitor.shared.installEventTapIfPossible()
        Log.info("diag: AX=\(Permissions.accessibility) screen=\(Permissions.screenRecording)")
        _ = SwitcherController.shared
        let started = ProcessInfo.processInfo.systemUptime
        WindowStore.shared.start {
            report["firstScanSeconds"] = ProcessInfo.processInfo.systemUptime - started
            // A second scan shows the steady-state cost (AX handshakes are paid once per app).
            let second = ProcessInfo.processInfo.systemUptime
            WindowStore.shared.rescan {
                report["secondScanSeconds"] = ProcessInfo.processInfo.systemUptime - second
                inventory()
                runSteps()
            }
        }
    }

    private static func inventory() {
        let store = WindowStore.shared
        let topology = store.topology
        report["spaces"] = topology.spaces.map { DiagnosticRecord.space($0, in: topology) }
        report["windows"] = store.windows.values.sorted { $0.focusStamp > $1.focusStamp }.map(DiagnosticRecord.window)
        report["apps"] = store.apps.values.sorted { $0.pid < $1.pid }.map {
            ["pid": $0.pid, "bundleID": $0.bundleID ?? "", "hidden": $0.isHidden, "responsive": $0.isResponsive]
        }
        let profile = Prefs.shared.profiles[0]
        report["switcherOrder"] = store.items(for: profile, screen: NSScreen.main).map(DiagnosticRecord.row)
        report["frontmost"] = DiagnosticRecord.app(NSWorkspace.shared.frontmostApplication)
        report["focusedWID"] = store.currentFocusedWID ?? 0
    }

    private static func runSteps() {
        let windows = WindowStore.shared.windows.values.sorted { $0.focusStamp > $1.focusStamp }
        steps = [
            ("thumbnails", {
                ThumbnailService.shared.refresh(windows.prefix(16).map { .init(wid: $0.wid, frame: $0.frame, isMinimized: $0.isMinimized) }, freshness: 0)
            }),
            ("measure thumbnails", {
                // Real windows can hold private content: only measure the captures, never write them out.
                report["thumbnails"] = windows.prefix(16).map { window -> [String: Any] in
                    let app = DiagnosticRecord.app(window.app, pid: window.pid)
                    guard let image = ThumbnailService.shared.image(for: window.wid) else {
                        return ["wid": window.wid, "app": app, "captured": false, "minimized": window.isMinimized]
                    }
                    let stats = ImageStats(image)
                    return ["wid": window.wid, "app": app, "captured": true, "size": "\(image.width)x\(image.height)",
                            "meanLuma": stats.mean, "lumaStdDev": stats.deviation, "minimized": window.isMinimized]
                }
            }),
            ("switcher", { show(style: .deck) }),
            ("switcher stage", { SwitcherController.shared.cancel(); show(style: .stage) }),
            ("switcher list", { SwitcherController.shared.cancel(); show(style: .list) }),
            ("switcher icons", { SwitcherController.shared.cancel(); show(style: .appIcons) }),
            ("switcher titles", { SwitcherController.shared.cancel(); show(style: .titles) }),
            ("search", {
                SwitcherController.shared.cancel()
                Prefs.shared.style = .deck
                SwitcherController.shared.showSticky(searching: true)
                // The first letters of the latest window's app: that app must be among the results. The letters only go
                // into the search field.
                let source = windows.first
                let query = String((source?.app?.name ?? "a").prefix(3))
                SwitcherController.shared.ui.searchBar.field.stringValue = query
                SwitcherController.shared.switcherUIQueryChanged(query)
                let results = SwitcherController.shared.session?.items ?? []
                report["search"] = [
                    "queryFrom": source.map { DiagnosticRecord.app($0.app, pid: $0.pid) } ?? "-", "queryLength": query.count,
                    "results": results.map(DiagnosticRecord.row), "foundTheApp": results.contains { $0.pid == source?.pid },
                ]
            }),
            ("settings", {
                SwitcherController.shared.cancel()
                // Made-up exceptions in the pictures: the user's own name the apps they chose.
                Prefs.shared.appExceptions = MockRender.exceptions
                SettingsWindow.shared.show(section: .general)
            }),
            ("capture settings general", { captureOwnWindow("settings-general.png") ; SettingsWindow.shared.show(section: .shortcuts) }),
            ("capture settings shortcuts", { captureOwnWindow("settings-shortcuts.png"); SettingsWindow.shared.show(section: .appearance) }),
            ("capture settings appearance", { captureOwnWindow("settings-appearance.png"); SettingsWindow.shared.show(section: .exclusions) }),
            ("capture settings exclusions", { captureOwnWindow("settings-exclusions.png"); SettingsWindow.shared.show(section: .permissions) }),
            ("capture settings permissions", { captureOwnWindow("settings-permissions.png"); SettingsWindow.shared.show(section: .about) }),
            ("capture settings about", { captureOwnWindow("settings-about.png"); OnboardingWindow.shared.show() }),
            ("capture onboarding", {
                captureOwnWindow("onboarding.png")
                // Put away rather than closed: closing the welcome window marks it done, a setting `Prefs.persists` doesn't cover.
                NSApp.windows.forEach { if !($0 is NSPanel) { $0.orderOut(nil) } }
            }),
            ("focus test", { focusTest(windows) }),
            ("focus verify", { verifyFocus() }),
            ("focus restore", { restoreFocus() }),
            ("finish", {
                SwitcherController.shared.cancel()
                writeReport()
                Log.info("diag: done → \(output.path)")
                Log.flush()
                exit(0)
            }),
        ]
        next()
    }

    private static var focusTarget: TrackedWindow?
    private static var focusOrigin: TrackedWindow?

    /// Switches to the second most recent window (other than Riffle's own), then checks that it really got focus.
    private static func focusTest(_ windows: [TrackedWindow]) {
        let candidates = windows.filter { $0.app?.bundleID != Bundle.main.bundleIdentifier && !$0.isMinimized }
        focusOrigin = candidates.first { $0.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier }
        // Not the warning macOS shows about apps using Accessibility.
        focusTarget = candidates.first { $0.wid != focusOrigin?.wid && $0.app?.bundleID != "com.apple.accessibility.universalAccessAuthWarn" }
        guard let target = focusTarget else {
            report["focusTest"] = "skipped: no candidate"
            return
        }
        report["focusTarget"] = DiagnosticRecord.window(target)
        WindowActions.focus(.init(wid: target.wid, pid: target.pid, element: target.element, isMinimized: false, spaceIDs: target.spaceIDs))
    }

    private static func verifyFocus() {
        guard let target = focusTarget else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let focusedWID = front.flatMap { AXReader.focusedWindow(ofApp: AXUIElementCreateApplication($0.processIdentifier))?.windowID }
        report["focusResult"] = [
            "frontmostApp": DiagnosticRecord.app(front),
            "frontmostIsTarget": front?.processIdentifier == target.pid,
            "focusedWindowIsTarget": focusedWID == target.wid,
        ]
        Log.info("diag: focus → front=\(Log.app(front)) ok=\(front?.processIdentifier == target.pid && focusedWID == target.wid)")
    }

    private static func restoreFocus() {
        guard let origin = focusOrigin else { return }
        WindowActions.focus(.init(wid: origin.wid, pid: origin.pid, element: origin.element, isMinimized: false, spaceIDs: origin.spaceIDs))
    }

    private static func next() {
        guard !steps.isEmpty else { return }
        let (name, body) = steps.removeFirst()
        Log.info("diag: \(name)")
        body()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { next() }
    }

    private static func show(style: SwitcherStyle) {
        Prefs.shared.style = style
        SwitcherController.shared.showSticky()
    }

    // MARK: - The switcher on real glass

    /// `Riffle --diag-glass <folder>`: shows the deck and the stage on screen, searched down to Riffle's own windows,
    /// and photographs them with only Riffle's windows composited (no other app, no wallpaper). Nothing of the
    /// user's ever ends up in the pictures.
    static func runGlass(outputDirectory: String) {
        // It switches styles and themes: never in the user's settings.
        Prefs.persists = false
        Log.echoToStdout = true
        output = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = SwitcherController.shared
        WindowStore.shared.start {
            SettingsWindow.shared.show(section: .appearance)
            steps = [
                ("rescan", { WindowStore.shared.rescan() }),
                ("deck dark", { showOwnWindows(.deck, theme: .dark) }),
                ("capture deck dark", { captureOwnPanel("deck-glass-dark.png") }),
                ("deck light", { showOwnWindows(.deck, theme: .light) }),
                ("capture deck light", { captureOwnPanel("deck-glass-light.png") }),
                ("stage dark", { showOwnWindows(.stage, theme: .dark) }),
                ("capture stage dark", { captureOwnPanel("stage-glass-dark.png") }),
                ("finish", {
                    SwitcherController.shared.cancel()
                    NSApp.windows.forEach { if !($0 is NSPanel) { $0.close() } }
                    writeReport()
                    Log.flush()
                    exit(0)
                }),
            ]
            next()
        }
    }

    private static func showOwnWindows(_ style: SwitcherStyle, theme: ThemeMode) {
        SwitcherController.shared.cancel()
        Prefs.shared.style = style
        Prefs.shared.theme = theme
        SwitcherController.shared.showSticky(searching: true)
        SwitcherController.shared.ui.searchBar.field.stringValue = "Riffle"
        SwitcherController.shared.switcherUIQueryChanged("Riffle")
    }

    /// Photographs the panel with only this process's windows composited, and only if nothing but Riffle's windows is listed.
    private static func captureOwnPanel(_ name: String) {
        let items = SwitcherController.shared.session?.items ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard !items.isEmpty, items.allSatisfy({ $0.pid == ownPID }) else {
            report[name] = "skipped: \(items.filter { $0.pid != ownPID }.count) of \(items.count) rows aren't Riffle's"
            Log.warn("diag: \(name) skipped — something other than Riffle matched")
            return
        }
        report[name] = items.map(DiagnosticRecord.row)
        let panel = SwitcherController.shared.ui.panel
        guard let screen = panel.screen,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
        let frame = panel.frame.insetBy(dx: -24, dy: -24)
        // Display-local points, top-left origin.
        let source = CGRect(x: frame.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        let scale = screen.backingScaleFactor
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
            guard let content, let display = content.displays.first(where: { $0.displayID == displayID }) else {
                return Log.warn("diag: \(name): no shareable content (\(error?.localizedDescription ?? "?"))")
            }
            let own = content.windows.filter { $0.owningApplication?.processID == getpid() }
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = source
            configuration.width = Int(source.width * scale)
            configuration.height = Int(source.height * scale)
            configuration.showsCursor = false
            SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, including: own), configuration: configuration) { image, error in
                DispatchQueue.main.async {
                    if let image { write(image, name) } else { Log.warn("diag: \(name) failed: \(error?.localizedDescription ?? "?")") }
                }
            }
        }
    }

    /// Captures Riffle's own frontmost titled window (Settings, welcome) as the WindowServer has that one window, not the
    /// screen where it is: no other app's window, over it or behind its glass, ends up on disk.
    private static func captureOwnWindow(_ name: String) {
        guard let window = WindowStore.shared.ownWindows.first(where: { $0.isKeyWindow }) ?? WindowStore.shared.ownWindows.first,
              let wid = window.cgWindowID else {
            Log.warn("diag: no own window for \(name)")
            return
        }
        guard let image = PrivateAPI.captureWindow(wid) else {
            Log.warn("diag: capture \(name) failed")
            return
        }
        write(image, name)
    }

    private static func write(_ image: CGImage, _ name: String) {
        let url = output.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private static func writeReport() {
        let url = output.appendingPathComponent("report.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
}

/// Mean and spread of luminance: tells a real capture from a blank (all black / all transparent) one.
struct ImageStats {
    let mean: Double
    let deviation: Double

    init(_ image: CGImage) {
        let width = 64, height = 40
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var values = [Double]()
        for index in stride(from: 0, to: pixels.count, by: 4) {
            values.append(0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2]))
        }
        let mean = values.reduce(0, +) / Double(values.count)
        self.mean = (mean * 10).rounded() / 10
        deviation = ((values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot() * 10).rounded() / 10
    }
}
