import Cocoa
import Carbon
import ScreenCaptureKit

/// `Riffle --diag-windows <folder>`: checks every running app the way the switcher sees it and writes what doesn't
/// add up to <folder>/windows.json: real windows Riffle doesn't track (and why), and tracked windows whose thumbnail
/// is missing or blank. Apps are named by bundle identifier, window titles recorded only as lengths, and no image is
/// written: nothing private lands on disk.
enum WindowAudit {
    private static var output = URL(fileURLWithPath: NSTemporaryDirectory())

    static func run(outputDirectory: String) {
        Prefs.persists = false
        Log.echoToStdout = true
        output = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = WindowStore.shared
        store.start {
            // Let AX observers settle, then take the steady-state picture.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                store.rescan {
                    let requests = store.windows.values.map { ThumbnailService.Request(wid: $0.wid, frame: $0.frame, isMinimized: $0.isMinimized) }
                    ThumbnailService.shared.refresh(requests, freshness: 0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { inspect() }
                }
            }
        }
    }

    private static func inspect() {
        let store = WindowStore.shared
        let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var serverWindows = [pid_t: [[String: Any]]]()
        for entry in all {
            guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            serverWindows[pid, default: []].append(entry)
        }
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, _ in
            let listed = Set(content?.windows.map(\.windowID) ?? [])
            DispatchQueue.main.async { write(report(store: store, serverWindows: serverWindows, listed: listed)) }
        }
    }

    private static func report(store: WindowStore, serverWindows: [pid_t: [[String: Any]]], listed: Set<CGWindowID>) -> [String: Any] {
        var apps = [[String: Any]]()
        var problems = [String]()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for running in NSWorkspace.shared.runningApplications where running.processIdentifier != ownPID
            && (running.activationPolicy == .regular || store.apps[running.processIdentifier] != nil) {
            let pid = running.processIdentifier
            let app = DiagnosticRecord.app(running)
            let element = AXUIElementCreateApplication(pid)
            element.setMessagingTimeout(1)
            var raw: CFTypeRef?
            let windowsError = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &raw)
            let axElements: [AXUIElement]
            switch AXReader.windows(ofApp: element) {
            case .windows(let list): axElements = list
            default: axElements = []
            }
            var axByWID = [CGWindowID: AXWindowSnapshot]()
            for axElement in axElements {
                if let snapshot = AXReader.snapshot(of: axElement) { axByWID[snapshot.wid] = snapshot }
            }
            // Real, normal-level, window-sized surfaces the WindowServer has for this app.
            var candidates = [[String: Any]]()
            for entry in serverWindows[pid] ?? [] {
                guard let wid = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                      (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                      bounds.width >= WindowEligibility.minimumSize.width, bounds.height >= WindowEligibility.minimumSize.height else { continue }
                let onScreen = (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
                let tracked = store.windows[wid] != nil
                var row: [String: Any] = ["wid": wid, "bounds": NSStringFromRect(bounds), "onScreen": onScreen, "tracked": tracked,
                                          "alpha": (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                                          "sharing": (entry[kCGWindowSharingState as String] as? NSNumber)?.intValue ?? -1,
                                          "spaces": PrivateAPI.spaces(forWindow: wid)]
                if let snapshot = axByWID[wid] {
                    let description = WindowServerInfo.describe([wid])[wid]
                    row["ax"] = ["role": snapshot.role ?? "-", "subrole": snapshot.subrole ?? "-", "titleLength": snapshot.title.count,
                                 "minimized": snapshot.isMinimized, "main": snapshot.isMain, "fullscreen": snapshot.isFullscreen]
                    row["admitted"] = WindowEligibility.admit(snapshot, description)
                } else {
                    row["ax"] = "not listed by AX"
                }
                if onScreen && !tracked { problems.append("\(app) #\(wid): on screen but not tracked (\(row["ax"] is String ? "AX doesn't list it" : "admitted: \(row["admitted"] ?? "?")"))") }
                candidates.append(row)
            }
            // What the switcher would draw for the windows it does track.
            var thumbnails = [[String: Any]]()
            for window in store.windows.values where window.pid == pid {
                var row: [String: Any] = ["wid": window.wid, "minimized": window.isMinimized, "fullscreen": window.isFullscreen,
                                          "spaces": window.spaceIDs, "listedByScreenCaptureKit": listed.contains(window.wid)]
                if let image = ThumbnailService.shared.image(for: window.wid) {
                    let stats = ImageStats(image)
                    row["thumbnail"] = ["size": "\(image.width)x\(image.height)", "meanLuma": stats.mean, "lumaStdDev": stats.deviation]
                    if stats.deviation < 1.5 { problems.append("\(app) #\(window.wid): thumbnail looks blank (luma \(stats.mean) ± \(stats.deviation))") }
                } else {
                    row["thumbnail"] = "none"
                    problems.append("\(app) #\(window.wid): no thumbnail\(window.isMinimized ? " (minimized)" : "")")
                }
                if let image = PrivateAPI.captureWindow(window.wid) {
                    let stats = ImageStats(image)
                    row["windowServerCapture"] = ["size": "\(image.width)x\(image.height)", "meanLuma": stats.mean, "lumaStdDev": stats.deviation]
                } else {
                    row["windowServerCapture"] = "failed"
                }
                thumbnails.append(row)
            }
            let tracked = store.apps[pid]
            apps.append([
                "pid": pid, "bundleID": running.bundleIdentifier ?? "", "policy": running.activationPolicy.rawValue,
                "hidden": running.isHidden, "tracked": tracked != nil, "observer": tracked?.observer != nil,
                "axWindowsError": windowsError.rawValue, "axWindowCount": axElements.count,
                "windowServerCandidates": candidates, "trackedWindows": thumbnails,
            ])
        }
        return ["problems": problems, "apps": apps, "trackedCount": store.windows.count]
    }

    private static func write(_ report: [String: Any]) {
        let url = output.appendingPathComponent("windows.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url) }
        Log.info("window audit → \(url.path)")
        Log.flush()
        exit(0)
    }
}

/// `Riffle --diag-quit <folder> <app path or bundle id> [arguments…]`: opens an app, quits it the way the switcher's
/// ⌘Q-like action does, and records what the switcher would list at every change notification, to <folder>/quit.json.
/// Once the app is gone, the last list must not contain it.
enum QuitTest {
    private static var timeline = [[String: Any]]()
    private static let start = ProcessInfo.processInfo.systemUptime
    private static func now() -> String { String(format: "%.2f", ProcessInfo.processInfo.systemUptime - start) }

    static func run(outputDirectory: String, app target: String, arguments: [String]) {
        Prefs.persists = false
        Log.echoToStdout = true
        let output = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = WindowStore.shared
        var pid: pid_t = 0
        // The switcher listens to the store too: keep it informed, and record what changed.
        _ = SwitcherController.shared
        let switcherListener = store.onChange
        // Each card on screen must stand for the row the switcher acts on when it's clicked, also while one fades out.
        func misdirectedCards() -> Int {
            guard let session = SwitcherController.shared.session else { return 0 }
            return SwitcherController.shared.ui.tiles.filter { session.items[safe: $0.index]?.id != $0.item.id }.count
        }
        store.onChange = {
            switcherListener?()
            let items = store.items(for: Prefs.shared.profiles[0], screen: NSScreen.main).filter { $0.pid == pid }
            var entry: [String: Any] = ["t": now(), "event": "change notification",
                                        "appItems": items.map { $0.isWindowless ? "app without windows" : "window #\($0.wid ?? 0)" }]
            if SwitcherController.shared.session != nil {
                entry["misdirectedCards"] = misdirectedCards()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    timeline.append(["t": now(), "event": "mid-fade", "misdirectedCards": misdirectedCards()])
                }
            }
            timeline.append(entry)
        }
        store.start {
            let url = target.hasSuffix(".app") ? URL(fileURLWithPath: target) : NSWorkspace.shared.urlForApplication(withBundleIdentifier: target)
            guard let url else { return finish(output, "no such app") }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.arguments = arguments
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                DispatchQueue.main.async {
                    // The error's domain and code: its description would name the app.
                    guard let app else { return finish(output, "didn't open: \((error as NSError?).map { "\($0.domain) \($0.code)" } ?? "?")") }
                    pid = app.processIdentifier
                    timeline.append(["t": now(), "event": "launched"])
                    // With RIFFLE_QUIT_TEST_PANEL set, the real switcher is open while it quits: count its cards for the app.
                    let withPanel = ProcessInfo.processInfo.environment["RIFFLE_QUIT_TEST_PANEL"] != nil
                    func cardsShown() -> Int { SwitcherController.shared.ui.tiles.filter { $0.item.pid == pid }.count }
                    // A moment for Riffle to notice it (and its window, if it opens one), then quit it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if withPanel {
                            SwitcherController.shared.showSticky()
                            timeline.append(["t": now(), "event": "panel open", "cardsForApp": cardsShown()])
                        }
                        // With the panel, quit once it has faded in: cards only animate out of a panel that shows.
                        DispatchQueue.main.asyncAfter(deadline: .now() + (withPanel ? 0.6 : 0)) {
                            timeline.append(["t": now(), "event": "quit requested"])
                            // Exactly what the switcher's quit button and Q key do.
                            WindowStore.shared.markQuitting(pid)
                            WindowActions.quit(pid: pid)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                                let listed = store.items(for: Prefs.shared.profiles[0], screen: NSScreen.main).contains { $0.pid == pid }
                                var entry: [String: Any] = ["t": now(), "event": "4 s later", "terminated": app.isTerminated,
                                                            "listedIfSummonedNow": listed]
                                if withPanel {
                                    entry["cardsStillInOpenPanel"] = cardsShown()
                                    SwitcherController.shared.cancel()
                                }
                                timeline.append(entry)
                                finish(output, nil)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func finish(_ output: URL, _ error: String?) {
        let report: [String: Any] = ["error": error ?? "", "timeline": timeline]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("quit.json"))
        }
        Log.flush()
        exit(0)
    }
}

/// `Riffle --diag-close <folder> <path>`: opens <path> (a folder opens a Finder window), then closes the new window the
/// way the switcher's close button does, and reports whether it really went away, to <folder>/close.json.
enum CloseTest {
    static func run(outputDirectory: String, path: String) {
        Prefs.persists = false
        Log.echoToStdout = true
        let output = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = WindowStore.shared
        var report = [String: Any]()
        func finish() {
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("close.json"))
            }
            Log.flush()
            exit(0)
        }
        store.start {
            let before = Set(store.windows.keys)
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            func waitForWindow(_ attempt: Int) {
                if let window = store.windows.values.first(where: { !before.contains($0.wid) }) {
                    report["window"] = "\(DiagnosticRecord.app(window.app, pid: window.pid)) #\(window.wid) frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid)"
                    // Look at the close button and press it directly, recording every answer.
                    let button = window.element?.element(kAXCloseButtonAttribute)
                    report["hasCloseButton"] = button != nil
                    if let button {
                        var names: CFArray?
                        AXUIElementCopyActionNames(button, &names)
                        report["buttonActions"] = (names as? [String]) ?? []
                        report["buttonRole"] = button.string(kAXRoleAttribute) ?? "-"
                        report["buttonSubrole"] = button.string(kAXSubroleAttribute) ?? "-"
                        report["buttonEnabled"] = button.bool(kAXEnabledAttribute).map { "\($0)" } ?? "-"
                    }
                    // Exactly the switcher's close; then up to 3 s for it to leave the screen (Finder animates out).
                    WindowActions.close(window.element, isFullscreen: window.isFullscreen)
                    func check(_ tries: Int) {
                        let description = WindowServerInfo.describe([window.wid])[window.wid]
                        if description == nil || description?.isOnScreen == false {
                            report["closedAfterSeconds"] = Double(tries) * 0.25
                            return finish()
                        }
                        guard tries < 12 else {
                            report["closedAfterSeconds"] = "still open after 3 s"
                            return finish()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { check(tries + 1) }
                    }
                    check(0)
                    return
                }
                guard attempt < 20 else {
                    report["error"] = "the new window never got tracked"
                    return finish()
                }
                if attempt % 4 == 3 { store.rescan() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { waitForWindow(attempt + 1) }
            }
            waitForWindow(0)
        }
    }
}

/// `Riffle --diag-ax <folder>`: opens the switcher and reads it back the way VoiceOver does, through the accessibility API
/// from another thread (the main thread has to stay free to answer): every card must be a button with a spoken label and
/// a press action. Writes <folder>/ax.json; window titles are kept only as their length.
enum AccessibilityAudit {
    static func run(outputDirectory: String) {
        Prefs.persists = false
        Log.echoToStdout = true
        let output = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        WindowStore.shared.start {
            SwitcherController.shared.showSticky()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let expected = SwitcherController.shared.ui.tiles.count
                DispatchQueue.global(qos: .userInitiated).async {
                    var report = read()
                    report["cardsOnScreen"] = expected
                    DispatchQueue.main.async {
                        SwitcherController.shared.cancel()
                        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                            try? data.write(to: output.appendingPathComponent("ax.json"))
                        }
                        Log.flush()
                        exit(0)
                    }
                }
            }
        }
    }

    private static func read() -> [String: Any] {
        let app = AXUIElementCreateApplication(getpid())
        app.setMessagingTimeout(2)
        guard let panel = app.elements(kAXWindowsAttribute).first(where: { $0.string(kAXTitleAttribute) == "Riffle" }) else {
            return ["error": "the switcher panel isn't in the app's accessibility windows"]
        }
        var cards = [[String: Any]]()
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 14 else { return }
            if element.string(kAXRoleAttribute) == kAXButtonRole {
                var names: CFArray?
                AXUIElementCopyActionNames(element, &names)
                let label = element.string(kAXDescriptionAttribute) ?? element.string(kAXTitleAttribute) ?? ""
                cards.append(["labelLength": label.count, "labelParts": label.components(separatedBy: ", ").count,
                              "actions": (names as? [String]) ?? []])
            }
            for child in element.elements(kAXChildrenAttribute) { walk(child, depth: depth + 1) }
        }
        walk(panel, depth: 0)
        let pressable = cards.filter { ($0["actions"] as? [String])?.contains(kAXPressAction) == true }
        let labelled = cards.filter { ($0["labelLength"] as? Int ?? 0) > 0 }
        return ["panelTitle": panel.string(kAXTitleAttribute) ?? "", "buttons": cards.count, "pressable": pressable.count,
                "labelled": labelled.count, "cards": cards]
    }
}

/// `Riffle --diag-shortcuts <folder>`: registers nine shortcuts at once, the way Settings has them registered, on keys
/// nothing else uses (⌃⌥ with F12…F20), then again with the ninth repeating the first one's keys, and reports what
/// registered and what was flagged, to <folder>/shortcuts.json. The test's shortcuts are never saved, and the system's
/// own ⌘⇥ is left as it is.
enum ShortcutTest {
    static func run(outputDirectory: String) {
        Log.echoToStdout = true
        let output = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        Prefs.persists = false
        let prefs = Prefs.shared
        prefs.shortcutsPaused = false
        let keys = [kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20].map(UInt32.init)
        func profiles(_ keys: [UInt32]) -> [ShortcutProfile] {
            keys.enumerated().map { index, key in
                ShortcutProfile(id: index, isEnabled: true, holdModifiers: [.control, .option], keyCode: key, scope: .allWindows,
                                showMinimized: true, showHidden: true, showWindowlessApps: false, startInSearch: false)
            }
        }
        var report = [String: Any]()
        func attempt(_ name: String, _ list: [ShortcutProfile]) {
            prefs.profiles = list
            (NSApp.delegate as? AppDelegate)?.registerHotkeys(managesNativeSwitcher: false)
            report[name] = ["profiles": list.count, "registered": HotkeyCenter.shared.registrationCount,
                            "failures": ShortcutStatus.shared.failures.keys.sorted(), "duplicates": ShortcutStatus.shared.duplicates.sorted()]
            HotkeyCenter.shared.unregisterAll()
        }
        attempt("nineDistinct", profiles(keys))
        attempt("ninthRepeatsFirst", profiles(Array(keys.prefix(8)) + [keys[0]]))
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("shortcuts.json"))
        }
        Log.flush()
        exit(0)
    }
}

