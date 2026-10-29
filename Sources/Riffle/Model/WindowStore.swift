import Cocoa

/// Source of truth for every app and window Riffle can switch to, kept in most-recently-used order.
///
/// Main-thread owned. AX IPC (which can block on a busy app) runs on background queues through `AXLimiter` and is
/// folded back in on main. AX notifications keep the model fresh; the WindowServer (which never waits on an app) is
/// checked on every summon, and only apps that need it are read again over AX (`ScanPlanner` decides). Full scans of
/// every app are for an old or invalidated model, so summoning the switcher never has to wait for IPC.
final class WindowStore {
    static let shared = WindowStore()

    private(set) var apps: [pid_t: TrackedApp] = [:]
    private(set) var windows: [CGWindowID: TrackedWindow] = [:]
    private(set) var topology = SpaceTopology()
    /// When `topology` was read: only a newer reading replaces it.
    private var topologyReadAt: TimeInterval = 0
    private(set) var isStarted = false
    /// How long the last full scan took.
    private(set) var lastScanDuration: TimeInterval = 0

    /// Fired (coalesced) after the window list changed in a way the switcher should show.
    var onChange: (() -> Void)?
    /// Fired when a window stops being the focused one: the perfect moment to refresh its thumbnail.
    var onWindowLostFocus: ((CGWindowID) -> Void)?
    /// Fired when a window is gone for good.
    var onWindowRemoved: ((CGWindowID) -> Void)?
    /// Fired when a window Riffle didn't know shows up.
    var onWindowAdded: ((CGWindowID) -> Void)?

    /// Starts high: windows nobody focused yet get stamps below the lowest one, and must never reach zero.
    private var stamp: UInt64 = 1 << 32
    /// The stamp of the newest focus event applied, so late answers to older events can't win.
    private var lastFocusStamp: UInt64 = 0
    private var elementIndex = [AXElementKey: CGWindowID]()
    /// Focus the system reported for windows Riffle couldn't inspect yet: the stamp, and when it happened.
    private var pendingFocusStamps = [CGWindowID: (stamp: UInt64, at: TimeInterval)]()
    private(set) var lastFocusedWID: CGWindowID?
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let scanQueue = DispatchQueue(label: "riffle.scan", qos: .userInitiated)
    /// Every AX call into another app goes through it: a few in flight at most, one per app.
    private let limiter = AXLimiter.shared
    /// AXObserver registration isn't documented as thread-safe: one queue for all of it.
    private let observerQueue = DispatchQueue(label: "riffle.ax.observers", qos: .userInitiated)
    private var scanRunning = false
    /// When the full scan under way started, if one is.
    private var runningFullScanStart: TimeInterval?
    /// Asked for while a scan ran: runs next (a full scan wins over a few apps).
    private var queuedScope: ScanScope?
    /// A scan asked for while the screen was locked: the next scan that can run (on unlock at the latest) takes its place,
    /// as a full one, with the first scan's seeding if it was that one.
    private var scanWaitingForUnlock: (seedOrder: Bool, pending: Bool) = (false, false)
    private let unlockObserver = UnlockObserver()
    /// Waiting for the next full scan to finish (`rescan(completion:)`).
    private var scanCompletions = [() -> Void]()
    private var changeScheduled = false

    // What `ScanPlanner` goes by.
    private var scanNeeds = [pid_t: ScanPlanner.Need]()
    /// Per app (tracked or not), the window-like surfaces a scan has settled, and whether each was on screen then.
    private var examined = [pid_t: [CGWindowID: Bool]]()
    /// Untracked apps that own window-like surfaces no scan has looked at yet.
    private var untrackedOwners = Set<pid_t>()
    /// When the last full scan that completed had started.
    private var lastFullScanStart: TimeInterval?
    /// The whole model was invalidated (wake, displays) and no full scan has caught up yet.
    private var fullScanRequestedAt: TimeInterval?
    /// Sweeps for windows on other Spaces carry on by themselves this many rounds before waiting for the next trigger.
    private static let sweepFollowUpLimit = 12
    private var sweepFollowUps = WindowStore.sweepFollowUpLimit
    private var safetyNet: Timer?
    private var displayChangeWork: DispatchWorkItem?

    /// What one scan reads: every app, or a few (tracked apps, and untracked owners of window-like surfaces to probe).
    private enum ScanScope {
        case full
        case apps(Set<pid_t>)

        func merged(with other: ScanScope) -> ScanScope {
            switch (self, other) {
            case (.full, _), (_, .full): return .full
            case let (.apps(mine), .apps(theirs)): return .apps(mine.union(theirs))
            }
        }
    }

    // MARK: - Lifecycle

    func start(completion: (() -> Void)? = nil) {
        guard !isStarted else { completion?(); return }
        isStarted = true
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        observeWorkspace()
        observeOwnWindows()
        for running in NSWorkspace.shared.runningApplications where shouldTrack(running) {
            track(running)
        }
        rescan(seedOrder: true, completion: completion)
        startSafetyNet()
        MissionControl.warmUp()
    }

