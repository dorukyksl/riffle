import Cocoa

/// Focusing and manipulating other apps' windows. AX writes run on a serial background queue per app: a busy app can
/// block an AX call for up to the messaging timeout, the main thread must never wait on that, and neither must a
/// request for another app.
enum WindowActions {
    private static let lanes = ActionLanes(label: "riffle.actions", qos: .userInteractive)
    private static let generations = FocusGenerations()

    struct FocusTarget {
        let wid: CGWindowID
        let pid: pid_t
        let element: AXUIElement?
        let isMinimized: Bool
        let spaceIDs: [CGSSpaceID]
    }

    /// Brings one specific window to the front, on whichever Space it lives, and gives it keyboard focus.
    /// `onFronted` runs on main as soon as the window's app is in front.
    static func focus(_ target: FocusTarget, onFronted: @escaping () -> Void = {}) {
        let topology = WindowStore.shared.topology
        let isCrossSpace = !target.isMinimized && !target.spaceIDs.isEmpty
            && !target.spaceIDs.contains(where: topology.visibleSpaceIDs.contains)
        let origin = isCrossSpace ? NSWorkspace.shared.frontmostApplication.map {
            FocusSequence.Origin(space: topology.activeSpaceID, frontPID: $0.processIdentifier)
        } : nil
        let token = generations.begin()
        // Fronting a process doesn't unhide it: a hidden app's window would stay invisible.
        if let running = NSRunningApplication(processIdentifier: target.pid), running.isHidden { running.unhide() }
        let lane = lanes.queue(for: target.pid)
        lane.async {
            let done = FocusSequence.run(target, token: token, generations: generations, driver: SystemFocusDriver(), origin: origin,
                                         onFronted: { DispatchQueue.main.async(execute: onFronted) },
                                         cannotFront: {
                                             DispatchQueue.main.async {
                                                 NSRunningApplication(processIdentifier: target.pid)?.activate(options: [.activateAllWindows])
                                                 onFronted()
                                             }
                                         })
            if done { verify(target, token: token, on: lane) }
        }
    }

    fileprivate static func raise(_ target: FocusTarget) {
        if let element = target.element, element.perform(kAXRaiseAction) == .success { return }
        // The cached element may have gone stale (apps sometimes rebuild their AX tree): find it again by id.
        findElement(target)?.perform(kAXRaiseAction)
    }

    fileprivate static func findElement(_ target: FocusTarget) -> AXUIElement? {
        let app = AXUIElementCreateApplication(target.pid)
        app.setMessagingTimeout(0.5)
        guard case .windows(let elements) = AXReader.windows(ofApp: app) else { return nil }
        return elements.first { $0.windowID == target.wid }
    }

    /// Occasionally every step reports success and another window still ends up on top, or the app doesn't come
    /// forward at all (a Space switch can swallow the request). Check once the switch has settled: ask again, then
    /// the ordinary way, and raise the right window. Runs on the target app's lane, and stands down as soon as a newer
    /// request came in.
    private static func verify(_ target: FocusTarget, token: UInt64, on lane: DispatchQueue, attempt: Int = 0) {
        lane.asyncAfter(deadline: .now() + (attempt == 0 ? 0.15 : 0.3)) {
            guard generations.isCurrent(token) else { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
                guard attempt < 2 else { return }
                if attempt == 0, var psn = PrivateAPI.processSerialNumber(for: target.pid) {
                    PrivateAPI.setFrontProcess(&psn, window: target.wid)
                    PrivateAPI.makeKeyWindow(&psn, window: target.wid)
                    raise(target)
                } else {
                    DispatchQueue.main.async {
                        guard generations.isCurrent(token) else { return }
                        NSRunningApplication(processIdentifier: target.pid)?.activate(options: [])
                    }
                }
                verify(target, token: token, on: lane, attempt: attempt + 1)
                return
            }
            let app = AXUIElementCreateApplication(target.pid)
            app.setMessagingTimeout(0.25)
            guard let focused = AXReader.focusedWindow(ofApp: app), let focusedWID = focused.windowID,
                  focusedWID != target.wid else { return }
            // That read can take a while on a busy app: a newer request may own the screen by now.
            guard generations.isCurrent(token) else { return }
            if var psn = PrivateAPI.processSerialNumber(for: target.pid) {
                PrivateAPI.makeKeyWindow(&psn, window: target.wid)
            }
            raise(target)
        }
    }

