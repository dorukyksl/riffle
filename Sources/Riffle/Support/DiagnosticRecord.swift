import Cocoa

/// How the diagnostic and test modes write about the user's apps and windows. Any local process can start them, and they
/// read with Riffle's permissions, so what they write never names anything: a window title can say anything private, and
/// which apps someone runs says a lot too. An app goes by its bundle identifier, as the log names it, a window by its id
/// and the length of its title, and the only pictures they take are of Riffle's own windows.
enum DiagnosticRecord {
    static func app(_ app: TrackedApp?, pid: pid_t) -> String {
        Log.app(app?.bundleID, pid: pid)
    }

    static func app(_ running: NSRunningApplication?) -> String {
        Log.app(running)
    }

    static func window(_ window: TrackedWindow) -> [String: Any] {
        [
            "wid": window.wid, "pid": window.pid, "app": app(window.app, pid: window.pid), "titleLength": window.title.count,
            "minimized": window.isMinimized, "fullscreen": window.isFullscreen, "hidden": window.app?.isHidden ?? false,
            "spaces": window.spaceIDs, "frame": NSStringFromRect(window.frame), "stamp": window.focusStamp,
            "hasElement": window.element != nil,
        ]
    }

    /// A switcher row on one line: its app, its window, and the length of its title.
    static func row(_ item: SwitcherItem) -> String {
        "\(Log.app(item.bundleID, pid: item.pid)) \(item.wid.map { "#\($0)" } ?? "without windows") titleLength=\(item.title.count)"
    }

    static func space(_ space: SpaceInfo, in topology: SpaceTopology) -> [String: Any] {
        // A full-screen Space has no desktop number: null, as nil would make the whole report unwritable.
        ["id": space.id, "index": space.index, "desktop": space.desktopNumber.map { $0 as Any } ?? NSNull(),
         "fullscreen": space.isFullscreen, "visible": topology.visibleSpaceIDs.contains(space.id)]
    }
}
