import Carbon
import Cocoa
import os

/// One look at whether the hold modifiers are still down, and whether that look needs a timer to follow it up.
///
/// Two kinds of evidence, combined so a release is never missed and never invented:
/// - **events**: flagsChanged seen by a passive event tap (instant, needs Accessibility) and by Riffle's own key panel;
/// - **hardware**: the keyboard's modifier state (needs nothing, but nothing announces its changes).
/// Remapping tools synthesize modifiers that only show up as events, never in the hardware state, while a tap that was
/// interrupted can miss events that the hardware state still shows. So a modifier counts as held if either says so,
/// and only the hardware is trusted once the tap has been interrupted. Any change arrives as an event while the tap
/// runs and both agree; otherwise (no tap, secure keyboard entry hiding events from taps, or the two disagreeing,
/// e.g. the hardware state a beat behind the event) only polling notices the release.
struct HoldReading: Equatable {
    let isHeld: Bool
    let needsPolling: Bool

    /// `events`: the modifiers of the latest event, nil when there's no event stream to trust.
    init(hold: NSEvent.ModifierFlags, hardware: NSEvent.ModifierFlags, events: NSEvent.ModifierFlags?, secureInput: Bool) {
        // Nothing to hold (a switcher opened from the menu bar): released from the start.
        guard !hold.isEmpty else {
            isHeld = false
            needsPolling = false
            return
        }
        let hardwareHeld = hardware.contains(hold)
        guard let events else {
            isHeld = hardwareHeld
            needsPolling = true
            return
        }
        let eventsHeld = events.contains(hold)
        isHeld = hardwareHeld || eventsHeld
        needsPolling = secureInput || hardwareHeld != eventsHeld
    }
}

/// Tells the switcher when the held modifier (⌥ by default) is released. The event tap runs on a thread of its own, so a
/// busy main thread can neither delay it nor get it disabled for being slow; the keyboard state is polled (at 30 Hz)
/// only while events alone can't be counted on (see `HoldReading`).
final class ModifierMonitor {
    static let shared = ModifierMonitor()

    /// Called on the main thread whenever the modifier evidence may have changed.
    var onChange: (() -> Void)?

    private struct EventState {
        /// `NSEvent.ModifierFlags` raw value of the latest event.
        var flags: UInt = 0
        /// When that event happened: the tap and the panel's own monitor report the same events, each at its own pace,
        /// and an older one must not overwrite a newer one.
        var timestamp: CGEventTimestamp = 0
        var interruptedAt: TimeInterval = -1
        var tapRunning = false
        /// The tap's port: made and removed on the main thread, switched back on from the tap's own thread, so it's
        /// only ever read or written under the lock.
        var tap: CFMachPort?
    }

    /// Unchecked: a `CFMachPort` isn't `Sendable`, and the lock is what makes sharing it safe.
    private let state = OSAllocatedUnfairLock(uncheckedState: EventState())
    private var pollTimer: Timer?

    static var hardwareFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))
            .intersection(.deviceIndependentFlagsMask)
    }

    var hasEventTap: Bool { state.withLockUnchecked { $0.tap != nil } }

    /// Whether `modifiers` are held right now; `since` is when the current session started. Main thread. Also starts or
    /// stops the fallback poll, which runs exactly while this answer can't be trusted to change with an event.
    func isHolding(_ modifiers: NSEvent.ModifierFlags, since: TimeInterval) -> Bool {
        let events = state.withLockUnchecked { $0 }
        let tapTrusted = events.tapRunning && events.interruptedAt < since && events.tap.map { CGEvent.tapIsEnabled(tap: $0) } == true
        let reading = HoldReading(hold: modifiers, hardware: ModifierMonitor.hardwareFlags,
                                  events: tapTrusted ? NSEvent.ModifierFlags(rawValue: events.flags) : nil,
                                  secureInput: IsSecureEventInputEnabled())
        if reading.needsPolling { startPolling() } else { stopPolling() }
        return reading.isHeld
    }

    /// A listen-only tap: it observes modifier changes and never alters or delays typing.
    @discardableResult
    func installEventTapIfPossible() -> Bool {
        if hasEventTap { return true }
        guard Permissions.accessibility else { return false }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: riffleModifierTapCallback, userInfo: nil),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            Log.warn("modifier event tap unavailable; relying on the keyboard state")
            return false
        }
        adopt(tap)
        let thread = Thread { [weak self] in
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
            // Only returns once the tap's port is gone.
            self?.tapStopped(tap)
        }
        thread.name = "Riffle modifier tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    /// Events come from `tap` from now on, starting from the keyboard's state.
    func adopt(_ tap: CFMachPort) {
        let hardware = ModifierMonitor.hardwareFlags
        state.withLockUnchecked {
            $0.tap = tap
            $0.flags = hardware.rawValue
            $0.tapRunning = true
        }
    }

    /// Accessibility was taken away: the tap would only be disabled over and over. Invalidating its port ends its thread
    /// (see `tapStopped`); `installEventTapIfPossible` makes a new one once the permission is back.
    func removeEventTap() {
        let removed = state.withLockUnchecked { state -> CFMachPort? in
            defer { state.tap = nil }
            return state.tap
        }
        guard let removed else { return }
        CFMachPortInvalidate(removed)
    }

    /// The tap macOS switched off, to switch back on; nil once it's been removed. Any thread.
    func tapToReenable() -> CFMachPort? {
        state.withLockUnchecked { $0.tap }
    }

    /// A tap's thread ended, its port gone. False when a newer tap had already taken its place, which runs on.
    @discardableResult
    func forgetTap(_ stopped: CFMachPort) -> Bool {
        state.withLockUnchecked { state in
            guard state.tap == nil || state.tap === stopped else { return false }
            state.tap = nil
            state.tapRunning = false
            return true
        }
    }

    /// On the tap's thread.
    fileprivate func handleTap(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = tapToReenable() { CGEvent.tapEnable(tap: tap, enable: true) }
            let now = ProcessInfo.processInfo.systemUptime
            let hardware = ModifierMonitor.hardwareFlags
            // Whatever happened while it was off is lost: carry on from the keyboard's state.
            state.withLockUnchecked {
                $0.interruptedAt = now
                $0.flags = hardware.rawValue
            }
            Log.warn("modifier tap was disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input")); re-enabled")
        case .flagsChanged:
            record(NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)), at: event.timestamp)
        default:
            return
        }
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    /// On the tap's thread, as it ends.
    private func tapStopped(_ tap: CFMachPort) {
        guard forgetTap(tap) else { return }
        Log.warn("modifier tap stopped; relying on the keyboard state")
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    /// flagsChanged that reached Riffle's own key panel. Main thread.
    func handleLocalEvent(_ event: NSEvent) {
        record(event.modifierFlags, at: event.cgEvent?.timestamp)
        onChange?()
    }

    private func record(_ flags: NSEvent.ModifierFlags, at timestamp: CGEventTimestamp?) {
        let flags = flags.intersection(.deviceIndependentFlagsMask).rawValue
        state.withLockUnchecked { state in
            if let timestamp {
                guard timestamp >= state.timestamp else { return }
                state.timestamp = timestamp
            }
            state.flags = flags
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        // The first look comes soon: when the hardware state is merely a beat behind an event, that's all it takes.
        let timer = Timer(fire: Date(timeIntervalSinceNow: 0.01), interval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.onChange?()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

private func riffleModifierTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    ModifierMonitor.shared.handleTap(type: type, event: event)
    return Unmanaged.passUnretained(event)
}
