import Cocoa

/// The key recorders of Settings, one at a time. While one records, Riffle's global shortcuts are let go, so the keys
/// pressed reach it instead of summoning the switcher; they come back the moment it stops, whatever stops it: a key, a
/// second click, another recorder starting, the recorder going away, or the window it's in (or Riffle) losing the
/// keyboard, so a recording can't be left behind with the shortcuts gone. Main thread only.
final class KeyRecording: ObservableObject {
    static let shared = KeyRecording()

    /// What it asks of the rest of Riffle and of AppKit, replaceable in tests: they must never touch real shortcuts.
    struct System {
        var pauseShortcuts: () -> Void
        /// Registers the shortcuts as configured (by then nothing records).
        var resumeShortcuts: () -> Void
        var addMonitor: (NSEvent.EventTypeMask, @escaping (NSEvent) -> NSEvent?) -> Any?
        var removeMonitor: (Any) -> Void
        /// The window the keyboard goes to now: the recording ends when it stops being key.
        var keyWindow: () -> AnyObject?
        var notifications: NotificationCenter
    }

    /// The recorder that's recording.
    @Published private(set) var recorder: UUID?
    var isRecording: Bool { recorder != nil }

    private let system: System
    private var monitor: Any?
    private var observers = [NSObjectProtocol]()

    init(system: System = .live) {
        self.system = system
    }

    /// `recorder` records from now on: keys of `events` go to `handle` (whatever it returns goes on to the app), and any
    /// other recording stops. The shortcuts stay off until `stop(recorder)`, or one of the ways a recording ends by itself.
    func start(_ recorder: UUID, events: NSEvent.EventTypeMask, handle: @escaping (NSEvent) -> NSEvent?) {
        // Handed over from another recorder, the shortcuts simply stay off.
        let wasRecording = isRecording
        endListening()
        self.recorder = recorder
        if !wasRecording { system.pauseShortcuts() }
        monitor = system.addMonitor(events) { [weak self] event in
            guard self?.recorder == recorder else { return event }
            return handle(event)
        }
        let notifications = system.notifications
        let end: (Notification) -> Void = { [weak self] _ in self?.stop() }
        observers.append(notifications.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil, using: end))
        if let window = system.keyWindow() {
            observers.append(notifications.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: nil, using: end))
        }
    }

    /// Ends `recorder`'s recording, if it's the one recording: a recorder that goes away mustn't end another's.
    func stop(_ recorder: UUID) {
        guard self.recorder == recorder else { return }
        stop()
    }

    /// Ends whatever is recording, and gives the shortcuts back.
    func stop() {
        guard isRecording else { return }
        endListening()
        recorder = nil
        system.resumeShortcuts()
    }

    private func endListening() {
        if let monitor { system.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { system.notifications.removeObserver(observer) }
        observers = []
    }
}

extension KeyRecording.System {
    static let live = KeyRecording.System(
        pauseShortcuts: { HotkeyCenter.shared.unregisterAll() },
        resumeShortcuts: { (NSApp.delegate as? AppDelegate)?.registerHotkeys() },
        addMonitor: { NSEvent.addLocalMonitorForEvents(matching: $0, handler: $1) },
        removeMonitor: { NSEvent.removeMonitor($0) },
        keyWindow: { NSApp.keyWindow },
        notifications: .default)
}