    /// Accessibility is back after being taken away: observers made before may never fire again, so every app gets a new
    /// one, and everything is read again.
    func reattachObservers() {
        guard isStarted else { return }
        for app in apps.values where !app.isAttachingObserver {
            if let observer = app.observer {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            app.observer = nil
            app.observedWindows.removeAll()
            attachObserver(app)
        }
        requestFullScan()
    }

    private func shouldTrack(_ running: NSRunningApplication) -> Bool {
        guard running.processIdentifier > 0, running.processIdentifier != ownPID, !running.isTerminated else { return false }
        return running.activationPolicy == .regular
    }

    @discardableResult
    private func track(_ running: NSRunningApplication) -> TrackedApp {
        if let existing = apps[running.processIdentifier] { return existing }
        let app = TrackedApp(running)
        apps[app.pid] = app
        attachObserver(app)
        return app
    }

    private func untrack(pid: pid_t) {
        guard let app = apps.removeValue(forKey: pid) else { return }
        if let observer = app.observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        let gone = windows.values.filter { $0.pid == pid }.map(\.wid)
        gone.forEach(removeWindow)
        quitting[pid] = nil
        scanNeeds[pid] = nil
        examined[pid] = nil
        // Always: an app whose windows had already closed (most apps close them before exiting) is still on screen as an
        // app without windows, and an open switcher must drop it now.
        notifyChange()
    }

    /// Apps asked to quit from the switcher, and when. While they wind down they aren't shown as apps without windows:
    /// most close their windows first and exit a moment later.
    private var quitting = [pid_t: TimeInterval]()

    func markQuitting(_ pid: pid_t) {
        quitting[pid] = ProcessInfo.processInfo.systemUptime
        notifyChange()
    }

    private func isQuitting(_ pid: pid_t) -> Bool {
        guard let since = quitting[pid] else { return false }
        // An app that asked to save, or refused, is back after a while.
        return ProcessInfo.processInfo.systemUptime - since < 10
    }

    // MARK: - Scans

    /// While the screen is locked, apps don't let accessibility read their windows: a scan then would see none and drop
    /// them all (after every wake from sleep, the first ⌘⇥ would come up empty and forget the most-recent order).
    static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    /// Seconds since the last keyboard, mouse or trackpad input.
    static var userIdleTime: TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// Re-inventories every window of every app on every Space; concurrent requests merge. `completion` runs once a
    /// full scan has finished. Summons don't need this: see `refreshForSummon`.
    func rescan(seedOrder: Bool = false, completion: (() -> Void)? = nil) {
        if let completion { scanCompletions.append(completion) }
        startScan(.full, seedOrder: seedOrder)
    }

    /// Right after a summon (its rows are on screen already, from the model and a WindowServer check): read over AX
    /// what needs reading, folded in as it arrives. Usually a few apps or nothing; every app only when the model is
    /// old or was invalidated.
    func refreshForSummon() {
        run(ScanPlanner.plan(plannerState(), trigger: .summon))
    }

    private func run(_ plan: ScanPlanner.Plan) {
        sweepFollowUps = WindowStore.sweepFollowUpLimit
        switch plan {
        case .none:
            break
        case .full:
            // One is under way and nothing has invalidated the model since it started: it is the scan asked for.
            if let running = runningFullScanStart, (fullScanRequestedAt ?? 0) <= running { return }
            rescan()
        case .apps(let pids):
            startScan(.apps(pids))
        }
    }

    /// One app needs a look no notification can give; nothing else has to wait for it.
    private func scanApp(_ pid: pid_t, because reason: ScanPlanner.Reason) {
        guard apps[pid] != nil else { return }
        scanNeeds[pid, default: ScanPlanner.Need()].reasons.insert(reason)
        startScan(.apps([pid]))
    }

    /// Everything may have changed (woke from sleep, displays rearranged): read every app again.
    private func requestFullScan() {
        if fullScanRequestedAt == nil { fullScanRequestedAt = ProcessInfo.processInfo.systemUptime }
        rescan()
    }

    private func plannerState() -> ScanPlanner.State {
        let now = ProcessInfo.processInfo.systemUptime
        var needs = scanNeeds.filter { apps[$0.key] != nil }
        // No notifications: only scans keep these current.
        for app in apps.values where app.observer == nil && !app.isAttachingObserver {
            needs[app.pid, default: ScanPlanner.Need()].reasons.insert(.noObserver)
        }
        // An untracked owner that didn't answer waits out its backoff like any app.
        let owners = untrackedOwners.filter { scanNeeds[$0].map { ScanPlanner.isDue($0, now: now) } ?? true }
        return ScanPlanner.State(now: now, lastFullScan: lastFullScanStart, fullScanRequested: fullScanRequestedAt != nil,
                                 needs: needs, untrackedOwners: owners, idleTime: WindowStore.userIdleTime,
                                 isLocked: WindowStore.isScreenLocked)
    }

    private func startScan(_ requested: ScanScope, seedOrder: Bool = false) {
        guard !scanRunning else {
            queuedScope = queuedScope.map { $0.merged(with: requested) } ?? requested
            return
        }
        if WindowStore.isScreenLocked {
            if !scanWaitingForUnlock.pending { Log.info("screen locked: the window scan waits for unlock") }
            scanWaitingForUnlock = (scanWaitingForUnlock.seedOrder || seedOrder, true)
            return
        }
        var scope = requested
        var seedOrder = seedOrder
        if scanWaitingForUnlock.pending {
            // This scan is the one that was waiting (the unlock notice can come late, or not at all): it reads everything
            // and does its seeding.
            scope = .full
            seedOrder = seedOrder || scanWaitingForUnlock.seedOrder
            scanWaitingForUnlock = (false, false)
        }
        let targetApps: [TrackedApp]
        let probe: WindowScanner.Probe
        switch scope {
        case .full:
            targetApps = Array(apps.values)
            probe = .all
        case .apps(let pids):
            targetApps = pids.compactMap { apps[$0] }
            let untracked = pids.filter { apps[$0] == nil }
            guard !targetApps.isEmpty || !untracked.isEmpty else { return }
            probe = .only(untracked)
        }
        let isFull: Bool
        if case .full = scope { isFull = true } else { isFull = false }
        scanRunning = true
        let startedAt = ProcessInfo.processInfo.systemUptime
        if isFull { runningFullScanStart = startedAt }
        for app in targetApps { scanNeeds[app.pid, default: ScanPlanner.Need()].lastAttempt = startedAt }
        let targets = targetApps.map {
            WindowScanner.Target(pid: $0.pid, element: $0.element, cursor: $0.bruteForceCursor, sweepPass: $0.sweepPass)
        }
        let targetPIDs = Set(targetApps.map(\.pid))
        var knownElements = [CGWindowID: AXUIElement]()
        for (wid, window) in windows where targetPIDs.contains(window.pid) {
            if let element = window.element { knownElements[wid] = element }
        }
        var unfindable = [pid_t: Set<CGWindowID>]()
        for app in targetApps where !app.unfindableWIDs.isEmpty { unfindable[app.pid] = app.unfindableWIDs }
        let ownPID = self.ownPID
        let tracked = Set(apps.keys)
        let hidden = Set(apps.values.filter(\.isHidden).map(\.pid))
        let limiter = self.limiter
        scanQueue.async { [weak self] in
            let result = WindowScanner.scan(targets: targets, knownElements: knownElements, ownPID: ownPID, trackedPIDs: tracked,
                                            unfindable: unfindable, probe: probe, hiddenPIDs: hidden, limiter: limiter)
            DispatchQueue.main.async { self?.apply(result, isFull: isFull, seedOrder: seedOrder, startedAt: startedAt) }
        }
    }

    private func apply(_ result: ScanResult, isFull: Bool, seedOrder: Bool, startedAt: TimeInterval) {
        // The screen locked while the scan ran: it may have read the lock's empty window lists. Scan again on unlock.
        runningFullScanStart = nil
        if WindowStore.isScreenLocked {
            Log.info("screen locked during a scan: its result is dropped, the scan waits for unlock")
            scanRunning = false
            queuedScope = nil
            scanWaitingForUnlock = (scanWaitingForUnlock.seedOrder || seedOrder, true)
            return
        }
        // The scan read its Space layout when it started; a reconcile since (a Space change while it waited on a slow app)
        // knows better.
        if startedAt >= topologyReadAt {
            topology = result.topology
            topologyReadAt = startedAt
        }
        if isFull { lastScanDuration = result.duration }
        for pid in result.newAppPIDs {
            if let running = NSRunningApplication(processIdentifier: pid) { track(running) }
        }
        for (pid, cursor) in result.cursors { apps[pid]?.bruteForceCursor = cursor }
        for (pid, wids) in result.unfindable { apps[pid]?.unfindableWIDs = wids }
        for (pid, wids) in result.sweepPasses { apps[pid]?.sweepPass = wids }
        for pid in result.scannedPIDs { apps[pid]?.isResponsive = !result.unresponsivePIDs.contains(pid) }

        let ordered = result.records.sorted { $0.zIndex < $1.zIndex }
        var seededStamps = [CGWindowID: UInt64]()
        if seedOrder {
            // Before we have seen any focus change, the stacking order is the best guess of recency.
            for (offset, record) in ordered.reversed().enumerated() {
                seededStamps[record.snapshot.wid] = stamp + UInt64(offset) + 1
            }
            stamp += UInt64(ordered.count) + 1
        }
        var seen = Set<CGWindowID>()
        var found = 0
        for record in ordered {
            let wid = record.snapshot.wid
            guard let app = apps[record.description.pid] else { continue }
            seen.insert(wid)
            if windows[wid] == nil { found += 1 }
            let pending = pendingFocusStamps.removeValue(forKey: wid)?.stamp
            upsert(record.snapshot, app: app, description: record.description, spaces: record.spaces, stamp: seededStamps[wid] ?? pending)
            if let pending, seededStamps[wid] == nil { becameFocused(wid, stamp: pending) }
        }
        // Only what this scan could vouch for may go: windows of apps it read completely, and not confirmed after it began
        // (a notification may have added one while it ran).
        for (wid, window) in windows where !seen.contains(wid) && result.scannedPIDs.contains(window.pid)
            && !result.unresponsivePIDs.contains(window.pid) && window.confirmedAt < startedAt {
            removeWindow(wid)
        }
        if !isFull && found > 0 && lastFullScanStart != nil {
            Log.info("a scan of \(result.scannedPIDs.count) app(s) added \(found) window(s)")
        }

        // What the planner goes by next time.
        for (pid, surfaces) in result.examined { examined[pid] = surfaces }
        untrackedOwners.subtract(result.examined.keys)
        for pid in result.scannedPIDs {
            var need = scanNeeds[pid] ?? ScanPlanner.Need()
            if result.unresponsivePIDs.contains(pid) {
                need.reasons.insert(.unresponsive)
                need.failures += 1
                need.lastAttempt = startedAt
            } else if apps[pid] == nil {
                // An untracked owner that answered: settled (see `examined`).
                scanNeeds[pid] = nil
                continue
            } else {
                need.reasons = result.missing[pid] == nil ? [] : [.sweeping]
                need.failures = 0
            }
            scanNeeds[pid] = need
        }
        if isFull {
            lastFullScanStart = startedAt
            if let requested = fullScanRequestedAt, requested <= startedAt { fullScanRequestedAt = nil }
        }

        // Focus reports for windows no scan ever admitted (dialogs, panels, long-closed windows) expire.
        let now = ProcessInfo.processInfo.systemUptime
        pendingFocusStamps = pendingFocusStamps.filter { now - $0.value.at < 10 }
        if seedOrder, let front = NSWorkspace.shared.frontmostApplication {
            appActivated(front)
        }
        scanRunning = false
        let completions = isFull ? scanCompletions : []
        if isFull { scanCompletions = [] }
        notifyChange()
        completions.forEach { $0() }
        if let next = queuedScope {
            queuedScope = nil
            startScan(next)
        } else {
            continueSweeps()
        }
    }

    /// Windows on other Spaces are found by sweeping AX element ids a slice per scan: while a sweep is under way it
    /// carries on by itself, a moment apart, rather than waiting for the next summon.
    private func continueSweeps() {
        let sweeping = Set(scanNeeds.filter { $0.value.reasons.contains(.sweeping) && apps[$0.key] != nil }.keys)
        guard !sweeping.isEmpty, sweepFollowUps > 0 else { return }
        sweepFollowUps -= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startScan(.apps(sweeping))
        }
    }

