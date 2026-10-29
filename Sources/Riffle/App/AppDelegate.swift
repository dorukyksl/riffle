import Carbon
import Cocoa
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let diagnosticsDirectory: String?
    private var statusItem: NSStatusItem?
    private var statusMenuIsOpen = false
    private var cancellables = Set<AnyCancellable>()
    /// Riffle can switch: Accessibility is there, and the window list, the event tap and the shortcuts run.
    private var engineStarted = false
    private let nativeCommandTab = NativeCommandTab()
    /// Shortcuts another app already owns, by profile id.
    private(set) var hotkeyFailures = [Int: OSStatus]()

    init(diagnosticsDirectory: String?) {
        self.diagnosticsDirectory = diagnosticsDirectory
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--diag-close") {
            CloseTest.run(outputDirectory: CommandLine.arguments[safe: index + 1] ?? NSTemporaryDirectory() + "riffle-close",
                          path: CommandLine.arguments[safe: index + 2] ?? NSTemporaryDirectory())
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--diag-quit") {
            QuitTest.run(outputDirectory: CommandLine.arguments[safe: index + 1] ?? NSTemporaryDirectory() + "riffle-quit",
                         app: CommandLine.arguments[safe: index + 2] ?? "com.apple.calculator",
                         arguments: Array(CommandLine.arguments.dropFirst(index + 3)))
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--diag-languages") {
            let rest = Array(CommandLine.arguments.dropFirst(index + 1))
            LanguageAudit.run(outputDirectory: rest.first ?? NSTemporaryDirectory() + "riffle-languages", codes: Array(rest.dropFirst()))
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--diag-notch") {
            NotchTest.run(outputDirectory: CommandLine.arguments[safe: index + 1] ?? NSTemporaryDirectory() + "riffle-notch")
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--diag-shortcut-editing") {
            ShortcutEditingTest.run(outputDirectory: CommandLine.arguments[safe: index + 1] ?? NSTemporaryDirectory() + "riffle-shortcut-editing")
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--diag-shortcuts") {
            ShortcutTest.run(outputDirectory: CommandLine.arguments[safe: index + 1] ?? NSTemporaryDirectory() + "riffle-shortcuts")
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--diag-ax") {
            AccessibilityAudit.run(outputDirectory: CommandLine.arguments[safe: index + 1] ?? NSTemporaryDirectory() + "riffle-ax")
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--diag-windows") {
            WindowAudit.run(outputDirectory: CommandLine.arguments[safe: index + 1] ?? NSTemporaryDirectory() + "riffle-windows")
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--diag-glass") {
            Diagnostics.runGlass(outputDirectory: CommandLine.arguments[safe: index + 1] ?? NSTemporaryDirectory() + "riffle-glass")
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--e2e-spaces") {
            EndToEnd.runSpaces(outputDirectory: CommandLine.arguments[safe: index + 1] ?? NSTemporaryDirectory() + "riffle-e2e-spaces")
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--e2e") {
            EndToEnd.run(outputDirectory: CommandLine.arguments[safe: index + 1] ?? NSTemporaryDirectory() + "riffle-e2e")
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--site-images") {
            let windows = CommandLine.arguments.firstIndex(of: "--windows").flatMap { CommandLine.arguments[safe: $0 + 1] }
            SiteRender.run(outputDirectory: CommandLine.arguments[safe: index + 1] ?? NSTemporaryDirectory() + "riffle-site", windows: windows)
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--mock") {
            MockRender.run(outputDirectory: CommandLine.arguments[safe: index + 1] ?? NSTemporaryDirectory() + "riffle-mock")
            return
        }
        if let diagnosticsDirectory {
            Diagnostics.run(outputDirectory: diagnosticsDirectory)
            return
        }
        guard SingleInstance.acquire() else {
            DistributedNotificationCenter.default().postNotificationName(.riffleShowSettings, object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(openSettings), name: .riffleShowSettings, object: nil)
        CrashGuard.install()
        // `pkill`, logout, ⌃C in a terminal, a closed terminal: quit through AppKit so cleanup (restoring ⌘⇥) still runs;
        // if the main thread is stuck, the crash guard gives ⌘⇥ back and ends the process.
        CrashGuard.handleTerminationSignals { DispatchQueue.main.async { NSApp.terminate(nil) } }
        Log.info("Riffle \(AppInfo.version) (\(AppInfo.build)) starting — AX: \(Permissions.accessibility), screen: \(Permissions.screenRecording), login item: \(LoginItem.isEnabled)")
        repairNativeCommandTab()
        installMainMenu()
        LoginItem.restoreIfWanted()
        let permissions = PermissionMonitor.shared
        permissions.onChange = { [weak self] effects in self?.permissionsChanged(effects) }
        updateStatusItem()
        observePrefs()
        registerHotkeys()
        // Without Accessibility the engine waits; the monitor starts it the moment it's given.
        if permissions.tracker.accessibility == .granted { startEngine() }
        permissions.start()
        // Previews are optional: once they were declined, neither the welcome window nor the system asks for them again.
        let prefs = Prefs.shared
        if OnboardingWindow.isNeeded(accessibility: Permissions.accessibility, screenRecording: Permissions.screenRecording,
                                     completed: prefs.hasCompletedOnboarding, withoutPreviews: prefs.continuesWithoutPreviews) {
            OnboardingWindow.shared.show()
        }
        // Put Riffle on the Screen Recording list right away, so it can simply be switched on there.
        if !Permissions.screenRecording && !prefs.continuesWithoutPreviews { Permissions.requestScreenRecording() }
        Updates.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if nativeCommandTab.ownsCommandTab { restoreNativeCommandTab() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    // MARK: - Engine

    private func startEngine() {
        guard !engineStarted else { return }
        engineStarted = true
        // Now Riffle can actually switch: it may take over ⌘⇥.
        registerHotkeys()
        let switcher = SwitcherController.shared
        _ = switcher
        ModifierMonitor.shared.installEventTapIfPossible()
        let store = WindowStore.shared
        // Accessibility is back after being taken away: everything else is in place, but AX starts afresh.
        guard !store.isStarted else { return store.reattachObservers() }
        store.onWindowRemoved = { ThumbnailService.shared.evict($0) }
        ThumbnailService.shared.isTracked = { wid in WindowStore.shared.windows[wid] != nil || WindowStore.shared.ownWindow(wid) != nil }
        // A new window isn't in ScreenCaptureKit's list yet: look again on its first capture.
        store.onWindowAdded = { _ in ThumbnailService.shared.invalidateShareableContent() }
        store.onWindowLostFocus = { wid in
            // The window you just left is the one most likely to have changed: refresh its thumbnail quietly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // Not for windows that just went off screen (minimized, app hidden): their last picture is the good one.
                guard let window = WindowStore.shared.windows[wid], !SwitcherController.shared.isActive, !window.isMinimized,
                      window.app?.isHidden != true else { return }
                ThumbnailService.shared.refresh([.init(wid: wid, frame: window.frame, isMinimized: false)], freshness: 1.5, priority: .background)
            }
        }
        store.start {
            Log.info("first scan: \(store.windows.count) windows in \(String(format: "%.0f", store.lastScanDuration * 1000)) ms")
            // Warm the thumbnail cache so the very first summon already shows real previews.
            let requests = store.windows.values.sorted { $0.focusStamp > $1.focusStamp }
                .map { ThumbnailService.Request(wid: $0.wid, frame: $0.frame, isMinimized: $0.isMinimized, isHidden: $0.app?.isHidden ?? false) }
            ThumbnailService.shared.refresh(requests, freshness: 0, priority: .background)
        }
    }

    /// Accessibility was taken away: no switcher (a summon shows the welcome window instead), no event tap, and ⌘⇥ back to
    /// macOS until it's back. The window list stays as it was: its AX reads now fail at once and keep what they knew.
    private func stopEngine() {
        guard engineStarted else { return }
        engineStarted = false
        SwitcherController.shared.cancel()
        ModifierMonitor.shared.removeEventTap()
        registerHotkeys()
    }

    /// Screen Recording was taken away: captures stop by themselves (`ThumbnailService.isAvailable`), and the previews
    /// taken before go too, so no picture outlives the permission. Cards show app icons instead.
    private func stopPreviews() {
        let store = WindowStore.shared
        for wid in Array(store.windows.keys) + store.ownWindows.compactMap(\.cgWindowID) { ThumbnailService.shared.evict(wid) }
    }

    private func permissionsChanged(_ effects: [PermissionTracker.Effect]) {
        for effect in effects {
            switch effect {
            case .startEngine:
                Log.info("accessibility granted")
                startEngine()
            case .stopEngine:
                Log.warn("accessibility was taken away: switching stops until it's back")
                stopEngine()
            case .stopPreviews:
                Log.warn("screen recording was taken away: previews stop")
                stopPreviews()
            case .offerRestart:
                Log.info("screen recording granted: previews start after a restart")
            }
        }
        updateStatusItem()
    }

    // MARK: - Shortcuts

    /// `managesNativeSwitcher`: false only for the shortcut test, which must leave the system's ⌘⇥ alone.
    func registerHotkeys(managesNativeSwitcher: Bool = true) {
        HotkeyCenter.shared.unregisterAll()
        // A key recorder in Settings is listening: the shortcuts come back once it's done (`KeyRecording`).
        guard !KeyRecording.shared.isRecording else { return }
        // An app that wants these keys for itself is in front (Exceptions: a virtual machine, a remote desktop): let go
        // of them until it isn't. macOS's own ⌘⇥ is never switched back on meanwhile, so that keystroke reaches it too.
        if managesNativeSwitcher, ShortcutSuspension.shared.isSuspended {
            if engineStarted, !Prefs.shared.shortcutsPaused, Prefs.shared.profiles.contains(where: { $0.isEnabled && $0.usesCommandTab }) {
                updateNativeCommandTab(holdsCommandTab: true)
            }
            return
        }
        hotkeyFailures = [:]
        var duplicates = Set<Int>()
        defer {
            ShortcutStatus.shared.failures = hotkeyFailures
            ShortcutStatus.shared.duplicates = duplicates
        }
        guard !Prefs.shared.shortcutsPaused else {
            if managesNativeSwitcher { updateNativeCommandTab(holdsCommandTab: false) }
            return
        }
        var holdsCommandTab = false
        // The session remembers which hold started it, to notice its release.
        var registered = [String: Int]() // keystroke → the profile that has it
        func register(_ index: Int, _ profile: ShortcutProfile, modifiers: CarbonModifiers, hold: CarbonModifiers, reverse: Bool) {
            let keystroke = "\(profile.keyCode)-\(modifiers.rawValue)"
            if let owner = registered[keystroke] {
                // Another of Riffle's shortcuts (or its ⇧ variant) on the same keystroke: the earlier one keeps it.
                if owner != profile.id, !reverse { duplicates.insert(profile.id) }
                return
            }
            registered[keystroke] = profile.id
            let status = HotkeyCenter.shared.register(
                keyCode: profile.keyCode, modifiers: modifiers,
                onPress: { [weak self] in self?.summon(index, reverse: reverse, hold: hold) },
                onRelease: { SwitcherController.shared.hotkeyReleased() })
            if status != noErr && !reverse { hotkeyFailures[profile.id] = status }
            if status == noErr, !reverse, profile.keyCode == KeyCodes.tab, modifiers.contains(.command) { holdsCommandTab = true }
        }
        for (index, profile) in Prefs.shared.profiles.enumerated() where profile.isEnabled {
            let hold = profile.holdModifiers
            register(index, profile, modifiers: hold, hold: hold, reverse: false)
            // Adding ⇧ walks backwards.
            if !hold.contains(.shift) {
                register(index, profile, modifiers: hold.union(.shift), hold: hold, reverse: true)
            }
        }
        if managesNativeSwitcher { updateNativeCommandTab(holdsCommandTab: holdsCommandTab) }
    }

    private func summon(_ index: Int, reverse: Bool, hold: CarbonModifiers) {
        // Accessibility may have been taken away since the last look: never start AX work without it.
        guard canSwitch else {
            OnboardingWindow.shared.show()
            return
        }
        SwitcherController.shared.hotkeyPressed(profileIndex: index, reverse: reverse, hold: hold)
    }

    /// ⌘⇥ is consumed by the Dock before any app hears it, so when a shortcut uses it the native switcher is switched
    /// off — but only once Riffle can really switch (its engine runs, the shortcut registered), and it's switched back
    /// on when Riffle quits or the shortcut changes.
    private func updateNativeCommandTab(holdsCommandTab: Bool) {
        if holdsCommandTab && engineStarted {
            nativeCommandTab.takeOver()
            Log.info("took over ⌘⇥ (native switcher enabled: \(PrivateAPI.isSymbolicHotKeyEnabled(.commandTab).map(String.init) ?? "?"))")
        } else {
            restoreNativeCommandTab()
        }
    }

    private func restoreNativeCommandTab() {
        switch nativeCommandTab.giveBack() {
        case .switchedOn: Log.info("gave ⌘⇥ back to macOS")
        case .stillOff: Log.error("couldn't give ⌘⇥ back to macOS: the next launch tries again")
        case .notOurs, .alreadyOn: break
        }
    }

    /// A Riffle that went down with ⌘⇥ off in a way the crash guard can't catch (SIGKILL, a power cut) left the record of
    /// it behind. Done before anything registers a shortcut, and never by a second copy, which quits before getting here.
    private func repairNativeCommandTab() {
        switch nativeCommandTab.repairAtLaunch() {
        case .switchedOn: Log.info("⌘⇥ was left off by an earlier run: switched it back on")
        case .stillOff: Log.error("⌘⇥ was left off by an earlier run and couldn't be switched back on")
        case .notOurs, .alreadyOn: break
        }
    }

    // MARK: - Preferences

    private func observePrefs() {
        let prefs = Prefs.shared
        // @Published fires before the new value is stored: hop once so readers see it.
        prefs.$profiles.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.registerHotkeys() } }.store(in: &cancellables)
        prefs.$shortcutsPaused.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.registerHotkeys()
                self?.updateStatusItem()
            }
        }.store(in: &cancellables)
        prefs.$showMenuBarIcon.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusItem() } }.store(in: &cancellables)
        prefs.$language.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusItem()
                SettingsWindow.shared.updateTitle()
                OnboardingWindow.shared.updateTitle()
            }
        }.store(in: &cancellables)
    }

    // MARK: - Menus

    private func installMainMenu() {
        // Riffle has no menu bar of its own, but key equivalents (⌘C/⌘V in text fields, ⌘W) need these.
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L.t("Riffle'dan Çık", "Quit Riffle"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    private func updateStatusItem() {
        let needsAccessibility = PermissionMonitor.shared.tracker.needsAccessibility
        // Hidden on purpose, it still shows while Riffle can't switch: nothing else would say why.
        guard Prefs.shared.showMenuBarIcon || needsAccessibility else {
            // Not while its menu is open: that happens once it closes.
            guard !statusMenuIsOpen else { return }
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        let paused = Prefs.shared.shortcutsPaused
        let symbol = needsAccessibility ? "exclamationmark.triangle" : paused ? "square.on.square.dashed" : "square.on.square"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Riffle")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = needsAccessibility ? L.t("Riffle'ın Erişilebilirlik iznine ihtiyacı var", "Riffle needs Accessibility") : "Riffle"
        // One menu, filled each time it opens: this runs while it's open too (a permission can change meanwhile).
        if item.menu == nil {
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        statusMenuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        statusMenuIsOpen = false
        DispatchQueue.main.async { self.updateStatusItem() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // A new version a check in the background found: offered here rather than in a window over someone's work.
        if let version = Updates.shared.waiting {
            let update = NSMenuItem(title: L.t("Güncelleme Mevcut…", "Update Available…"), action: #selector(checkForUpdates), keyEquivalent: "")
            update.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            update.subtitle = "Riffle " + version
            menu.addItem(update)
            menu.addItem(.separator())
        }
        let permissions = PermissionMonitor.shared.check()
        if permissions.needsAccessibility {
            let grant = NSMenuItem(title: L.t("Erişilebilirlik İzni Ver…", "Grant Accessibility…"), action: #selector(grantAccessibility), keyEquivalent: "")
            grant.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            grant.subtitle = L.t("Riffle bu izin olmadan pencere değiştiremez", "Riffle can't switch windows without it")
            menu.addItem(grant)
        }
        if permissions.needsRestart {
            let restart = NSMenuItem(title: L.t("Riffle'ı Yeniden Başlat", "Restart Riffle"), action: #selector(restart), keyEquivalent: "")
            restart.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
            restart.subtitle = PermissionText.restartForPreviews
            menu.addItem(restart)
        }
        if permissions.needsAccessibility || permissions.needsRestart { menu.addItem(.separator()) }
        let shortcut = Prefs.shared.profiles.first?.description ?? "⌥⇥"
        let show = NSMenuItem(title: L.t("Pencereleri Göster", "Show Windows") + "  (\(shortcut))", action: #selector(showSwitcher), keyEquivalent: "")
        menu.addItem(show)
        menu.addItem(NSMenuItem(title: L.t("Pencerelerde Ara…", "Search Windows…"), action: #selector(showSearch), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L.t("Ayarlar…", "Settings…"), action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: L.t("İzinler ve Kurulum…", "Permissions & Setup…"), action: #selector(openOnboarding), keyEquivalent: ""))
        let paused = Prefs.shared.shortcutsPaused
        menu.addItem(NSMenuItem(title: paused ? L.t("Kısayolları Sürdür", "Resume Shortcuts") : L.t("Kısayolları Duraklat", "Pause Shortcuts"),
                                action: #selector(togglePause), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L.t("Riffle Hakkında", "About Riffle"), action: #selector(openAbout), keyEquivalent: ""))
        if Updates.shared.isAvailable {
            menu.addItem(NSMenuItem(title: UpdateText.check, action: #selector(checkForUpdates), keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem(title: L.t("Riffle'dan Çık", "Quit Riffle"), action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // Not while a check or an installation is already under way.
        item.action == #selector(checkForUpdates) ? Updates.shared.canCheck : true
    }

    /// The engine runs, and Accessibility is still there right now.
    private var canSwitch: Bool {
        PermissionMonitor.shared.check().accessibility == .granted && engineStarted
    }

    @objc private func showSwitcher() {
        DispatchQueue.main.async { self.canSwitch ? SwitcherController.shared.showSticky() : OnboardingWindow.shared.show() }
    }

    @objc private func showSearch() {
        DispatchQueue.main.async { self.canSwitch ? SwitcherController.shared.showSticky(searching: true) : OnboardingWindow.shared.show() }
    }

    @objc private func grantAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    }

    @objc private func restart() {
        Relauncher.relaunch()
    }

    @objc func openSettings() {
        SettingsWindow.shared.show()
    }

    @objc private func openOnboarding() {
        OnboardingWindow.shared.show()
    }

    @objc private func openAbout() {
        SettingsWindow.shared.show(section: .about)
    }

    @objc private func checkForUpdates() {
        Updates.shared.check()
    }

    @objc private func togglePause() {
        Prefs.shared.shortcutsPaused.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
