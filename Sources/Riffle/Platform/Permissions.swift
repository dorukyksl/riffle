import Cocoa
import ApplicationServices

enum Permissions {
    /// Needed to read windows of other apps, focus them and listen to modifier keys.
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Needed for live thumbnails and for window titles of apps that don't expose them over accessibility.
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static var allGranted: Bool { accessibility && screenRecording }

    /// Adds Riffle to the Accessibility list and shows the system prompt.
    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Adds Riffle to the Screen Recording list and shows the system prompt (only the first time).
    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// What has happened to the two permissions since launch, and what Riffle does about each change. Pure: it's fed
/// readings and answers with effects, so every transition can be tested.
///
/// Accessibility can come and go while Riffle runs: without it Riffle stops its engine (no AX work, no event tap, ⌘⇥ back
/// to macOS) and starts it again when it's back, no relaunch needed. Screen Recording only takes effect at launch:
/// taken away, previews stop; given, they need a restart.
struct PermissionTracker: Equatable {
    enum Accessibility: Equatable {
        /// Not had since launch: the engine hasn't started.
        case waiting
        case granted
        /// Taken away while Riffle ran: the engine stopped until it's back.
        case revoked
    }

    enum ScreenRecording: Equatable {
        case granted
        /// Not had since launch: no previews.
        case missing
        /// Taken away while Riffle ran: previews stopped.
        case revoked
        /// Given while Riffle ran: previews come after a restart.
        case needsRestart
    }

    enum Effect: Equatable {
        /// Start (or start again) the engine and the event tap.
        case startEngine
        /// Stop all AX work and the event tap, and give ⌘⇥ back.
        case stopEngine
        /// Stop capturing and drop the previews taken.
        case stopPreviews
        /// Offer to restart Riffle, for previews.
        case offerRestart
    }

    private(set) var accessibility: Accessibility
    private(set) var screenRecording: ScreenRecording
    private let screenRecordingAtLaunch: Bool

    init(accessibility: Bool, screenRecording: Bool) {
        self.accessibility = accessibility ? .granted : .waiting
        self.screenRecording = screenRecording ? .granted : .missing
        screenRecordingAtLaunch = screenRecording
    }

    /// Takes in a new reading; the effects of whatever changed, in order (none when nothing did).
    mutating func update(accessibility hasAccessibility: Bool, screenRecording hasScreenRecording: Bool) -> [Effect] {
        var effects = [Effect]()
        switch (accessibility, hasAccessibility) {
        case (.waiting, true), (.revoked, true):
            accessibility = .granted
            effects.append(.startEngine)
        case (.granted, false):
            accessibility = .revoked
            effects.append(.stopEngine)
        default:
            break
        }
        switch (screenRecording, hasScreenRecording) {
        case (.granted, false):
            screenRecording = .revoked
            effects.append(.stopPreviews)
        case (.missing, true), (.revoked, true):
            // Capturing starts with the process: whether it was never had or taken back meanwhile, only a restart helps.
            screenRecording = .needsRestart
            effects.append(.offerRestart)
        case (.needsRestart, false):
            // Taken back before the restart: nothing to restart for.
            screenRecording = screenRecordingAtLaunch ? .revoked : .missing
        default:
            break
        }
        return effects
    }

    /// Riffle can't switch windows: the menu bar icon says so, and its menu offers the permission.
    var needsAccessibility: Bool { accessibility != .granted }
    var needsRestart: Bool { screenRecording == .needsRestart }
}

/// Watches both permissions while Riffle runs and acts on every change (`onChange`): within moments of a change in System
/// Settings (it announces Accessibility changes), on every summon, and on a slow timer for whatever slips through.
final class PermissionMonitor: ObservableObject {
    static let shared = PermissionMonitor()

    @Published private(set) var tracker = PermissionTracker(accessibility: Permissions.accessibility,
                                                            screenRecording: Permissions.screenRecording)
    /// Told about each change, with its effects. Main thread.
    var onChange: ([PermissionTracker.Effect]) -> Void = { _ in }
    private var timer: Timer?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        // Posted whenever the Accessibility list changes, for any app. Delivered at once: AppKit holds back distributed
        // notifications while the app isn't active, and Riffle rarely is.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(accessibilityListChanged),
                                                            name: Notification.Name("com.apple.accessibility.api"), object: nil,
                                                            suspensionBehavior: .deliverImmediately)
        schedule()
    }

    @objc private func accessibilityListChanged(_ notification: Notification) {
        // The notification can come before the change is readable: look again as it settles.
        for delay in [0.25, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.check() }
        }
    }

    /// Reads both permissions: the state at once, and its effects on the next turn of the run loop (this can run inside a
    /// hotkey's handler, and the effects register hotkeys again). Cheap: fine on every summon.
    @discardableResult
    func check() -> PermissionTracker {
        var next = tracker
        let effects = next.update(accessibility: Permissions.accessibility, screenRecording: Permissions.screenRecording)
        guard next != tracker else { return tracker }
        tracker = next
        Log.info("permissions: accessibility \(next.accessibility), screen recording \(next.screenRecording)")
        schedule()
        DispatchQueue.main.async { self.onChange(effects) }
        return tracker
    }

    /// Once a second while Riffle waits for Accessibility, so it starts the moment it's given; every five otherwise.
    private func schedule() {
        guard started else { return }
        let interval: TimeInterval = tracker.needsAccessibility ? 1 : 5
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.check() }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
