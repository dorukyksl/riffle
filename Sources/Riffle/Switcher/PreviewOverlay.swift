import Cocoa
import QuartzCore

/// Optional "peek": shows the selected window, full size, exactly where it lives on screen (just under the
/// switcher), so you can see what you're about to switch to even if it's buried, minimized or on another Space.
final class PreviewOverlay {
    private let panel: NSPanel
    private let imageLayer = CALayer()
    private var currentWID: CGWindowID?
    private var captureWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        let view = NSView()
        view.wantsLayer = true
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.cornerRadius = 14
        imageLayer.cornerCurve = .continuous
        imageLayer.masksToBounds = true
        view.layer?.addSublayer(imageLayer)
        panel.contentView = view
    }

    func show(wid: CGWindowID, window: TrackedWindow) {
        let frame = ScreenGeometry.cocoaRect(fromAX: window.frame)
        guard frame.width > 60, frame.height > 60, ThumbnailService.shared.isAvailable else {
            hide()
            return
        }
        let changed = currentWID != wid
        currentWID = wid
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(frame, display: false)
        imageLayer.frame = CGRect(origin: .zero, size: frame.size)
        if changed { imageLayer.contents = ThumbnailService.shared.image(for: wid) }
        CATransaction.commit()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        fade(to: imageLayer.contents == nil ? 0 : 0.97, duration: 0.1)
        guard changed else { return }
        // Sharp capture once the selection settles for a moment; fast Tab-cycling doesn't capture every window.
        captureWork?.cancel()
        let request = ThumbnailService.Request(wid: wid, frame: window.frame, isMinimized: window.isMinimized)
        let work = DispatchWorkItem { [weak self] in
            ThumbnailService.shared.captureLarge(request) { image in
                guard let self, self.currentWID == wid, let image else { return }
                self.setImage(image)
                self.fade(to: 0.97)
            }
        }
        captureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
    }

    func thumbnailUpdated(_ wid: CGWindowID) {
        guard wid == currentWID, imageLayer.contents == nil, let image = ThumbnailService.shared.image(for: wid) else { return }
        setImage(image)
        fade(to: 0.97)
    }

    /// A new picture dissolves in, unless the panel's animations are off.
    private func setImage(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(!SwitcherUI.animatesFades)
        imageLayer.contents = image
        CATransaction.commit()
    }

    /// Over `duration` (AppKit's default when nil), or at once when the panel's animations are off.
    private func fade(to alpha: CGFloat, duration: TimeInterval? = nil) {
        guard SwitcherUI.animatesFades else {
            panel.alphaValue = alpha
            return
        }
        guard let duration else {
            panel.animator().alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = alpha
        }
    }

    func hide() {
        captureWork?.cancel()
        currentWID = nil
        imageLayer.contents = nil
        panel.orderOut(nil)
    }
}
