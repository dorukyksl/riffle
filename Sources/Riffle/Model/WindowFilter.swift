import CoreGraphics
import Foundation

/// Which windows, and which apps without windows, one shortcut lists, and in what order. Pure: plain values in, the rows'
/// identities out, so every option can be tested without a WindowServer. `WindowStore.items(for:)` gathers the values
/// and turns the result into `SwitcherItem`s.
///
/// In order: exceptions, full-screen windows, whose windows and where leave rows out; minimized windows and windows of
/// hidden apps stay, go to the end or go; "one window per app" keeps each app's most recently used one; the rest is
/// sorted. Apps without windows join last (whose, not where: they aren't anywhere), among the others or at the very end.
enum WindowFilter {
    struct Window: Equatable {
        var wid: CGWindowID
        var pid: pid_t
        var title = ""
        var isMinimized = false
        var isFullscreen = false
        /// Global coordinates, top-left origin.
        var frame = CGRect.zero
        /// The Spaces it's on as best known (a minimized window keeps the one it was last seen on); empty when unknown.
        var spaceIDs: [CGSSpaceID] = []
        /// Whether it's on screen right now, when that was looked up (for windows whose Space is unknown).
        var isOnScreen: Bool?
        /// Most-recently-used order: higher is more recent.
        var focusStamp: UInt64 = 0
    }

    struct App: Equatable {
        var pid: pid_t
        var bundleID: String?
        var name: String
        var isHidden = false
        /// When it last came to the front, on the same clock as `Window.focusStamp`.
        var activationStamp: UInt64 = 0
        var launchDate: Date?
        /// May be listed while it has no windows (a regular app that's still running, isn't Finder and isn't quitting).
        var canListWithoutWindows = true
    }

    /// Who "the active app" and "the app under the pointer" are. A switcher session keeps the ones it began with.
    struct Anchor: Equatable {
        var frontPID: pid_t?
        var pointerPID: pid_t?
    }

    struct Context {
        var anchor = Anchor()
        /// The Space each display shows. Empty when unknown: then every window counts as on this desktop.
        var visibleSpaceIDs: Set<CGSSpaceID> = []
        /// The visible Space of the display with the active menu bar.
        var activeSpaceID: CGSSpaceID = 0
        /// Mission Control's number for each Space.
        var spaceNumbers: [CGSSpaceID: Int] = [:]
        /// The screen the switcher is on (global, top-left origin); nil: any.
        var screenRect: CGRect?
        var exceptions: [AppException] = []
    }

    private struct Row {
        let kind: SwitcherItem.Kind
        let app: App
        let title: String
        /// 0: in its place; 1: a window put at the end; 2: an app without windows put at the very end.
        let group: Int
        let stamp: UInt64
        /// Mission Control number; nil when unknown (sorts after the known ones).
        let desktop: Int?
        /// Window ids grow as windows are created: the order they were opened in.
        let id: UInt64
    }

