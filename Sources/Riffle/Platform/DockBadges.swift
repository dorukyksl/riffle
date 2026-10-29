import Cocoa

/// The red badges the Dock draws on app icons ("3", "•"), read from the Dock's accessibility tree so the
/// switcher can show them too.
enum DockBadges {
    private static let queue = DispatchQueue(label: "riffle.dockbadges", qos: .userInitiated)
    private static var cache = [String: String]()
    private static var readAt: TimeInterval = -100

    static var current: [String: String] { cache }

    /// Refreshes at most every couple of seconds; `completion` runs on main with badges keyed by app bundle path.
    static func refresh(_ completion: @escaping ([String: String]) -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - readAt > 2 else { return completion(cache) }
        readAt = now
        queue.async {
            let badges = read()
            DispatchQueue.main.async {
                cache = badges
                completion(badges)
            }
        }
    }

    private static func read() -> [String: String] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        element.setMessagingTimeout(0.3)
        var result = [String: String]()
        for list in element.elements(kAXChildrenAttribute) where list.string(kAXRoleAttribute) == kAXListRole {
            for item in list.elements(kAXChildrenAttribute) {
                guard item.string(kAXSubroleAttribute) == "AXApplicationDockItem",
                      let label = item.string("AXStatusLabel"), !label.isEmpty,
                      let url = item.value(kAXURLAttribute) as? URL else { continue }
                result[url.standardizedFileURL.path] = label
            }
        }
        return result
    }

    static func key(for bundleURL: URL?) -> String? {
        bundleURL?.standardizedFileURL.path
    }
}
