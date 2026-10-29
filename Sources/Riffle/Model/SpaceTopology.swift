import Cocoa

struct SpaceInfo: Equatable {
    let id: CGSSpaceID
    /// 1-based position in Mission Control's order, every display's Spaces in turn, full-screen ones included: what
    /// ordering windows by desktop goes by.
    let index: Int
    let displayUUID: String
    let isFullscreen: Bool
    /// The number Mission Control gives a desktop ("Desktop 2"), counted the same way but over desktops only. Nil for a
    /// full-screen Space: Mission Control names that one after its app.
    var desktopNumber: Int? = nil
}

/// A point-in-time picture of the user's Spaces and which windows live where.
struct SpaceTopology {
    var spaces: [SpaceInfo] = []
    /// The Space each display is currently showing.
    var visibleSpaceIDs: Set<CGSSpaceID> = []
    /// The visible Space of the display with the active menu bar.
    var activeSpaceID: CGSSpaceID = 0
    var windowSpaces: [CGWindowID: [CGSSpaceID]] = [:]
    /// Window ids across every Space, visible Spaces first, each Space top-most first.
    var orderedWindowIDs: [CGWindowID] = []

    var hasMultipleSpaces: Bool { spaces.count > 1 }

    func info(for id: CGSSpaceID) -> SpaceInfo? {
        spaces.first { $0.id == id }
    }

    /// The desktop number a card shows for a window on these Spaces: the first of them that's a desktop. Nil when it's
    /// on full-screen Spaces only, which the card marks as full screen instead.
    func desktopNumber(of spaceIDs: [CGSSpaceID]) -> Int? {
        spaceIDs.lazy.compactMap { info(for: $0)?.desktopNumber }.first
    }

    /// Safe to call off the main thread: only WindowServer IPC and parsing.
    static func read(includeWindows: Bool) -> SpaceTopology {
        let activeDisplay = PrivateAPI.activeMenuBarDisplayUUID()
        return parse(displays: PrivateAPI.managedDisplaySpaces(), activeDisplay: activeDisplay,
                     windowIDs: includeWindows ? { PrivateAPI.windowIDs(inSpaces: [$0], includeInvisible: true) } : nil)
    }

    /// The same from what the WindowServer answered (in tests, fixtures): `displays` as `managedDisplaySpaces()` lists
    /// them, and `windowIDs` the windows of one Space, top-most first, or nil to leave windows out.
    static func parse(displays: [NSDictionary], activeDisplay: String?, windowIDs: ((CGSSpaceID) -> [CGWindowID])?) -> SpaceTopology {
        var topology = SpaceTopology()
        var index = 1
        var desktop = 1
        for display in displays {
            let uuid = display["Display Identifier"] as? String ?? "Main"
            for space in display["Spaces"] as? [NSDictionary] ?? [] {
                guard let id = (space["id64"] as? NSNumber)?.uint64Value else { continue }
                // Type 4 is a full-screen Space (one app, or two side by side); anything else is a desktop. The desktops
                // after a full-screen Space keep counting from the one before it, and on across displays, as the
                // "Switch to Desktop N" shortcuts number them.
                let isFullscreen = (space["type"] as? NSNumber)?.intValue == 4
                topology.spaces.append(SpaceInfo(id: id, index: index, displayUUID: uuid, isFullscreen: isFullscreen,
                                                 desktopNumber: isFullscreen ? nil : desktop))
                index += 1
                if !isFullscreen { desktop += 1 }
            }
            if let current = ((display["Current Space"] as? NSDictionary)?["id64"] as? NSNumber)?.uint64Value {
                topology.visibleSpaceIDs.insert(current)
                if topology.activeSpaceID == 0 || uuid == activeDisplay {
                    topology.activeSpaceID = current
                }
            }
        }
        guard let windowIDs else { return topology }
        let visibleFirst = topology.spaces.filter { topology.visibleSpaceIDs.contains($0.id) }
            + topology.spaces.filter { !topology.visibleSpaceIDs.contains($0.id) }
        var seen = Set<CGWindowID>()
        for space in visibleFirst {
            for wid in windowIDs(space.id) {
                topology.windowSpaces[wid, default: []].append(space.id)
                if seen.insert(wid).inserted { topology.orderedWindowIDs.append(wid) }
            }
        }
        return topology
    }
}
