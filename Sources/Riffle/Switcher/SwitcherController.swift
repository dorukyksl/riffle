import Carbon
import Cocoa

/// What can be done to the selected window from inside the switcher.
enum SwitcherAction { case close, minimize, fullscreen, hide, quit }

/// State of one summon of the switcher, from the first ⌥⇥ until a window is chosen or the switcher is dismissed.
final class SwitcherSession {
    let profile: ShortcutProfile
    let screen: NSScreen
    /// Every row for this shortcut, in the order shown when not searching.
    var allItems: [SwitcherItem]
    /// The rows on screen (search results while searching).
    var items: [SwitcherItem]
    var selectedIndex = 0
    var query = ""
    var isSearching: Bool
    /// A sticky session stays open after the modifiers are released (search, or opened from the menu bar).
    var isSticky: Bool
    var revealWork: DispatchWorkItem?
    let startedAt = ProcessInfo.processInfo.systemUptime
    /// The modifiers macOS reported for the keystroke that opened this session; letting go of them chooses.
    let hold: NSEvent.ModifierFlags
    /// In a sticky session (search) the hold key was let go: from then on ⌘V is paste again, not a "v".
    var holdReleased = false
    /// The active app and the app under the pointer as they were when it began: its list keeps showing theirs.
    var anchor: WindowFilter.Anchor?

    init(profile: ShortcutProfile, hold: CarbonModifiers, items: [SwitcherItem], screen: NSScreen, searching: Bool, sticky: Bool) {
        self.profile = profile
        self.hold = hold.eventFlags
        self.screen = screen
        allItems = items
        self.items = items
        isSearching = searching
        isSticky = sticky || searching
    }

    var selectedItem: SwitcherItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }
}

final class SwitcherController: NSObject, SwitcherUIDelegate {
    static let shared = SwitcherController()

    let ui = SwitcherUI()
    private(set) var session: SwitcherSession?
    private let preview = PreviewOverlay()
    private var keyMonitor: Any?
    private var repeatTimer: Timer?
    private var liveTimer: Timer?
    private var presentedSignature = ""

    private override init() {
        super.init()
        ui.delegate = self
        ModifierMonitor.shared.onChange = { [weak self] in self?.modifiersChanged() }
        WindowStore.shared.onChange = { [weak self] in self?.storeChanged() }
        ThumbnailService.shared.addListener { [weak self] wid in
            self?.ui.updateThumbnail(wid)
            self?.preview.thumbnailUpdated(wid)
        }
    }

    var isActive: Bool { session != nil }

    // MARK: - Entry points

    func hotkeyPressed(profileIndex: Int, reverse: Bool, hold: CarbonModifiers) {
        let profiles = Prefs.shared.profiles
        guard profiles.indices.contains(profileIndex), profiles[profileIndex].isEnabled else { return }
        let profile = profiles[profileIndex]
        if let session, session.profile.id == profile.id {
            step(reverse ? -1 : 1)
        } else {
            begin(profile, hold: hold, reverse: reverse)
        }
        if session != nil { startRepeat(reverse: reverse) }
    }

    func hotkeyReleased() {
        stopRepeat()
    }

    /// Opens a switcher that stays up until a choice is made (menu bar, or a search-first shortcut).
    func showSticky(searching: Bool = false) {
        guard let profile = Prefs.shared.profiles.first else { return }
        begin(profile, hold: profile.holdModifiers, reverse: false, sticky: true, searching: searching)
    }

