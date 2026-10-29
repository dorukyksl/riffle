import CoreGraphics

/// macOS native tabs (Finder, Terminal, TextEdit, …) are one window per tab. Only the selected tab's window is shown;
/// the others are kept ordered out and belong to no Space, at the group's frame. They are no place to switch to (a
/// card for one would have no picture), and the group already has its card: the visible tab.
enum TabGroups {
    struct Surface: Equatable {
        let wid: CGWindowID
        let pid: pid_t
        /// WindowServer bounds (tabs of one group share them).
        let frame: CGRect
        let isOnScreen: Bool
        /// Listed on at least one Space (minimized windows and hidden apps' windows still are).
        let isOnSpace: Bool
        let isMinimized: Bool
    }

    static let frameTolerance: CGFloat = 2

    /// The windows among `surfaces` that are background tabs: not minimized, off screen and on no Space, while another
    /// window of the same app with the same frame is shown (on a Space, on screen or minimized: the group's visible
    /// tab). Without such a sibling a window is kept: dropping it could leave its group with no card at all. Apps in
    /// `hiddenPIDs` are left alone (all their windows are off screen).
    static func backgroundTabs(_ surfaces: [Surface], hiddenPIDs: Set<pid_t> = []) -> Set<CGWindowID> {
        var tabs = Set<CGWindowID>()
        for (pid, group) in Dictionary(grouping: surfaces, by: \.pid) where group.count > 1 && !hiddenPIDs.contains(pid) {
            for window in group where !window.isMinimized && !window.isOnSpace && !window.isOnScreen {
                let hasVisibleTab = group.contains { other in
                    other.wid != window.wid && (other.isOnSpace || other.isOnScreen || other.isMinimized)
                        && sameFrame(other.frame, window.frame)
                }
                if hasVisibleTab { tabs.insert(window.wid) }
            }
        }
        return tabs
    }

    static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= frameTolerance && abs(a.minY - b.minY) <= frameTolerance
            && abs(a.width - b.width) <= frameTolerance && abs(a.height - b.height) <= frameTolerance
    }
}
