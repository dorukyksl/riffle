import Cocoa
import Combine

/// Lets go of Riffle's shortcuts while an app that wants them for itself is in front (Settings → Exceptions: a virtual
/// machine or a remote desktop, typically only in full screen), and takes them back once it isn't. It tells
/// `AppDelegate.registerHotkeys`, which asks `isSuspended`; the decision itself is `AppException.shortcutRule`.
final class ShortcutSuspension {
    static let shared = ShortcutSuspension()

    private var started = false
    private var suspended = false
    /// Leaving or entering a full screen of the app's own making changes no Space and sends no notification: while the
    /// app in front has a full-screen-only rule, look once a second.
    private var poll: Timer?
    private var cancellable: AnyCancellable?

    /// Starts watching on first use.
    var isSuspended: Bool {
        if !started { start() }
        return suspended
    }

    private func start() {
        started = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.update() }
        }
        // @Published fires before the new value is stored: hop once so the check sees it.
        cancellable = Prefs.shared.$appExceptions.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }
        suspended = evaluate()
        if suspended { Log.info("shortcuts left to \(Log.app(NSWorkspace.shared.frontmostApplication))") }
    }

    private func update() {
        let now = evaluate()
        guard now != suspended else { return }
        suspended = now
        Log.info(now ? "shortcuts left to \(Log.app(NSWorkspace.shared.frontmostApplication))" : "shortcuts back")
        (NSApp.delegate as? AppDelegate)?.registerHotkeys()
    }

    private func evaluate() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() else {
            setPolling(false)
            return false
        }
        let rule = AppException.shortcutRule(for: front.bundleIdentifier, in: Prefs.shared.appExceptions)
        setPolling(rule == .whileFullscreen)
        return AppException.ignoresShortcuts(rule, isFullscreen: rule == .whileFullscreen && WindowProbe.isFullscreen(pid: front.processIdentifier))
    }

    private func setPolling(_ on: Bool) {
        guard on != (poll != nil) else { return }
        poll?.invalidate()
        poll = nil
        guard on else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }
}