    /// For apps without windows: ask the app to reopen, like clicking its Dock icon.
    static func activate(pid: pid_t, bundleURL: URL?) {
        _ = generations.begin()
        guard let running = NSRunningApplication(processIdentifier: pid) else { return }
        if running.isHidden { running.unhide() }
        if let bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { app, _ in
                if app == nil { running.activate(options: [.activateAllWindows]) }
            }
        } else {
            running.activate(options: [.activateAllWindows])
        }
    }

    static func close(_ element: AXUIElement?, isFullscreen: Bool) {
        guard let element else {
            Log.warn("close: the window has no accessibility element yet")
            return NSSound.beep()
        }
        func press() {
            guard let button = element.element(kAXCloseButtonAttribute) else {
                Log.warn("close: the window has no close button")
                return DispatchQueue.main.async { NSSound.beep() }
            }
            let result = button.perform(kAXPressAction)
            if result != .success { Log.warn("close: pressing the close button failed (\(result.rawValue))") }
        }
        let lane = lane(for: element)
        lane.async {
            if isFullscreen {
                element.set(kAXFullScreenAttribute, kCFBooleanFalse)
                // AX ignores the close button while the window animates out of fullscreen.
                lane.asyncAfter(deadline: .now() + 1.0) { press() }
            } else {
                press()
            }
        }
    }

    static func toggleMinimized(_ element: AXUIElement?, isMinimized: Bool, isFullscreen: Bool) {
        guard let element else { return NSSound.beep() }
        let lane = lane(for: element)
        lane.async {
            if isFullscreen {
                element.set(kAXFullScreenAttribute, kCFBooleanFalse)
                lane.asyncAfter(deadline: .now() + 1.0) { element.set(kAXMinimizedAttribute, kCFBooleanTrue) }
            } else {
                element.set(kAXMinimizedAttribute, isMinimized ? kCFBooleanFalse : kCFBooleanTrue)
            }
        }
    }

    static func toggleFullscreen(_ element: AXUIElement?, isFullscreen: Bool) {
        guard let element else { return NSSound.beep() }
        lane(for: element).async {
            element.set(kAXFullScreenAttribute, isFullscreen ? kCFBooleanFalse : kCFBooleanTrue)
        }
    }

    static func quit(pid: pid_t) {
        // Finder can't be quit: macOS keeps it running.
        guard let running = NSRunningApplication(processIdentifier: pid), running.bundleIdentifier != "com.apple.finder" else {
            return NSSound.beep()
        }
        if !running.terminate() { Log.warn("quit: \(Log.app(running.bundleIdentifier, pid: pid)) refused to terminate") }
    }

    static func toggleHidden(pid: pid_t) {
        guard let running = NSRunningApplication(processIdentifier: pid) else { return }
        if running.isHidden { running.unhide() } else { running.hide() }
    }

    /// The lane of the app that owns `element` (reading the pid is local, no IPC).
    private static func lane(for element: AXUIElement) -> DispatchQueue {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return lanes.queue(for: pid)
    }
}

/// One serial queue per app. Requests for the same app keep their order; a hung app's call holds up only that app.
/// Thread-safe.
final class ActionLanes {
    private let label: String
    private let qos: DispatchQoS
    /// Past this many lanes, the ones of apps that have quit are let go.
    private let limit: Int
    private let isAlive: (pid_t) -> Bool
    private let lock = NSLock()
    private var queues = [pid_t: DispatchQueue]()

    init(label: String, qos: DispatchQoS, limit: Int = 32,
         isAlive: @escaping (pid_t) -> Bool = { NSRunningApplication(processIdentifier: $0) != nil }) {
        self.label = label
        self.qos = qos
        self.limit = limit
        self.isAlive = isAlive
    }

