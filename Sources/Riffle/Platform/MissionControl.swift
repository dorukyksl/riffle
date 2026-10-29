import Cocoa

/// Mission Control (and App Exposé) is drawn by the Dock. A switcher summoned on top of it would only confuse, so
/// summons ask the Dock first.
///
/// The WindowServer's window list can't tell on its own: the Dock's own window already spans the whole display at the
/// Dock level whether Mission Control is up or not. Its accessibility tree can: normally it holds one list (the Dock's
/// icons), and while Mission Control is up its view is there too, a group identified "mc" (seen on macOS 26, with one
/// "mc.display" group per display inside). Usually the system keeps the shortcut from reaching Riffle then anyway; this
/// covers the moments it doesn't.
enum MissionControl {
    struct Element: Equatable {
        var role: String?
        var subrole: String? = nil
        var identifier: String? = nil
        var title: String? = nil
    }

    static func isShowing(dockChildren: [Element]) -> Bool {
        dockChildren.contains { $0.role == kAXGroupRole && $0.identifier == "mc" }
    }

    private static let queue = DispatchQueue(label: "riffle.missioncontrol", qos: .userInteractive)
    private static let lock = NSLock()
    /// A question to the Dock is still out (lock).
    private static var asking = false
    private static var dock: (pid: pid_t, element: AXUIElement)? // queue
    private static var lastReport: String?                       // queue

    /// Whether Mission Control is showing. Waits at most `wait` for the Dock (it answers in a few hundredths of a
    /// millisecond) and fails open: no answer in time, an error or no permission all mean "not showing", and while an
    /// earlier question is still unanswered (a hung Dock) nobody waits again.
    static func isShowing(wait: TimeInterval = 0.01) -> Bool {
        guard beginAsking() else { return false }
        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        queue.async {
            answer.value = readDock()
            endAsking()
            done.signal()
        }
        guard done.wait(timeout: .now() + wait) == .success else {
            Log.warn("Mission Control check: the Dock didn't answer in time")
            return false
        }
        return answer.value
    }

    /// Opens the connection to the Dock before the first summon needs it (the first question to an app is slow).
    static func warmUp() {
        guard beginAsking() else { return }
        queue.async {
            _ = readDock()
            endAsking()
        }
    }

    private static func beginAsking() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !asking else { return false }
        asking = true
        return true
    }

    private static func endAsking() {
        lock.lock()
        asking = false
        lock.unlock()
    }

    private static func readDock() -> Bool {
        guard let element = dockElement() else { return false }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw) == .success,
              let children = raw as? [AXUIElement] else { return false }
        let elements = children.map { child -> Element in
            let values = child.values([kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXTitleAttribute]) ?? [:]
            return Element(role: values[kAXRoleAttribute] as? String, subrole: values[kAXSubroleAttribute] as? String,
                           identifier: values[kAXIdentifierAttribute] as? String, title: values[kAXTitleAttribute] as? String)
        }
        let showing = isShowing(dockChildren: elements)
        // What the Dock showed, once per change: the evidence for (or against) this rule on a real Mac.
        let report = showing ? elements.map { element in
            [element.role, element.subrole, element.identifier, element.title.map { "\"\($0)\"" }].compactMap { $0 }.joined(separator: " ")
        }.joined(separator: ", ") : nil
        if let report, report != lastReport { Log.info("Mission Control is showing (the Dock lists: \(report)): no switcher") }
        lastReport = report
        return showing
    }

    private static func dockElement() -> AXUIElement? {
        if let dock, NSRunningApplication(processIdentifier: dock.pid)?.isTerminated == false { return dock.element }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let element = AXUIElementCreateApplication(running.processIdentifier)
        element.setMessagingTimeout(0.25)
        dock = (running.processIdentifier, element)
        return element
    }

    private final class Answer {
        private let lock = NSLock()
        private var stored = false
        var value: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                stored = newValue
                lock.unlock()
            }
        }
    }
}