    static func select(windows: [Window], apps: [App], profile: ShortcutProfile, context: Context) -> [SwitcherItem.Kind] {
        let appsByPID = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var rulesByPID = [pid_t: [AppException]]()
        func rules(_ app: App) -> [AppException] {
            if let known = rulesByPID[app.pid] { return known }
            let found = context.exceptions.filter { $0.matches(app.bundleID) }
            rulesByPID[app.pid] = found
            return found
        }

        var rows = [Row]()
        for window in windows {
            guard let app = appsByPID[window.pid], includes(app.pid, profile.apps, context.anchor),
                  isInPlace(window, profile.place, context), profile.showFullscreen || !window.isFullscreen,
                  !rules(app).contains(where: { $0.hidesWindow(titled: window.title) }) else { continue }
            var placement = ShowOption.show
            if window.isMinimized { placement = placement.combined(with: profile.minimized) }
            if app.isHidden { placement = placement.combined(with: profile.hiddenApps) }
            guard placement != .hide else { continue }
            rows.append(Row(kind: .window(window.wid), app: app, title: window.title, group: placement == .showAtEnd ? 1 : 0,
                            stamp: window.focusStamp, desktop: desktopNumber(window, context), id: UInt64(window.wid)))
        }

        if profile.onePerApp {
            var newest = [pid_t: Row]()
            for row in rows where newest[row.app.pid].map({ precedes(row, $0, by: .recentlyUsed, ignoringGroups: true) }) ?? true {
                newest[row.app.pid] = row
            }
            rows.removeAll { newest[$0.app.pid]?.kind != $0.kind }
        }

        if profile.listsWindowlessApps, profile.windowlessApps != .hide {
            let withWindows = Set(windows.map(\.pid))
            for app in apps where app.canListWithoutWindows && !withWindows.contains(app.pid) && includes(app.pid, profile.apps, context.anchor) {
                guard !rules(app).contains(where: \.hidesWindowlessApp) else { continue }
                let placement = app.isHidden ? profile.windowlessApps.combined(with: profile.hiddenApps) : profile.windowlessApps
                guard placement != .hide else { continue }
                rows.append(Row(kind: .app(app.pid), app: app, title: "", group: placement == .showAtEnd ? 2 : 0,
                                stamp: app.activationStamp, desktop: nil, id: UInt64(UInt32(bitPattern: app.pid))))
            }
        }

        rows.sort { precedes($0, $1, by: profile.order, ignoringGroups: false) }
        return rows.map(\.kind)
    }

    private static func includes(_ pid: pid_t, _ scope: AppScope, _ anchor: Anchor) -> Bool {
        switch scope {
        case .allApps: return true
        case .activeApp: return pid == anchor.frontPID
        case .otherApps: return pid != anchor.frontPID
        case .appUnderPointer: return pid == anchor.pointerPID
        }
    }

    private static func isInPlace(_ window: Window, _ place: PlaceScope, _ context: Context) -> Bool {
        switch place {
        case .allDesktops:
            return true
        case .thisDesktop:
            // No picture of the Spaces at all (the private API failed): nothing to tell desktops apart by.
            guard !context.visibleSpaceIDs.isEmpty else { return true }
            // A window whose Space nobody knows only counts when it's visibly here; minimized, it can't be.
            if window.spaceIDs.isEmpty { return window.isOnScreen == true }
            return window.spaceIDs.contains(where: context.visibleSpaceIDs.contains)
        case .thisScreen:
            guard let screen = context.screenRect else { return true }
            return !window.frame.isEmpty && screen.intersects(window.frame)
        }
    }

    /// The lowest Mission Control number among its Spaces. A window whose Space is unknown but that is on screen counts as
    /// on the active desktop; otherwise it has none.
    private static func desktopNumber(_ window: Window, _ context: Context) -> Int? {
        if let lowest = window.spaceIDs.compactMap({ context.spaceNumbers[$0] }).min() { return lowest }
        guard window.spaceIDs.isEmpty, window.isOnScreen == true else { return nil }
        return context.spaceNumbers[context.activeSpaceID]
    }

    private static func precedes(_ a: Row, _ b: Row, by order: WindowOrder, ignoringGroups: Bool) -> Bool {
        if !ignoringGroups, a.group != b.group { return a.group < b.group }
        switch order {
        case .recentlyUsed:
            if a.stamp != b.stamp { return a.stamp > b.stamp }
        case .launchOrder:
            if a.app.pid != b.app.pid {
                switch (a.app.launchDate, b.app.launchDate) {
                case let (x?, y?) where x != y: return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return a.app.pid < b.app.pid
                }
            }
        case .alphabetical:
            let byName = a.app.name.localizedStandardCompare(b.app.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            let byTitle = a.title.localizedStandardCompare(b.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            if a.stamp != b.stamp { return a.stamp > b.stamp }
        case .byDesktop:
            let (x, y) = (a.desktop ?? .max, b.desktop ?? .max)
            if x != y { return x < y }
            if a.stamp != b.stamp { return a.stamp > b.stamp }
        }
        // Same app or a tie: the order things were opened in, windows before apps without any.
        if a.kind.isWindow != b.kind.isWindow { return a.kind.isWindow }
        return a.id < b.id
    }
}

private extension SwitcherItem.Kind {
    var isWindow: Bool {
        if case .window = self { return true }
        return false
    }
}