    // MARK: - The WindowServer's view

    /// Brings the model in line with the WindowServer, asking no app (so it never waits on a busy one; about a
    /// millisecond): the Space layout and the Space of every window, windows that are gone, background tabs, and which
    /// apps own windows the model doesn't know yet (they get a scan, see `ScanPlanner`).
    private func reconcileWithWindowServer() {
        guard isStarted, !WindowStore.isScreenLocked else { return }
        let readAt = ProcessInfo.processInfo.systemUptime
        let fresh = SpaceTopology.read(includeWindows: true)
        // SkyLight didn't answer properly: then only closed windows are dropped (from the public window list), the
        // rest waits for an answer.
        let layoutKnown = WindowServerReconcile.isLayoutKnown(fresh)
        let descriptions = WindowServerInfo.describe(Array(Set(fresh.orderedWindowIDs).union(windows.keys)))
        // No answer at all is no proof that anything closed.
        guard !descriptions.isEmpty else { return }
        var changed = false
        if layoutKnown {
            changed = fresh.spaces != topology.spaces || fresh.visibleSpaceIDs != topology.visibleSpaceIDs
                || fresh.activeSpaceID != topology.activeSpaceID
            topology = fresh
            topologyReadAt = readAt
        }
        let outcome = WindowServerReconcile.evaluate(WindowServerReconcile.Input(
            ownPID: ownPID, topology: fresh, descriptions: descriptions, displays: DisplayBounds.online(),
            tracked: windows.values.map { WindowServerReconcile.Tracked(wid: $0.wid, pid: $0.pid, isMinimized: $0.isMinimized) },
            trackedPIDs: Set(apps.keys), hiddenPIDs: Set(apps.values.filter(\.isHidden).map(\.pid)), examined: examined))
        if !outcome.vanished.isEmpty {
            outcome.vanished.forEach(removeWindow)
            Log.info("pruned \(outcome.vanished.count) vanished window(s)")
            changed = true
        }
        for wid in outcome.backgroundTabs {
            guard let window = windows[wid] else { continue }
            Log.info("\(Log.app(window.app?.bundleID, pid: window.pid)) #\(wid) is a background tab: its group's card is the visible tab")
            removeWindow(wid)
            changed = true
        }
        for (wid, spaces) in outcome.spaces where windows[wid]?.spaceIDs != spaces {
            windows[wid]?.spaceIDs = spaces
            changed = true
        }
        if layoutKnown {
            for pid in outcome.appsWithUnknownWindows {
                scanNeeds[pid, default: ScanPlanner.Need()].reasons.insert(.unknownWindows)
            }
            untrackedOwners = outcome.untrackedOwners
            examined = WindowServerReconcile.pruned(examined, alive: Set(descriptions.keys))
            scanNeeds = scanNeeds.filter { apps[$0.key] != nil || untrackedOwners.contains($0.key) }
        }
        if changed { notifyChange() }
    }

