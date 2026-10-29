import Cocoa

/// When the setting is on, a switch to a window ends with the mouse pointer in the middle of it, where the eyes go.
enum PointerFollow {
    /// Where the pointer goes for a window at `frame` (global coordinates, top-left origin, as accessibility and Quartz
    /// share them): its centre; when that is off every display, the centre of the window's largest part on one. Nil when
    /// no display shows any of it.
    static func target(for frame: CGRect, displays: [CGRect]) -> CGPoint? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if displays.contains(where: { $0.contains(center) }) { return center }
        let parts = displays.map { $0.intersection(frame) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard let largest = parts.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        return CGPoint(x: largest.midX, y: largest.midY)
    }

    /// The switch to the window at `frame` (top-left origin) is done: bring the pointer, if the setting asks for it.
    static func windowFronted(at frame: CGRect) {
        guard Prefs.shared.pointerFollowsSwitch else { return }
        let displays = NSScreen.screens.map { ScreenGeometry.axRect(fromCocoa: $0.frame) }
        guard let point = target(for: frame, displays: displays) else { return }
        CGWarpMouseCursorPosition(point)
        // Without this the pointer ignores the mouse for a moment after a warp.
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