    func queue(for pid: pid_t) -> DispatchQueue {
        lock.lock()
        defer { lock.unlock() }
        if let queue = queues[pid] { return queue }
        // A queue with work still pending stays alive on its own until that work is done.
        if queues.count >= limit { queues = queues.filter { isAlive($0.key) } }
        let queue = DispatchQueue(label: "\(label).\(pid)", qos: qos)
        queues[pid] = queue
        return queue
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return queues.count
    }
}

/// Each focus request takes a new generation; an older request stands down as soon as it sees it isn't current.
final class FocusGenerations {
    private let lock = NSLock()
    private var current: UInt64 = 0

    func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        current += 1
        return current
    }

    func isCurrent(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return current == token
    }
}

/// The side effects of focusing a window, so the sequencing can be tested without touching real windows.
protocol FocusDriver {
    /// Can wait out a busy app's timeout.
    func unminimize(_ target: WindowActions.FocusTarget)
    /// Fronts the process with exactly this window; false if the process can't be fronted this way.
    func front(_ target: WindowActions.FocusTarget) -> Bool
    func makeKey(_ target: WindowActions.FocusTarget)
    /// Can wait out a busy app's timeout.
    func raise(_ target: WindowActions.FocusTarget)
    func restoreSpaceFront(space: CGSSpaceID, pid: pid_t)
}

enum FocusSequence {
    /// The Space we leave for a window on another one, and the app that was in front there.
    struct Origin: Equatable {
        let space: CGSSpaceID
        let frontPID: pid_t
    }

    /// 1. unminimize, 2. front the process with exactly this window, 3. make it key, 4. raise it within its app, 5. put
    /// back the front app of the Space we left. Lanes are per app, so a newer request for another app doesn't wait for
    /// this one: after every step that can block, a request that is no longer the newest stops, before it can pull its
    /// app in front of the newer one's. Returns whether it ran to the end (then it is worth verifying).
    @discardableResult
    static func run(_ target: WindowActions.FocusTarget, token: UInt64, generations: FocusGenerations, driver: FocusDriver,
                    origin: Origin?, onFronted: () -> Void, cannotFront: () -> Void) -> Bool {
        guard generations.isCurrent(token) else { return false }
        if target.isMinimized {
            driver.unminimize(target)
            guard generations.isCurrent(token) else { return false }
        }
        guard driver.front(target) else {
            cannotFront()
            return false
        }
        onFronted()
        guard generations.isCurrent(token) else { return false }
        driver.makeKey(target)
        driver.raise(target)
        guard generations.isCurrent(token) else { return false }
        // Fronting a window on another Space makes macOS remember its app as front on the Space we left.
        if let origin, origin.frontPID != target.pid { driver.restoreSpaceFront(space: origin.space, pid: origin.frontPID) }
        return true
    }
}

/// The real thing: SkyLight to front and key the window, AX to unminimize and raise it.
struct SystemFocusDriver: FocusDriver {
    func unminimize(_ target: WindowActions.FocusTarget) {
        // The cached element may have gone stale: then find the window again by id to bring it back.
        if target.element?.set(kAXMinimizedAttribute, kCFBooleanFalse) != .success, let fresh = WindowActions.findElement(target) {
            fresh.set(kAXMinimizedAttribute, kCFBooleanFalse)
        }
    }

    func front(_ target: WindowActions.FocusTarget) -> Bool {
        guard var psn = PrivateAPI.processSerialNumber(for: target.pid) else { return false }
        PrivateAPI.setFrontProcess(&psn, window: target.wid)
        return true
    }

    func makeKey(_ target: WindowActions.FocusTarget) {
        guard var psn = PrivateAPI.processSerialNumber(for: target.pid) else { return }
        PrivateAPI.makeKeyWindow(&psn, window: target.wid)
    }

    func raise(_ target: WindowActions.FocusTarget) {
        WindowActions.raise(target)
    }

    func restoreSpaceFront(space: CGSSpaceID, pid: pid_t) {
        guard let psn = PrivateAPI.processSerialNumber(for: pid) else { return }
        PrivateAPI.setSpaceFrontProcess(space, psn)
    }
}