    func begin(_ profile: ShortcutProfile, hold: CarbonModifiers, reverse: Bool, sticky: Bool = false, searching: Bool = false) {
        // No display at all for a moment (lid closing, a display waking up): nothing to show the switcher on.
        guard WindowStore.shared.isStarted, !NSScreen.screens.isEmpty else {
            if session != nil { endSession(keepPanel: false) }
            NSSound.beep()
            return
        }
        // Mission Control is showing: a switcher on top of it would only confuse.
        if MissionControl.isShowing() {
            if session != nil { endSession(keepPanel: false) }
            return
        }
        if session != nil { endSession(keepPanel: true) }
        let screen = targetScreen()
        WindowStore.shared.pruneVanishedWindows()
        WindowStore.shared.adoptPendingWindows()
        let anchor = WindowStore.shared.anchor(for: profile)
        let items = WindowStore.shared.items(for: profile, screen: screen, anchor: anchor)
        let session = SwitcherSession(profile: profile, hold: hold, items: items, screen: screen,
                                      searching: searching || profile.startInSearch, sticky: sticky)
        session.anchor = anchor
        session.selectedIndex = initialIndex(items, order: profile.order, reverse: reverse)
        self.session = session
        // The shortcut's own style, if it has one, before anything in this session reads the style.
        ui.styleOverride = profile.style
        installKeyMonitor()

        // A quick tap (modifier already up): switch straight away without ever showing the panel, unless the shortcut
        // keeps the switcher open. Reconcile in the background either way, so whatever notifications missed is found by
        // people who mostly tap.
        if !ModifierMonitor.shared.isHolding(session.hold, since: session.startedAt) {
            ModifierMonitor.shared.stopPolling()
            switch holdReleased(session) {
            case .switchToSelection:
                commit()
                WindowStore.shared.refreshForSummon()
                return
            case .startSearching:
                session.isSearching = true
            case .none, .stayOpen:
                break
            }
        }
        ui.present(items: session.items, selected: session.selectedIndex, searching: session.isSearching, query: "", screen: screen,
                   total: session.allItems.count)
        presentedSignature = signature(session.items)
        let delay = session.isSticky ? 0 : Double(Prefs.shared.showDelayMs) / 1000
        if delay <= 0 {
            reveal()
        } else {
            let work = DispatchWorkItem { [weak self, weak session] in
                guard let self, let session, self.session === session else { return }
                self.reveal()
            }
            session.revealWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        requestThumbnails()
        DockBadges.refresh { [weak self, weak session] badges in
            guard let self, let session, self.session === session else { return }
            self.ui.updateDockBadges(badges)
        }
        // Read what needs reading in the background (usually a few apps or nothing); `storeChanged` folds in any difference.
        WindowStore.shared.refreshForSummon()
    }

    private func reveal() {
        // The panel decides what animates: Reduce Motion stops movement there, not fades.
        ui.reveal(animated: true)
        updatePreview()
        startLiveRefresh()
    }

    /// While the switcher is up, the selected window's thumbnail keeps refreshing: a playing video plays here too.
    private func startLiveRefresh() {
        liveTimer?.invalidate()
        let style = ui.effectiveStyle
        guard style != .appIcons, style != .titles else { return }
        let timer = Timer(timeInterval: style == .deck ? 1.0 : 1.5, repeats: true) { [weak self] _ in
            guard let self, let session = self.session, let wid = session.selectedItem?.wid,
                  let window = WindowStore.shared.windows[wid], !window.isMinimized, window.app?.isHidden != true else { return }
            if style == .deck {
                ThumbnailService.shared.refresh([.init(wid: wid, frame: window.frame, isMinimized: false)], freshness: 0.9)
            } else {
                self.ui.requestHeroImage()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    private func initialIndex(_ items: [SwitcherItem], order: WindowOrder, reverse: Bool) -> Int {
        guard !items.isEmpty else { return 0 }
        // In the other orders the window you're in can be anywhere in the list: start next to it.
        if order != .recentlyUsed, let focused = WindowStore.shared.currentFocusedWID,
           let current = items.firstIndex(where: { $0.wid == focused }) {
            return (current + (reverse ? items.count - 1 : 1)) % items.count
        }
        if reverse { return items.count - 1 }
        guard items.count > 1 else { return 0 }
        // The first row is normally the window you're in: start on the previous one, like ⌘⇥ does.
        if let focused = WindowStore.shared.currentFocusedWID, items[0].wid == focused { return 1 }
        if items[0].pid == NSWorkspace.shared.frontmostApplication?.processIdentifier { return 1 }
        return 0
    }

    // MARK: - Selection

    private func step(_ delta: Int) {
        guard let session, !session.items.isEmpty else { return }
        let count = session.items.count
        session.selectedIndex = ((session.selectedIndex + delta) % count + count) % count
        selectionChanged()
    }

    private func move(_ direction: TileLayout.Move) {
        guard let session, let layout = ui.layout, !session.items.isEmpty else { return }
        session.selectedIndex = layout.target(from: session.selectedIndex, direction)
        selectionChanged()
    }

    private func selectionChanged(animated: Bool = true) {
        guard let session else { return }
        ui.select(session.selectedIndex, animated: animated)
        if Prefs.shared.hapticFeedback {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if NSWorkspace.shared.isVoiceOverEnabled, let item = session.selectedItem {
            let text = TitleFormat.spokenDescription(of: item, dockBadge: item.bundlePath.flatMap { DockBadges.current[$0] })
            NSAccessibility.post(element: ui.panel, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        updatePreview()
    }

    // MARK: - Ending

    /// Switches to the selected row.
    func commit() {
        guard let session else { return }
        var item = session.selectedItem
        if let wid = item?.wid, WindowStore.shared.ownWindow(wid) == nil, WindowServerInfo.describe([wid])[wid] == nil {
            // It closed while the switcher was up: take the next window that still exists rather than doing nothing.
            let after = session.items.indices.contains(session.selectedIndex + 1) ? Array(session.items[(session.selectedIndex + 1)...]) : []
            item = (after + session.items.prefix(session.selectedIndex)).first { candidate in
                guard let wid = candidate.wid else { return true }
                return WindowStore.shared.ownWindow(wid) != nil || WindowServerInfo.describe([wid])[wid] != nil
            }
        }
        endSession(keepPanel: item != nil)
        guard let item else { return }
        switch item.kind {
        case .window(let wid):
            if let own = WindowStore.shared.ownWindow(wid) {
                ui.orderOut()
                NSApp.activate(ignoringOtherApps: true)
                if own.isMiniaturized { own.deminiaturize(nil) }
                own.makeKeyAndOrderFront(nil)
                PointerFollow.windowFronted(at: ScreenGeometry.axRect(fromCocoa: own.frame))
                return
            }
            guard let window = WindowStore.shared.windows[wid] else {
                ui.orderOut()
                return
            }
            WindowStore.shared.markFocused(wid)
            let target = WindowActions.FocusTarget(wid: wid, pid: window.pid, element: window.element,
                                                   isMinimized: window.isMinimized, spaceIDs: window.spaceIDs)
            // Keep the (now invisible) panel ordered in until the target is in front, so the app we leave
            // can't take focus back in between.
            WindowActions.focus(target) { [weak self] in
                self?.orderOutIfIdle()
                PointerFollow.windowFronted(at: window.frame)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.orderOutIfIdle() }
        case .app(let pid):
            WindowStore.shared.markActivated(pid: pid)
            orderOutIfIdle()
            WindowActions.activate(pid: pid, bundleURL: WindowStore.shared.apps[pid]?.bundleURL)
        }
    }

    func cancel() {
        endSession(keepPanel: false)
    }

    private func orderOutIfIdle() {
        guard session == nil, ui.panel.isVisible else { return }
        ui.orderOut()
    }

    private func endSession(keepPanel: Bool) {
        guard let session else { return }
        session.revealWork?.cancel()
        self.session = nil
        stopRepeat()
        liveTimer?.invalidate()
        liveTimer = nil
        removeKeyMonitor()
        ModifierMonitor.shared.stopPolling()
        preview.hide()
        if keepPanel { ui.fadeOutImmediately() } else { ui.orderOut() }
    }

    private func modifiersChanged() {
        guard let session, !session.holdReleased else {
            ModifierMonitor.shared.stopPolling()
            return
        }
        guard !ModifierMonitor.shared.isHolding(session.hold, since: session.startedAt) else { return }
        ModifierMonitor.shared.stopPolling()
        switch holdReleased(session) {
        case .none:
            break
        case .switchToSelection:
            commit()
        case .stayOpen:
            // Let go before the panel faded in: it shows now, and stays.
            session.revealWork?.cancel()
            if !ui.isRevealed { reveal() }
        case .startSearching:
            enterSearch()
        }
    }

    /// The hold key went up: applies the shortcut's release behaviour to the session and returns what's left to do.
    /// Search is left for `enterSearch()` (or, before the panel is presented, the caller) to turn on.
    private func holdReleased(_ session: SwitcherSession) -> HoldRelease.Effect {
        var state = HoldRelease(isSticky: session.isSticky, isSearching: session.isSearching, isReleased: session.holdReleased)
        let effect = state.release(session.profile.releaseBehavior)
        session.isSticky = state.isSticky
        session.holdReleased = state.isReleased
        return effect
    }

    // MARK: - Keyboard inside the switcher

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.session != nil else { return event }
            if event.type == .flagsChanged {
                ModifierMonitor.shared.handleLocalEvent(event)
                return event
            }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private static let digitKeys: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5, kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
        kVK_ANSI_Keypad1: 1, kVK_ANSI_Keypad2: 2, kVK_ANSI_Keypad3: 3, kVK_ANSI_Keypad4: 4, kVK_ANSI_Keypad5: 5,
        kVK_ANSI_Keypad6: 6, kVK_ANSI_Keypad7: 7, kVK_ANSI_Keypad8: 8, kVK_ANSI_Keypad9: 9,
    ]

    /// Returns true when the key was consumed.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let session else { return false }
        // An input method is composing (Japanese, Chinese, Korean, a dead key): every key belongs to it, Return included.
        if session.isSearching, ui.searchBar.isComposing { return false }
        let code = Int(event.keyCode)
        switch code {
        case kVK_Escape:
            if session.isSearching && !session.query.isEmpty { setQuery("") } else { cancel() }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            commit()
            return true
        case kVK_LeftArrow: move(.left); return true
        case kVK_RightArrow: move(.right); return true
        case kVK_UpArrow: move(.up); return true
        case kVK_DownArrow: move(.down); return true
        case kVK_Tab:
            // Only reaches us when no global shortcut matched it (e.g. plain Tab in a sticky session).
            step(event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        default:
            break
        }
        if session.isSearching {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hold = session.hold
            let printable = event.charactersIgnoringModifiers.flatMap { characters -> String? in
                guard !characters.isEmpty,
                      characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
                return characters
            }
            // Still holding the key that opened the switcher (⌘ or ⌥)? Type the plain character rather than a shortcut or
            // a ⌥-symbol. Once it has been let go, keys mean what they always do (⌘V pastes, ⌥Q types "@").
            if let printable, !session.holdReleased, !hold.isEmpty, flags.contains(hold) {
                insertIntoSearch(printable)
                return true
            }
            if flags.contains(.command) {
                // Text editing keeps working; any other ⌘-key must not reach the menu (⌘Q would quit Riffle).
                let editing: Set<String> = ["a", "c", "v", "x", "z"]
                return !editing.contains(event.charactersIgnoringModifiers?.lowercased() ?? "")
            }
            return false
        }
        if let digit = SwitcherController.digitKeys[code] {
            if digit <= session.items.count {
                session.selectedIndex = digit - 1
                ui.select(session.selectedIndex, animated: false)
                commit()
            }
            return true
        }
        // The one-key commands go by the physical key (Settings → Shortcuts), whatever modifiers are down with it.
        switch PanelKeyMap.current(Prefs.shared.panelKeys).command(for: UInt32(code)) {
        case .search?: enterSearch()
        case .perform(let action)?: perform(action)
        case .move(let direction)?: move(direction)
        case nil: break
        }
        // While the switcher is up it owns the keyboard: nothing leaks into the app underneath.
        return true
    }

    // MARK: - Search

    func enterSearch() {
        guard let session, !session.isSearching else { return }
        session.isSearching = true
        session.isSticky = true
        session.revealWork?.cancel()
        ui.reload(items: session.items, selected: session.selectedIndex, searching: true, query: session.query, screen: session.screen,
                  total: session.allItems.count)
        presentedSignature = signature(session.items)
        reveal()
    }

    private func insertIntoSearch(_ text: String) {
        if let editor = ui.searchBar.field.currentEditor() as? NSTextView {
            editor.insertText(text, replacementRange: editor.selectedRange())
        } else {
            ui.searchBar.field.stringValue += text
            setQuery(ui.searchBar.field.stringValue)
        }
    }

    private func setQuery(_ query: String) {
        guard let session else { return }
        session.query = query
        session.items = FuzzySearch.rank(session.allItems, query: query)
        session.selectedIndex = 0
        ui.reload(items: session.items, selected: 0, searching: true, query: query, screen: session.screen, total: session.allItems.count)
        presentedSignature = signature(session.items)
        requestThumbnails()
        updatePreview()
    }

    // MARK: - Window actions

    private func perform(_ action: SwitcherAction) {
        guard let item = session?.selectedItem else { return }
        Log.info("action \(action) → \(Log.app(item.bundleID, pid: item.pid))\(item.wid.map { " #\($0)" } ?? " (no window)")")
        if let wid = item.wid, let own = WindowStore.shared.ownWindow(wid) {
            switch action {
            case .close: own.performClose(nil)
            case .minimize: own.isMiniaturized ? own.deminiaturize(nil) : own.miniaturize(nil)
            case .fullscreen: own.toggleFullScreen(nil)
            case .hide: NSApp.hide(nil)
            case .quit: NSSound.beep()
            }
            return
        }
        let window = item.wid.flatMap { WindowStore.shared.windows[$0] }
        switch action {
        case .close:
            guard let window else { return NSSound.beep() }
            WindowActions.close(window.element, isFullscreen: window.isFullscreen)
        case .minimize:
            guard let window else { return NSSound.beep() }
            WindowActions.toggleMinimized(window.element, isMinimized: window.isMinimized, isFullscreen: window.isFullscreen)
        case .fullscreen:
            guard let window else { return NSSound.beep() }
            WindowActions.toggleFullscreen(window.element, isFullscreen: window.isFullscreen)
        case .hide:
            WindowActions.toggleHidden(pid: item.pid)
        case .quit:
            WindowStore.shared.markQuitting(item.pid)
            WindowActions.quit(pid: item.pid)
        }
    }

    // MARK: - Live updates while open

    private struct Rows {
        var all: [SwitcherItem]
        var shown: [SwitcherItem]
        var selected: Int
    }

    /// The session's rows brought up to date with the store: the order the user is looking at stays, each row's data is
    /// refreshed, newcomers go at the end, and the selection stays on its window while that exists.
    private func refreshedRows(_ session: SwitcherSession) -> Rows {
        let fresh = WindowStore.shared.items(for: session.profile, screen: session.screen, anchor: session.anchor)
        let freshByID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var all = session.allItems.compactMap { freshByID[$0.id] }
        let known = Set(all.map(\.id))
        all += fresh.filter { !known.contains($0.id) }
        let shown = session.isSearching ? FuzzySearch.rank(all, query: session.query) : all
        let selectedID = session.selectedItem?.id
        let selected = selectedID.flatMap { id in shown.firstIndex { $0.id == id } } ?? min(session.selectedIndex, max(shown.count - 1, 0))
        return Rows(all: all, shown: shown, selected: selected)
    }

    private func adopt(_ rows: Rows, in session: SwitcherSession) {
        session.allItems = rows.all
        session.items = rows.shown
        session.selectedIndex = rows.selected
    }

    private func storeChanged() {
        guard let session else { return }
        let rows = refreshedRows(session)
        let newSignature = signature(rows.shown)
        guard newSignature != presentedSignature else { return }
        presentedSignature = newSignature
        // Same windows in the same places (a title or a state changed): update those tiles, leave the panel be.
        if ui.updateInPlace(items: rows.shown, selected: rows.selected) {
            adopt(rows, in: session)
            requestThumbnails()
            updatePreview()
            return
        }
        // Something closed or quit: its card shrinks and fades out first, then the rest closes ranks. Until then the
        // session keeps the rows on screen, so a click, hover or key during the fade acts on the card it was aimed at.
        let remaining = Set(rows.shown.map(\.id))
        ui.animateOut(where: { !remaining.contains($0.id) }) { [weak self, weak session] in
            guard let self, let session, self.session === session else { return }
            // The store may have moved on during the fade.
            let rows = self.refreshedRows(session)
            self.adopt(rows, in: session)
            self.presentedSignature = self.signature(rows.shown)
            self.ui.reload(items: session.items, selected: session.selectedIndex, searching: session.isSearching,
                           query: session.query, screen: session.screen, total: session.allItems.count)
            self.requestThumbnails()
            self.updatePreview()
        }
    }

    private func signature(_ items: [SwitcherItem]) -> String {
        items.map { "\($0.id)|\($0.title)|\($0.isMinimized)|\($0.isHidden)|\($0.isFullscreen)|\($0.otherSpaceIndex ?? 0)" }
            .joined(separator: "\n")
    }

    private func requestThumbnails() {
        // The icon and title styles draw no thumbnails, unless the selected window is previewed in place.
        guard let session, ![.appIcons, .titles].contains(ui.effectiveStyle) || Prefs.shared.previewSelectedWindow else { return }
        let store = WindowStore.shared
        // The selection and what follows it first: that's what the user looks at.
        let rotated = Array(session.items[min(session.selectedIndex, session.items.count)...]) + Array(session.items.prefix(session.selectedIndex))
        let requests = rotated.compactMap { item -> ThumbnailService.Request? in
            guard let wid = item.wid else { return nil }
            if let window = store.windows[wid] {
                return ThumbnailService.Request(wid: wid, frame: window.frame, isMinimized: window.isMinimized, isHidden: window.app?.isHidden ?? false)
            }
            return store.ownWindow(wid) == nil ? nil : ThumbnailService.Request(wid: wid, frame: item.frame, isMinimized: item.isMinimized)
        }
        ThumbnailService.shared.refresh(requests, freshness: 0.8)
    }

    private func updatePreview() {
        guard let session, ui.isRevealed, Prefs.shared.previewSelectedWindow, let wid = session.selectedItem?.wid,
              let window = WindowStore.shared.windows[wid] else {
            preview.hide()
            return
        }
        preview.show(wid: wid, window: window)
    }

    // MARK: - Key repeat (Carbon hot keys don't auto-repeat)

    private func startRepeat(reverse: Bool) {
        stopRepeat()
        let interval = max(NSEvent.keyRepeatInterval, 0.033)
        // The key's own state backs up Carbon's release event (which can go missing, e.g. if shortcuts are registered
        // again while it's held). Only trusted if it reports the key down right now, as it must.
        let key = session.map { CGKeyCode($0.profile.keyCode) }
        let keyStateWorks = key.map { CGEventSource.keyState(.combinedSessionState, key: $0) } ?? false
        let timer = Timer(fire: Date().addingTimeInterval(NSEvent.keyRepeatDelay), interval: interval, repeats: true) { [weak self] _ in
            guard let self, self.session != nil else {
                self?.stopRepeat()
                return
            }
            if keyStateWorks, let key, !CGEventSource.keyState(.combinedSessionState, key: key) {
                self.stopRepeat()
                return
            }
            self.step(reverse ? -1 : 1)
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    // MARK: - SwitcherUIDelegate

    func switcherUIHovered(_ index: Int) {
        guard let session, index != session.selectedIndex, session.items.indices.contains(index) else { return }
        session.selectedIndex = index
        ui.select(index, animated: true)
        updatePreview()
    }

    func switcherUIClicked(_ index: Int) {
        guard let session, session.items.indices.contains(index) else { return }
        session.selectedIndex = index
        commit()
    }

    func switcherUIPerform(_ action: SwitcherAction, at index: Int) {
        guard let session, session.items.indices.contains(index) else { return }
        if index != session.selectedIndex {
            session.selectedIndex = index
            ui.select(index, animated: true)
        }
        perform(action)
    }

    func switcherUIOpen(_ files: [URL], at index: Int) {
        guard let session, let item = session.items[safe: index], let route = FileDrop.route(for: item, files: files) else { return }
        session.selectedIndex = index
        // The window first, so the files open over it (a browser puts them in that window); an app without windows
        // comes forward by opening them.
        if route.window != nil { commit() } else { cancel() }
        FileDrop.open(files, along: route)
    }

    func switcherUIQueryChanged(_ query: String) {
        guard let session, query != session.query else { return }
        setQuery(query)
    }

    func switcherUIResignedKey() {
        // AppKit can deliver the resign of a panel we just ordered out *after* the next session already made it
        // key again, so only dismiss if, a beat later, the panel really has lost the keyboard.
        guard let session else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak session] in
            guard let self, let session, self.session === session, !self.ui.panel.isKeyWindow else { return }
            self.cancel()
        }
    }

    // MARK: - Screen

    private func targetScreen() -> NSScreen {
        let fallback = ScreenGeometry.screenUnderMouse ?? NSScreen.main ?? NSScreen.screens[0]
        switch Prefs.shared.screen {
        case .mouse:
            return fallback
        case .activeWindow:
            guard let wid = WindowStore.shared.currentFocusedWID, let frame = WindowStore.shared.windows[wid]?.frame,
                  let screen = ScreenGeometry.screen(containingAX: frame) else { return fallback }
            return screen
        case .main:
            return NSScreen.screens.first ?? fallback
        }
    }
}
