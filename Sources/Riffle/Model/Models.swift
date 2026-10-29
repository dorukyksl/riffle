import Cocoa

/// A running app Riffle tracks. Immutable identity (`let`s) is safe to read from background queues.
final class TrackedApp {
    let pid: pid_t
    let running: NSRunningApplication
    let element: AXUIElement
    let name: String
    let bundleID: String?
    let bundleURL: URL?
    var observer: AXObserver?
    /// An observer is being set up (or waiting to retry): don't start another.
    var isAttachingObserver = false
    var observedWindows = Set<CGWindowID>()
    /// Last time the app became frontmost; orders windowless apps.
    var activationStamp: UInt64 = 0
    /// Where the next brute-force sweep for other-Space windows resumes.
    var bruteForceCursor: UInt64 = 0
    /// WindowServer windows a whole sweep couldn't match to an AX window (popups, helper surfaces): not searched again.
    var unfindableWIDs = Set<CGWindowID>()
    /// Windows missing since the current sweep started at id 0.
    var sweepPass = Set<CGWindowID>()
    /// Last time AX answered for this app; used to avoid dropping windows of a busy app.
    var isResponsive = true

    lazy var icon: NSImage = {
        if let icon = running.icon { return icon }
        if let path = bundleURL?.path { return NSWorkspace.shared.icon(forFile: path) }
        return NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }()

    init(_ running: NSRunningApplication) {
        self.running = running
        pid = running.processIdentifier
        element = AXUIElementCreateApplication(running.processIdentifier)
        element.setMessagingTimeout(1.0)
        bundleID = running.bundleIdentifier
        bundleURL = running.bundleURL
        let rawName = running.localizedName ?? running.bundleURL?.deletingPathExtension().lastPathComponent ?? "?"
        // Some apps (WhatsApp) prefix their name with invisible direction marks; they break sorting and search.
        name = rawName.withoutFormatCharacters
    }

    var isHidden: Bool { running.isHidden }
    var isFinder: Bool { bundleID == "com.apple.finder" }
}

/// One switchable window.
final class TrackedWindow {
    let wid: CGWindowID
    let pid: pid_t
    weak var app: TrackedApp?
    var element: AXUIElement?
    var title: String
    var isMinimized: Bool
    var isFullscreen: Bool
    /// Global coordinates, top-left origin (the AX / CoreGraphics convention).
    var frame: CGRect
    var spaceIDs: [CGSSpaceID]
    /// Most-recently-used ordering: higher means used more recently.
    var focusStamp: UInt64
    /// When AX or a scan last confirmed this window: a scan that started earlier must not remove it.
    var confirmedAt = ProcessInfo.processInfo.systemUptime

    init(wid: CGWindowID, pid: pid_t, app: TrackedApp?, element: AXUIElement?, title: String, isMinimized: Bool,
         isFullscreen: Bool, frame: CGRect, spaceIDs: [CGSSpaceID], focusStamp: UInt64) {
        self.wid = wid
        self.pid = pid
        self.app = app
        self.element = element
        self.title = title
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.frame = frame
        self.spaceIDs = spaceIDs
        self.focusStamp = focusStamp
    }
}

/// An immutable row of one switcher session: a window, or an app without windows.
struct SwitcherItem {
    enum Kind: Equatable {
        case window(CGWindowID)
        case app(pid_t)
    }

    let kind: Kind
    let pid: pid_t
    let appName: String
    let title: String
    let icon: NSImage
    let isMinimized: Bool
    let isHidden: Bool
    let isFullscreen: Bool
    /// Mission Control number of the Space the window is on, when that Space isn't on screen.
    let otherSpaceIndex: Int?
    let frame: CGRect
    let bundleID: String?

    /// Search match positions (character offsets) for highlighting.
    var titleMatches: [Int] = []
    var appNameMatches: [Int] = []
    /// Bundle path, to match the app's Dock badge.
    var bundlePath: String? = nil

    var id: String {
        switch kind {
        case .window(let wid): return "w\(wid)"
        case .app(let pid): return "a\(pid)"
        }
    }

    var wid: CGWindowID? {
        if case .window(let wid) = kind { return wid }
        return nil
    }

    var isWindowless: Bool {
        if case .app = kind { return true }
        return false
    }

    /// What the tile shows as its main line.
    var displayTitle: String { title.isEmpty ? appName : title }

    var aspectRatio: CGFloat {
        guard frame.width > 1, frame.height > 1 else { return 16.0 / 10.0 }
        return frame.width / frame.height
    }
}
