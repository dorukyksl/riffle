import Cocoa

/// Files dragged onto a card open with that card's app, as if dropped on its Dock icon, and the window (or the app) comes
/// forward. Riffle's own windows take no drops.
enum FileDrop {
    /// Where dropped files go.
    struct Route: Equatable {
        /// The app that opens them.
        let app: URL
        /// The window brought forward first. Nil for an app without windows: opening the files brings it forward.
        let window: CGWindowID?
    }

    /// Where files dropped on `item` go, or nil when the card takes no drop: one of Riffle's own windows, an app that is no
    /// longer running (or has no bundle to open files with), or nothing to open.
    static func route(for item: SwitcherItem, files: [URL], ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
                      appURL: (pid_t) -> URL? = { NSRunningApplication(processIdentifier: $0)?.bundleURL }) -> Route? {
        guard !files.isEmpty, item.pid != ownPID, let app = appURL(item.pid) else { return nil }
        return Route(app: app, window: item.wid)
    }

    /// What a card shows while files hover over it: whatever the drag allows, a plain drop first, then a copy (Finder
    /// allows only copies while ⌥ is held, as it is to keep the switcher open), then a link. Empty: no drop.
    static func operation(allowed: NSDragOperation) -> NSDragOperation {
        [NSDragOperation.generic, .copy, .link].first { allowed.contains($0) } ?? []
    }

    /// The files on a drag's pasteboard.
    static func files(on pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Opens `files` with the route's app, which comes forward.
    static func open(_ files: [URL], along route: Route) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app = route.app.deletingPathExtension().lastPathComponent
        Log.info("drop: \(files.count) file(s) → \(app)")
        NSWorkspace.shared.open(files, withApplicationAt: route.app, configuration: configuration) { _, error in
            if let error { Log.warn("drop: \(app) didn't open the files: \(error.localizedDescription)") }
        }
    }
}