    /// Every half minute while someone is at the Mac: catch up with the WindowServer, retry apps that didn't answer,
    /// and read everything again once the model is a minute and a half old.
    private func startSafetyNet() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, !WindowStore.isScreenLocked, WindowStore.userIdleTime < ScanPlanner.idleCutoff else { return }
            self.reconcileWithWindowServer()
            self.run(ScanPlanner.plan(self.plannerState(), trigger: .timer))
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        safetyNet = timer
    }

    // MARK: - Model updates

    private func nextStamp() -> UInt64 {
        stamp += 1
        return stamp
    }

    private func upsert(_ snapshot: AXWindowSnapshot, app: TrackedApp, description: CGWindowDescription?, spaces: [CGSSpaceID], stamp newStamp: UInt64?) {
        let title = (snapshot.title.isEmpty ? (description?.name ?? "") : snapshot.title).withoutFormatCharacters
        let frame = snapshot.frame ?? description?.bounds ?? .zero
        if let window = windows[snapshot.wid] {
            if let old = window.element, !CFEqual(old, snapshot.element) {
                elementIndex[AXElementKey(element: old)] = nil
                app.observedWindows.remove(window.wid)
                window.element = snapshot.element
                observe(window)
            } else if window.element == nil {
                // Adopted from the WindowServer before AX answered: now it has its element.
                window.element = snapshot.element
                observe(window)
            } else {
                // Its notifications may not have been registered (the app was busy then): try again.
                observe(window)
            }
            window.title = title
            window.isMinimized = snapshot.isMinimized
            window.isFullscreen = snapshot.isFullscreen
            window.frame = frame
            window.confirmedAt = ProcessInfo.processInfo.systemUptime
            if !spaces.isEmpty { window.spaceIDs = spaces }
            if let newStamp, newStamp > window.focusStamp { window.focusStamp = newStamp }
        } else {
            let floor = windows.values.map(\.focusStamp).min() ?? stamp
            let lowest = floor > 1 ? floor - 1 : 1
            let window = TrackedWindow(wid: snapshot.wid, pid: app.pid, app: app, element: snapshot.element, title: title,
                                       isMinimized: snapshot.isMinimized, isFullscreen: snapshot.isFullscreen, frame: frame,
                                       spaceIDs: spaces, focusStamp: newStamp ?? lowest)
            windows[snapshot.wid] = window
            observe(window)
            onWindowAdded?(snapshot.wid)
            if isStarted && !scanRunning { Log.info("tracking \(Log.app(app.bundleID, pid: app.pid)) #\(snapshot.wid)") }
        }
        elementIndex[AXElementKey(element: snapshot.element)] = snapshot.wid
    }

    private func removeWindow(_ wid: CGWindowID) {
        guard let window = windows.removeValue(forKey: wid) else { return }
        if let element = window.element { elementIndex[AXElementKey(element: element)] = nil }
        window.app?.observedWindows.remove(wid)
        if lastFocusedWID == wid { lastFocusedWID = nil }
        onWindowRemoved?(wid)
    }

    private func notifyChange() {
        guard !changeScheduled else { return }
        changeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.changeScheduled = false
            self.onChange?()
        }
    }

    /// Optimistic MRU bump for a window Riffle is about to focus.
    func markFocused(_ wid: CGWindowID) {
        guard let window = windows[wid] else { return }
        window.focusStamp = nextStamp()
        window.app?.activationStamp = window.focusStamp
        becameFocused(wid, stamp: window.focusStamp)
    }

    func markActivated(pid: pid_t) {
        apps[pid]?.activationStamp = nextStamp()
    }

    /// `reserved` was taken when the event arrived: answers come back from a concurrent queue in any order, and an
    /// older event's late answer must not make its window the most recent.
    private func focusChanged(to wid: CGWindowID, pid: pid_t, element: AXUIElement?, reserved: UInt64) {
        Log.info("focus → \(Log.app(apps[pid]?.bundleID, pid: pid)) #\(wid)\(windows[wid] == nil ? " (untracked)" : "")")
        if let app = apps[pid], reserved > app.activationStamp { app.activationStamp = reserved }
        if let window = windows[wid] {
            if reserved > window.focusStamp { window.focusStamp = reserved }
            becameFocused(wid, stamp: reserved)
        } else {
            pendingFocusStamps[wid] = (reserved, ProcessInfo.processInfo.systemUptime)
            if let element { discover(element, pid: pid) }
        }
    }

    private func becameFocused(_ wid: CGWindowID, stamp: UInt64) {
        guard stamp >= lastFocusStamp else { return }
        lastFocusStamp = stamp
        if let old = lastFocusedWID, old != wid { onWindowLostFocus?(old) }
        lastFocusedWID = wid
    }

    // MARK: - Workspace events

    private func observeWorkspace() {
        unlockObserver.onUnlock = { [weak self] in
            // Give apps a moment to let accessibility in again, then catch up on everything the lock hid (a scan that
            // was waiting brings its seeding along).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.rescan() }
        }
        // Delivered at once: AppKit holds back distributed notifications while the app isn't active, and Riffle rarely is.
        DistributedNotificationCenter.default().addObserver(unlockObserver, selector: #selector(UnlockObserver.unlocked),
                                                            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil,
                                                            suspensionBehavior: .deliverImmediately)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  self.shouldTrack(running) else { return }
            self.track(running)
            // A freshly launched app answers accessibility a moment later, and opens its windows over the first seconds:
            // read it (only it) twice.
            let pid = running.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.scanApp(pid, because: .launched) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.scanApp(pid, because: .launched) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.untrack(pid: running.processIdentifier)
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appActivated(running)
        }
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.notifyChange() }
        }
        // Which Space each window is on, and which Spaces are on screen, are WindowServer facts: no app needs asking,
        // except apps whose windows on the Space now on screen the model doesn't know (AX lists the windows on screen).
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.reconcileWithWindowServer()
            self.run(ScanPlanner.plan(self.plannerState(), trigger: .event))
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.requestFullScan()
        }
        // Displays come and go in bursts of notifications: read everything once they've settled.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.displayChangeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.requestFullScan() }
            self.displayChangeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    private func appActivated(_ running: NSRunningApplication) {
        guard running.processIdentifier != ownPID else { return }
        let app = apps[running.processIdentifier] ?? (shouldTrack(running) ? track(running) : nil)
        guard let app else { return }
        app.activationStamp = nextStamp()
        // An app that wasn't ready when it launched gets another chance to tell us about its windows.
        if app.observer == nil, !app.isAttachingObserver { attachObserver(app) }
        let pid = app.pid
        let element = app.element
        let reserved = nextStamp()
        limiter.submit(pid: pid, priority: .high) { [weak self] in
            guard let focused = AXReader.focusedWindow(ofApp: element), let wid = focused.windowID else { return }
            DispatchQueue.main.async { self?.focusChanged(to: wid, pid: pid, element: focused, reserved: reserved) }
        }
    }

    // MARK: - AX observers

    /// Subscribes to the app's window notifications. A just-launched app often can't answer yet ("cannot complete"):
    /// then it is tried again with growing pauses for about 20 seconds, and a scan follows once it works.
    private func attachObserver(_ app: TrackedApp, attempt: Int = 0) {
        let pid = app.pid
        let appElement = app.element
        app.isAttachingObserver = true
        observerQueue.async { [weak self] in
            var created: AXObserver?
            var notReady = false
            if AXObserverCreate(pid, riffleAXCallback, &created) == .success, let observer = created {
                let refcon = UnsafeMutableRawPointer(bitPattern: Int(pid))
                var added = [String]()
                for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                             kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
                    let result = AXObserverAddNotification(observer, appElement, name as CFString, refcon)
                    // Not answering: stop at once (each further call would wait out the timeout and hold up other apps).
                    if result == .cannotComplete || result == .failure {
                        notReady = true
                        break
                    }
                    if result == .success { added.append(name) }
                }
                if notReady {
                    for name in added { AXObserverRemoveNotification(observer, appElement, name as CFString) }
                } else {
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                    DispatchQueue.main.async {
                        app.isAttachingObserver = false
                        guard let self, self.apps[pid] === app else {
                            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                            return
                        }
                        app.observer = observer
                        for window in self.windows.values where window.pid == pid { self.observe(window) }
                        if attempt > 0 {
                            Log.info("\(Log.app(app.bundleID, pid: app.pid)): window notifications on after \(attempt + 1) tries")
                            self.scanApp(pid, because: .changed)
                        }
                    }
                    return
                }
            } else {
                notReady = true
            }
            DispatchQueue.main.async {
                guard let self, self.apps[pid] === app else { return }
                guard notReady, attempt < 8 else {
                    app.isAttachingObserver = false
                    Log.warn("\(Log.app(app.bundleID, pid: app.pid)): no window notifications; relying on scans")
                    return
                }
                let delay = min(0.25 * pow(2, Double(attempt)), 4)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.apps[pid] === app else { return }
                    self.attachObserver(app, attempt: attempt + 1)
                }
            }
        }
    }

    private func observe(_ window: TrackedWindow) {
        guard let app = window.app, let observer = app.observer, let element = window.element,
              app.observedWindows.insert(window.wid).inserted else { return }
        let refcon = UnsafeMutableRawPointer(bitPattern: Int(window.pid))
        let wid = window.wid
        observerQueue.async {
            for name in [kAXUIElementDestroyedNotification, kAXTitleChangedNotification, kAXWindowMiniaturizedNotification,
                         kAXWindowDeminiaturizedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification] {
                // Not answering: stop at once (each further call would wait out the timeout and hold up every other
                // app's registrations); its next update tries again.
                if AXObserverAddNotification(observer, element, name as CFString, refcon) == .cannotComplete {
                    DispatchQueue.main.async { app.observedWindows.remove(wid) }
                    return
                }
            }
        }
    }

    fileprivate func handle(_ notification: String, element: AXUIElement, pid: pid_t) {
        switch notification {
        case kAXUIElementDestroyedNotification:
            guard let wid = elementIndex[AXElementKey(element: element)] else { return }
            if WindowServerInfo.describe([wid])[wid] != nil {
                // The app rebuilt its AX tree but the window lives on (or it was ordered out, a tab put in the
                // background): find its new element, or let a scan of that app decide it's gone.
                elementIndex[AXElementKey(element: element)] = nil
                windows[wid]?.element = nil
                windows[wid]?.app?.observedWindows.remove(wid)
                scanApp(windows[wid]?.pid ?? pid, because: .changed)
            } else {
                removeWindow(wid)
                notifyChange()
            }
        case kAXWindowCreatedNotification:
            discover(element, pid: pid)
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            let reserved = nextStamp()
            limiter.submit(pid: pid, priority: .high) { [weak self] in
                guard let wid = element.windowID else { return }
                DispatchQueue.main.async { self?.focusChanged(to: wid, pid: pid, element: element, reserved: reserved) }
            }
        case kAXTitleChangedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
             kAXWindowMovedNotification, kAXWindowResizedNotification:
            refresh(element)
        case kAXApplicationHiddenNotification, kAXApplicationShownNotification:
            notifyChange()
        default:
            break
        }
    }

    /// Inspects a window the system just told us about. Some apps publish a new window's role a beat after announcing
    /// it, fade a new window in from transparent, or place it a moment later; and a busy app (Preview opening a big
    /// PDF) may not answer at all for a while: retry with growing pauses, and if it never answers, scan that app.
    private func discover(_ element: AXUIElement, pid: pid_t, attempt: Int = 0) {
        limiter.submit(pid: pid, priority: .high) { [weak self] in
            let snapshot = AXReader.snapshot(of: element)
            if snapshot == nil || snapshot?.subrole == nil {
                let limit = snapshot == nil ? 6 : 3
                if attempt < limit {
                    let delay = snapshot == nil ? 0.1 * pow(2, Double(attempt)) : 0.15
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.discover(element, pid: pid, attempt: attempt + 1) }
                    return
                }
            }
            guard let snapshot else {
                DispatchQueue.main.async { self?.scanApp(pid, because: .changed) }
                return
            }
            let description = WindowServerInfo.describe([snapshot.wid])[snapshot.wid]
            let displays = DisplayBounds.online()
            if let description, WindowEligibility.isPhantom(snapshot, description, displays: displays), attempt < 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * pow(2, Double(attempt))) {
                    self?.discover(element, pid: pid, attempt: attempt + 1)
                }
                return
            }
            let spaces = PrivateAPI.spaces(forWindow: snapshot.wid)
            DispatchQueue.main.async {
                guard let self, let app = self.apps[pid] else { return }
                // Same rule as the scan: the WindowServer must agree the window belongs to this app.
                guard description?.pid == pid, WindowEligibility.admit(snapshot, description, displays: displays) else {
                    self.pendingFocusStamps[snapshot.wid] = nil
                    Log.info("skip \(Log.app(app.bundleID, pid: app.pid)) #\(snapshot.wid): role=\(snapshot.role ?? "-") subrole=\(snapshot.subrole ?? "-") level=\(description?.layer ?? -1) owner=\(description?.pid ?? -1)")
                    return
                }
                let pending = self.pendingFocusStamps.removeValue(forKey: snapshot.wid)?.stamp
                let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                let isNew = self.windows[snapshot.wid] == nil
                self.upsert(snapshot, app: app, description: description, spaces: spaces,
                            stamp: pending ?? (isNew && isFront ? self.nextStamp() : nil))
                if let pending { self.becameFocused(snapshot.wid, stamp: pending) }
                self.notifyChange()
            }
        }
    }

    /// Re-reads a window after a title, minimize, move or resize notification. A drag sends a stream of those: while
    /// one read waits for its turn, more notifications for the window add nothing (it reads the latest state anyway).
    private func refresh(_ element: AXUIElement) {
        guard let wid = elementIndex[AXElementKey(element: element)], let pid = windows[wid]?.pid else { return }
        limiter.submit(pid: pid, key: "refresh \(wid)") { [weak self] in
            guard let snapshot = AXReader.snapshot(of: element, knownWID: wid) else { return }
            DispatchQueue.main.async {
                guard let self, let window = self.windows[wid] else { return }
                let title = snapshot.title.withoutFormatCharacters
                // Entering or leaving full screen only arrives as a move/resize: still worth redrawing the switcher for.
                let changed = window.isMinimized != snapshot.isMinimized || window.isFullscreen != snapshot.isFullscreen
                    || (!title.isEmpty && title != window.title)
                if !title.isEmpty { window.title = title }
                window.isMinimized = snapshot.isMinimized
                window.isFullscreen = snapshot.isFullscreen
                if let frame = snapshot.frame { window.frame = frame }
                if changed { self.notifyChange() }
            }
        }
    }

    // MARK: - Riffle's own windows

    private var ownWindowStamps = [CGWindowID: UInt64]()

    /// Riffle's own titled windows on screen. Read straight from AppKit, never over accessibility: AX calls into our
    /// own process from a background thread would race AppKit.
    var ownWindows: [NSWindow] {
        NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) && $0.cgWindowID != nil }
    }

    func ownWindow(_ wid: CGWindowID) -> NSWindow? {
        ownWindows.first { $0.cgWindowID == wid }
    }

    private func observeOwnWindows() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let window = note.object as? NSWindow, !(window is NSPanel), let wid = window.cgWindowID else { return }
            self.ownWindowStamps[wid] = self.nextStamp()
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow, let wid = window.cgWindowID else { return }
            self?.ownWindowStamps[wid] = nil
            self?.notifyChange()
        }
    }

    // MARK: - Queries

    /// The window that has keyboard focus right now, if Riffle knows it.
    var currentFocusedWID: CGWindowID? {
        guard let wid = lastFocusedWID, let window = windows[wid],
              window.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return wid
    }

    /// Windows that got focus but that AX hasn't let us inspect yet (a busy or just-launched app) join the switcher
    /// from what the WindowServer knows about them, so they're never missing; the next scan fills in the rest.
    func adoptPendingWindows() {
        let waiting = pendingFocusStamps.filter { windows[$0.key] == nil }
        guard !waiting.isEmpty else { return }
        let descriptions = WindowServerInfo.describe(Array(waiting.keys))
        for (wid, pending) in waiting {
            guard let description = descriptions[wid], description.layer == 0, description.isOnScreen, description.alpha > 0,
                  description.bounds.width >= WindowEligibility.minimumSize.width,
                  description.bounds.height >= WindowEligibility.minimumSize.height,
                  let app = apps[description.pid] else { continue }
            let window = TrackedWindow(wid: wid, pid: app.pid, app: app, element: nil,
                                       title: (description.name ?? "").withoutFormatCharacters, isMinimized: false, isFullscreen: false,
                                       frame: description.bounds, spaceIDs: PrivateAPI.spaces(forWindow: wid), focusStamp: pending.stamp)
            windows[wid] = window
            pendingFocusStamps[wid] = nil
            becameFocused(wid, stamp: pending.stamp)
            onWindowAdded?(wid)
            Log.info("adopted \(Log.app(app.bundleID, pid: app.pid)) #\(wid) from the WindowServer")
        }
    }

    /// Before a summon shows the model: forgets windows the WindowServer no longer has (closes we were never told
    /// about: some apps and system agents don't send AX destroy notifications) and background tabs, refreshes the
    /// Spaces, and notes apps with windows the model doesn't know for `refreshForSummon`. WindowServer queries only,
    /// so cheap enough for every summon.
    func pruneVanishedWindows() {
        reconcileWithWindowServer()
    }

    /// Who "the active app" and "the app under the pointer" are right now. A switcher session keeps the ones it began
    /// with, so its list doesn't follow the pointer around the panel. Nothing under the pointer (the desktop, the menu
    /// bar): the active app stands in.
    func anchor(for profile: ShortcutProfile) -> WindowFilter.Anchor {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard profile.apps == .appUnderPointer else { return WindowFilter.Anchor(frontPID: frontPID) }
        let pointerPID = WindowProbe.appUnderPointer(among: Set(apps.keys).union([ownPID]), ownPID: ownPID)
        return WindowFilter.Anchor(frontPID: frontPID, pointerPID: pointerPID ?? frontPID)
    }

    /// The switcher rows for one shortcut: what the store knows, chosen and ordered by `WindowFilter`.
    func items(for profile: ShortcutProfile, screen: NSScreen?, anchor: WindowFilter.Anchor? = nil) -> [SwitcherItem] {
        var context = WindowFilter.Context(anchor: anchor ?? self.anchor(for: profile))
        context.visibleSpaceIDs = topology.visibleSpaceIDs
        context.activeSpaceID = topology.activeSpaceID
        context.spaceNumbers = Dictionary(topology.spaces.map { ($0.id, $0.index) }, uniquingKeysWith: min)
        context.screenRect = screen.map { ScreenGeometry.axRect(fromCocoa: $0.frame) }
        context.exceptions = Prefs.shared.appExceptions
        // Windows whose Space no scan saw (often minimized before Riffle started) when the shortcut cares about desktops:
        // ask the WindowServer for it, and failing that whether the window is on screen.
        let needsSpaces = profile.place == .thisDesktop || profile.order == .byDesktop
        var foundSpaces = [CGWindowID: [CGSSpaceID]]()
        var onScreen = [CGWindowID: Bool]()
        if needsSpaces {
            let unknown = windows.values.filter { $0.spaceIDs.isEmpty }.map(\.wid)
            for wid in unknown {
                let spaces = PrivateAPI.spaces(forWindow: wid)
                if !spaces.isEmpty { foundSpaces[wid] = spaces }
            }
            for (wid, description) in WindowServerInfo.describe(unknown.filter { foundSpaces[$0] == nil }) {
                onScreen[wid] = description.isOnScreen
            }
        }
        var filterWindows = windows.values.map { window in
            WindowFilter.Window(wid: window.wid, pid: window.pid, title: window.title, isMinimized: window.isMinimized,
                                isFullscreen: window.isFullscreen, frame: window.frame,
                                spaceIDs: window.spaceIDs.isEmpty ? foundSpaces[window.wid] ?? [] : window.spaceIDs,
                                isOnScreen: onScreen[window.wid], focusStamp: window.focusStamp)
        }
        var filterApps = apps.values.map { app in
            WindowFilter.App(pid: app.pid, bundleID: app.bundleID, name: app.name, isHidden: app.isHidden,
                             activationStamp: app.activationStamp, launchDate: app.running.launchDate,
                             canListWithoutWindows: app.running.activationPolicy == .regular && !app.running.isTerminated
                                 && !app.isFinder && !isQuitting(app.pid))
        }
        // Riffle's own windows (Settings, welcome) are listed like any other app's.
        let own = ownWindows
        for window in own {
            guard let wid = window.cgWindowID else { continue }
            filterWindows.append(WindowFilter.Window(
                wid: wid, pid: ownPID, title: window.title, isMinimized: window.isMiniaturized,
                isFullscreen: window.styleMask.contains(.fullScreen), frame: ScreenGeometry.axRect(fromCocoa: window.frame),
                spaceIDs: needsSpaces ? PrivateAPI.spaces(forWindow: wid) : [],
                isOnScreen: window.isOnActiveSpace && !window.isMiniaturized, focusStamp: ownWindowStamps[wid] ?? 0))
        }
        filterApps.append(WindowFilter.App(pid: ownPID, bundleID: Bundle.main.bundleIdentifier, name: "Riffle",
                                           launchDate: NSRunningApplication.current.launchDate, canListWithoutWindows: false))
        return WindowFilter.select(windows: filterWindows, apps: filterApps, profile: profile, context: context).compactMap { kind in
            switch kind {
            case .window(let wid):
                if let window = windows[wid] { return makeItem(window) }
                return own.first { $0.cgWindowID == wid }.flatMap(makeItem(own:))
            case .app(let pid):
                return apps[pid].map(makeItem(app:))
            }
        }
    }

    private func makeItem(_ window: TrackedWindow) -> SwitcherItem? {
        guard let app = window.app else { return nil }
        let visible = topology.visibleSpaceIDs
        let onOtherSpace = !window.isMinimized && !window.spaceIDs.isEmpty && !window.spaceIDs.contains(where: visible.contains)
        let spaceIndex = onOtherSpace ? topology.desktopNumber(of: window.spaceIDs) : nil
        return SwitcherItem(kind: .window(window.wid), pid: window.pid, appName: app.name, title: window.title, icon: app.icon,
                            isMinimized: window.isMinimized, isHidden: app.isHidden, isFullscreen: window.isFullscreen,
                            otherSpaceIndex: spaceIndex, frame: window.frame, bundleID: app.bundleID,
                            bundlePath: DockBadges.key(for: app.bundleURL))
    }

    private func makeItem(app: TrackedApp) -> SwitcherItem {
        SwitcherItem(kind: .app(app.pid), pid: app.pid, appName: app.name, title: "", icon: app.icon, isMinimized: false,
                     isHidden: app.isHidden, isFullscreen: false, otherSpaceIndex: nil, frame: .zero, bundleID: app.bundleID,
                     bundlePath: DockBadges.key(for: app.bundleURL))
    }

    private func makeItem(own window: NSWindow) -> SwitcherItem? {
        guard let wid = window.cgWindowID else { return nil }
        return SwitcherItem(kind: .window(wid), pid: ownPID, appName: "Riffle", title: window.title, icon: NSApp.applicationIconImage,
                            isMinimized: window.isMiniaturized, isHidden: false, isFullscreen: window.styleMask.contains(.fullScreen),
                            otherSpaceIndex: nil, frame: ScreenGeometry.axRect(fromCocoa: window.frame), bundleID: Bundle.main.bundleIdentifier)
    }
}

/// AX observer callbacks arrive on the main run loop (that's where the sources are scheduled).
private func riffleAXCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    let pid = pid_t(truncatingIfNeeded: Int(bitPattern: refcon))
    WindowStore.shared.handle(notification as String, element: element, pid: pid)
}

enum ScreenGeometry {
    /// Height of the primary display, which anchors both coordinate systems.
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Cocoa (bottom-left origin) → AX/CoreGraphics (top-left origin).
    static func axRect(fromCocoa rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// AX/CoreGraphics (top-left origin) → Cocoa (bottom-left origin).
    static func cocoaRect(fromAX rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func screen(containingAX rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { axRect(fromCocoa: $0.frame).contains(center) }
    }

    static var screenUnderMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }
}

/// Receives the screen-unlocked notification (the selector-based API is the one that can ask for immediate delivery).
final class UnlockObserver: NSObject {
    var onUnlock: (() -> Void)?

    @objc func unlocked(_ notification: Notification) {
        DispatchQueue.main.async { self.onUnlock?() }
    }
}