/// `Riffle --diag-notch <folder>`: opens the switcher on the current screen (meant to be run with a full-screen app in
/// front, when the menu bar is hidden) and reports where the panel sits against the camera housing, to notch.json.
enum NotchTest {
    static func run(outputDirectory: String) {
        Prefs.persists = false
        Log.echoToStdout = true
        let output = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        WindowStore.shared.start {
            SwitcherController.shared.showSticky()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let panel = SwitcherController.shared.ui.panel
                let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
                let ceiling = screen.frame.maxY - screen.safeAreaInsets.top
                let report: [String: Any] = [
                    "screen": NSStringFromRect(screen.frame), "visibleFrame": NSStringFromRect(screen.visibleFrame),
                    "notchHeight": screen.safeAreaInsets.top, "menuBarHidden": screen.visibleFrame.maxY >= screen.frame.maxY - 1,
                    "usable": NSStringFromRect(SwitcherUI.usableFrame(of: screen)), "panel": NSStringFromRect(panel.frame),
                    "panelTopBelowNotch": panel.frame.maxY <= ceiling, "clearance": ceiling - panel.frame.maxY,
                    "cards": SwitcherController.shared.ui.tiles.count,
                ]
                SwitcherController.shared.cancel()
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: output.appendingPathComponent("notch.json"))
                }
                Log.flush()
                exit(0)
            }
        }
    }
}
