import Cocoa

/// Live questions to the WindowServer about what is on screen right now, for the window filters and app exceptions.
/// Main thread; each is a few cheap WindowServer calls.
enum WindowProbe {
    /// The app among `candidates` whose window is under the mouse pointer, or whose Dock icon is. Riffle's own panels and
    /// anything that isn't a candidate's (the menu bar, overlays) are looked through.
    static func appUnderPointer(among candidates: Set<pid_t>, ownPID: pid_t) -> pid_t? {
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x, y: ScreenGeometry.primaryHeight - mouse.y)
        for entry in onScreenWindows() where entry.bounds.contains(point) {
            if entry.pid == ownPID {
                if entry.layer == 0 { return ownPID }
                continue
            }
            if candidates.contains(entry.pid) { return entry.pid }
            if NSRunningApplication(processIdentifier: entry.pid)?.bundleIdentifier == "com.apple.dock" {
                return dockItemApp(at: point, dockPID: entry.pid).flatMap { candidates.contains($0) ? $0 : nil }
            }
        }
        return nil
    }

    /// The running app whose Dock icon is at `point`, by asking the Dock.
    private static func dockItemApp(at point: CGPoint, dockPID: pid_t) -> pid_t? {
        guard let url = dockItemURL(at: point, in: AXUIElementCreateApplication(dockPID), asking: .live) else { return nil }
        let target = url.standardizedFileURL
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == target }?.processIdentifier
    }

    /// How long the Dock gets to answer each question: this runs while a shortcut is pressed, and a Dock that hangs must
    /// not hold the switcher up.
    static let dockTimeout: Float = 0.15

    /// What one element of the Dock says about itself, in one round trip.
    struct DockElement<Element> {
        var subrole: String?
        var url: URL?
        var parent: Element?
    }

    /// The questions `dockItemURL` asks the Dock: AX in the app, stand-ins in tests.
    struct DockQuestions<Element> {
        /// Sets how long one element may take to answer. It covers only that element, not the ones it hands back.
        var limit: (Element, Float) -> Void
        /// The element at a point (global, top-left origin) of the Dock's app element; nil without an answer in time.
        var elementAt: (Element, CGPoint) -> Element?
        /// Nil without an answer in time.
        var describe: (Element) -> DockElement<Element>?
    }

    /// The URL of the Dock icon at `point`: the element there is the icon itself or a part of it. Every element is held
    /// to `dockTimeout` before it's asked anything, and the first question the Dock doesn't answer in time ends the search.
    static func dockItemURL<Element>(at point: CGPoint, in dock: Element, asking questions: DockQuestions<Element>) -> URL? {
        questions.limit(dock, dockTimeout)
        guard var element = questions.elementAt(dock, point) else { return nil }
        for _ in 0..<3 {
            questions.limit(element, dockTimeout)
            guard let answer = questions.describe(element) else { return nil }
            if answer.subrole == "AXApplicationDockItem" { return answer.url }
            guard let parent = answer.parent else { return nil }
            element = parent
        }
        return nil
    }

    /// Whether `pid` fills a display right now: one of its windows is on a full-screen Space that's being shown, or one
    /// covers a whole display (full screen of the app's own making, as some virtual machines and games do it).
    static func isFullscreen(pid: pid_t) -> Bool {
        let topology = SpaceTopology.read(includeWindows: false)
        let shown = topology.spaces.filter { $0.isFullscreen && topology.visibleSpaceIDs.contains($0.id) }.map(\.id)
        if !shown.isEmpty,
           WindowServerInfo.describe(PrivateAPI.windowIDs(inSpaces: shown, includeInvisible: false)).values.contains(where: { $0.pid == pid }) {
            return true
        }
        let displays = NSScreen.screens.map { ScreenGeometry.axRect(fromCocoa: $0.frame) }
        return onScreenWindows().contains { $0.pid == pid && $0.layer == 0 && covers($0.bounds, anyOf: displays) }
    }

    /// A window as big as a whole display, give or take a point of rounding.
    static func covers(_ bounds: CGRect, anyOf displays: [CGRect]) -> Bool {
        displays.contains { bounds.insetBy(dx: -1, dy: -1).contains($0) }
    }

    private struct OnScreenWindow {
        let pid: pid_t
        let layer: Int
        /// Global, top-left origin.
        let bounds: CGRect
    }

    /// Visible windows, front to back.
    private static func onScreenWindows() -> [OnScreenWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { entry in
            guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0 else { return nil }
            return OnScreenWindow(pid: pid, layer: (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0, bounds: bounds)
        }
    }
}

extension WindowProbe.DockQuestions where Element == AXUIElement {
    static var live: WindowProbe.DockQuestions<AXUIElement> {
        WindowProbe.DockQuestions(
            limit: { element, seconds in element.setMessagingTimeout(seconds) },
            elementAt: { dock, point in
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(dock, Float(point.x), Float(point.y), &hit) == .success else { return nil }
                return hit
            },
            describe: { element in
                guard let values = element.values([kAXSubroleAttribute, kAXURLAttribute, kAXParentAttribute]) else { return nil }
                let parent = values[kAXParentAttribute].flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
                return WindowProbe.DockElement(subrole: values[kAXSubroleAttribute] as? String, url: values[kAXURLAttribute] as? URL,
                                               parent: parent)
            })
    }
}
