import Carbon
import Cocoa

/// `Riffle --e2e <folder>`: drives the *running* Riffle like a person would. It posts a real ⌥⇥ through the HID
/// system, holds ⌥, releases it, and checks that focus moved to the previous window; then a quick ⌥⇥ tap must
/// bring focus straight back. Results go to <folder>/e2e.json, naming apps by bundle identifier and no window by its title.
enum EndToEnd {
    private static var output = URL(fileURLWithPath: NSTemporaryDirectory())
    private static var report = [String: Any]()
    private static let source = CGEventSource(stateID: .hidSystemState)

    static func run(outputDirectory: String) {
        // Read only, but never saved either: the running Riffle owns the settings.
        Prefs.persists = false
        Log.echoToStdout = true
        output = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard Permissions.accessibility else {
            finish("no accessibility permission")
            return
        }
        let before = focused()
        report["before"] = before.description
        let profile = Prefs.shared.profiles[0]
        // Synthetic events skip the Modifier Keys remapping, so post what macOS would send for the physical keys.
        let sent = profile.holdModifiers
        let (holdKey, holdFlags) = sent.contains(.command) ? (kVK_Command, CGEventFlags.maskCommand)
            : sent.contains(.control) ? (kVK_Control, CGEventFlags.maskControl) : (kVK_Option, CGEventFlags.maskAlternate)
        report["sentModifiers"] = sent.symbols
        report["shortcut"] = profile.description
        Log.info("e2e: before = \(before.description), shortcut \(profile.description)")
        // 1. Hold the modifier, press ⇥ once, wait so the panel appears, release.
        post(holdKey, down: true, flags: holdFlags)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            report["nativeCommandTabEnabled"] = PrivateAPI.isSymbolicHotKeyEnabled(.commandTab).map { $0 } ?? "?"

            tap(kVK_Tab, flags: holdFlags)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                report["panelShown"] = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                    .map { ($0 as? [[String: Any]] ?? []).contains { ($0[kCGWindowOwnerName as String] as? String) == "Riffle" && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 } } ?? false
                post(holdKey, down: false, flags: [])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    let afterSwitch = focused()
                    report["afterSwitch"] = afterSwitch.description
                    report["switched"] = afterSwitch.wid != before.wid && afterSwitch.wid != 0
                    Log.info("e2e: after \(profile.description) = \(afterSwitch.description)")
                    // 2. A quick tap must bring us straight back, without showing the panel.
                    post(holdKey, down: true, flags: holdFlags)
                    tap(kVK_Tab, flags: holdFlags)
                    post(holdKey, down: false, flags: [])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        let afterTap = focused()
                        report["afterQuickTap"] = afterTap.description
                        report["returned"] = afterTap.wid == before.wid
                        Log.info("e2e: after quick tap = \(afterTap.description)")
                        finish(nil)
                    }
                }
            }
        }
    }

    // MARK: - Spaces, fullscreen and minimized windows

    private static var crossSpaceTarget: TrackedWindow?

    /// `Riffle --e2e-spaces <folder>`: run while the RiffleTestWindows helper shows a normal, a minimized and a
    /// fullscreen window (which macOS moves to its own Space, so the user's windows end up on a Space not shown).
    static func runSpaces(outputDirectory: String) {
        Prefs.persists = false
        Log.echoToStdout = true
        output = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        WindowStore.shared.start { waitForTestWindows(attempt: 0) }
    }

    private static func testWindows() -> [TrackedWindow] {
        WindowStore.shared.windows.values.filter { $0.title.hasPrefix("Riffle Test") }
    }

    private static func isOnVisibleSpace(_ window: TrackedWindow) -> Bool {
        window.spaceIDs.contains(where: WindowStore.shared.topology.visibleSpaceIDs.contains)
    }

    private static func describe(_ window: TrackedWindow) -> [String: Any] {
        [
            "app": DiagnosticRecord.app(window.app, pid: window.pid), "wid": window.wid,
            "testWindow": window.title.hasPrefix("Riffle Test"), "titleLength": window.title.count,
            "minimized": window.isMinimized, "fullscreen": window.isFullscreen,
            "onVisibleSpace": isOnVisibleSpace(window), "spaceCount": window.spaceIDs.count, "hasElement": window.element != nil,
        ]
    }

    private static func waitForTestWindows(attempt: Int) {
        if testWindows().count >= 3 || attempt >= 10 {
            inspectSpaces()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            WindowStore.shared.rescan { waitForTestWindows(attempt: attempt + 1) }
        }
    }

    private static func inspectSpaces() {
        let store = WindowStore.shared
        report["spaces"] = store.topology.spaces.map { DiagnosticRecord.space($0, in: store.topology) }
        report["testWindows"] = testWindows().map(describe)
        let userWindows = store.windows.values.filter { !$0.title.hasPrefix("Riffle Test") }
        report["userWindows"] = userWindows.map(describe)
        report["items"] = store.items(for: Prefs.shared.profiles[0], screen: NSScreen.main).map {
            "\(DiagnosticRecord.row($0)) | minimized=\($0.isMinimized) fullscreen=\($0.isFullscreen) space=\($0.otherSpaceIndex.map(String.init) ?? "-")"
        }
        guard let target = userWindows.first(where: { !$0.isMinimized && !isOnVisibleSpace($0) }) ?? userWindows.first else {
            finish("no user window")
            return
        }
        crossSpaceTarget = target
        Log.info("e2e-spaces: focusing \(Log.app(target.app?.bundleID, pid: target.pid)) across Spaces")
        WindowActions.focus(.init(wid: target.wid, pid: target.pid, element: target.element, isMinimized: false, spaceIDs: target.spaceIDs))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { verifyCrossSpace() }
    }

    private static func verifyCrossSpace() {
        guard let target = crossSpaceTarget else { return }
        report["crossSpaceFocus"] = ["app": DiagnosticRecord.app(target.app, pid: target.pid), "ok": focused().wid == target.wid]
        WindowStore.shared.rescan {
            report["testWindowsAfterReturn"] = testWindows().map(describe)
            guard let minimized = testWindows().first(where: { $0.title.contains("Küçültülmüş") }) else {
                finish("no minimized test window")
                return
            }
            Log.info("e2e-spaces: focusing the minimized window")
            WindowActions.focus(.init(wid: minimized.wid, pid: minimized.pid, element: minimized.element,
                                      isMinimized: minimized.isMinimized, spaceIDs: minimized.spaceIDs))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                let stillMinimized = minimized.element?.bool(kAXMinimizedAttribute) ?? true
                report["minimizedFocus"] = ["ok": focused().wid == minimized.wid, "restored": !stillMinimized]
                guard let fullscreen = testWindows().first(where: { $0.title.contains("Tam Ekran") }) else {
                    finish("no fullscreen test window")
                    return
                }
                Log.info("e2e-spaces: focusing the fullscreen window on its own Space")
                WindowActions.focus(.init(wid: fullscreen.wid, pid: fullscreen.pid, element: fullscreen.element,
                                          isMinimized: false, spaceIDs: fullscreen.spaceIDs))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    report["fullscreenFocus"] = ["ok": focused().wid == fullscreen.wid]
                    // Back to where the user was.
                    WindowActions.focus(.init(wid: target.wid, pid: target.pid, element: target.element, isMinimized: false, spaceIDs: target.spaceIDs))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        report["returnedToUser"] = focused().wid == target.wid
                        finish(nil)
                    }
                }
            }
        }
    }

    private struct Focus: CustomStringConvertible {
        let app: String
        let wid: CGWindowID
        var description: String { "\(app) #\(wid)" }
    }

    private static func focused() -> Focus {
        guard let front = NSWorkspace.shared.frontmostApplication else { return Focus(app: "?", wid: 0) }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        let wid = AXReader.focusedWindow(ofApp: app)?.windowID ?? 0
        return Focus(app: Log.app(front), wid: wid)
    }

    private static func post(_ key: Int, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private static func tap(_ key: Int, flags: CGEventFlags) {
        post(key, down: true, flags: flags)
        post(key, down: false, flags: flags)
    }

    private static func finish(_ error: String?) {
        if let error { report["error"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("e2e.json"))
        }
        Log.flush()
        exit(0)
    }
}
