import Cocoa
import QuartzCore

protocol SwitcherUIDelegate: AnyObject {
    func switcherUIHovered(_ index: Int)
    func switcherUIClicked(_ index: Int)
    func switcherUIQueryChanged(_ query: String)
    func switcherUIResignedKey()
    func switcherUIPerform(_ action: SwitcherAction, at index: Int)
    /// Files were dropped on a row: they open with its app, and its window comes forward.
    func switcherUIOpen(_ files: [URL], at index: Int)
}

/// Floats above everything, on every Space and over fullscreen apps, and takes keyboard focus without
/// activating Riffle, so the app you're leaving keeps its menu bar and active state.
final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.nonactivatingPanel, .borderless],
                  backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        // A window shadow follows the window's rectangle and draws a hairline outside the glass's rounded
        // corners; Liquid Glass brings its own rim and depth.
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
        worksWhenModal = true
        setAccessibilityTitle("Riffle")
    }
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Bottom to top in the tile container: the hover plate, the selection plate, then the tiles in item order.
private func stackingRank(_ view: NSView) -> Int {
    if let tile = view as? TileView { return tile.index }
    return (view as? HighlightView)?.isHover == true ? -2 : -1
}

/// The selection color: the system accent, unless an offscreen render (the website's pictures) asks for another.
enum Palette {
    static var accentOverride: NSColor?
    static var accent: NSColor { accentOverride ?? .controlAccentColor }
}

/// The selection plate behind the chosen tile, and the softer one behind a hovered tile. In the deck the selection
/// plate glows and slides from cell to cell.
final class HighlightView: NSView {
    let isHover: Bool
    var glows = false {
        didSet { updateColors() }
    }

    init(hover: Bool) {
        isHover = hover
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 14
        layer?.masksToBounds = false
        updateColors()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isHover {
                layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
                layer?.borderWidth = 0
            } else {
                layer?.backgroundColor = Palette.accent.withAlphaComponent(glows ? 0.18 : 0.24).cgColor
                layer?.borderColor = Palette.accent.withAlphaComponent(0.95).cgColor
                layer?.borderWidth = glows ? 2.5 : 2
                layer?.shadowColor = Palette.accent.cgColor
                layer?.shadowOpacity = glows ? 0.45 : 0
                layer?.shadowRadius = 12
                layer?.shadowOffset = .zero
            }
        }
    }
}

final class SearchBarView: NSView {
    let field = NSTextField()
    private let icon = NSImageView()
    let countLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        icon.contentTintColor = .secondaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17, weight: .regular)
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .right
        leftToRight = (field.alignment, countLabel.alignment)
        [icon, field, countLabel].forEach(addSubview)
        updateColors()
    }

    required init?(coder: NSCoder) { nil }

    /// An input method is in the middle of composing text (marked text).
    var isComposing: Bool { (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false }

    /// Arabic and Hebrew: the magnifying glass on the right, the query aligned to it, the count on the left.
    var isRightToLeft = false {
        didSet {
            guard isRightToLeft != oldValue else { return }
            field.alignment = isRightToLeft ? .right : leftToRight.field
            // A field already being edited draws through its field editor.
            field.currentEditor()?.alignment = field.alignment
            countLabel.alignment = isRightToLeft ? .left : leftToRight.count
            needsLayout = true
        }
    }

    /// The alignments the field and the count are made with, for going back to left to right.
    private var leftToRight: (field: NSTextAlignment, count: NSTextAlignment) = (.left, .right)

    /// `rect` as laid out left to right, mirrored when the bar reads right to left.
    private func mirrored(_ rect: NSRect) -> NSRect {
        isRightToLeft ? rect.mirrored(within: bounds.width) : rect
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        }
    }

    override func layout() {
        super.layout()
        icon.frame = mirrored(NSRect(x: 12, y: (bounds.height - 20) / 2, width: 20, height: 20))
        // The count ("2 of 12 windows") takes the room it needs; the field gets the rest.
        let countWidth = countLabel.stringValue.isEmpty ? 0 : min(ceil(countLabel.fittingSize.width) + 2, bounds.width * 0.4)
        countLabel.frame = mirrored(NSRect(x: bounds.width - 12 - countWidth, y: (bounds.height - 15) / 2, width: countWidth, height: 15))
        field.frame = mirrored(NSRect(x: 40, y: (bounds.height - 24) / 2, width: max(bounds.width - 40 - 24 - countWidth, 40), height: 24))
    }
}

/// Owns the panel and its views. Knows nothing about sessions; `SwitcherController` drives it.
///
/// Four arrangements:
/// - deck: every window in a cell (icon and title over its thumbnail) in balanced rows, a glowing plate sliding to
///   the selected one;
/// - stage: the selected window large on a stage, every window on a filmstrip below that keeps the
///   selection centered;
/// - list: rows on the left, the stage on the right;
/// - app icons: icons that wrap into rows.
///
/// In Arabic and Hebrew every arrangement is mirrored: the first window is on the right, the list sits on the right of
/// its stage, and what each tile shows reads right to left. Window pictures are never flipped.
final class SwitcherUI: NSObject, TileViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    weak var delegate: SwitcherUIDelegate?
    let panel = SwitcherPanel()

    private let glass = NSGlassEffectView()
    private let root = FlippedView()
    private let scrollView = NSScrollView()
    private let container = FlippedView()
    private let highlight = HighlightView(hover: false)
    private let hoverPlate = HighlightView(hover: true)
    let hero = HeroView()
    let searchBar = SearchBarView()
    private let emptyLabel = NSTextField(labelWithString: "")

    /// The tiles on show, in item order.
    private(set) var tiles = [TileView]()
    /// Tiles made earlier, kept to be moved and relabelled by later builds rather than made again.
    private let keeper = TileKeeper<TileView>()
    private(set) var layout: TileLayout?
    private(set) var style: SwitcherStyle = .deck
    /// The last build reads right to left (Arabic, Hebrew).
    private(set) var isRightToLeft = false
    /// The session's own style, when its shortcut has one; otherwise the one chosen in Appearance.
    var styleOverride: SwitcherStyle?
    /// The style the next build uses, known before the first one (`style` is the one last built).
    var effectiveStyle: SwitcherStyle { styleOverride ?? Prefs.shared.style }
    private var items = [SwitcherItem]()
    /// Pixels per point of the screen the panel is on: icons are drawn for it.
    private var renderScale: CGFloat = 2
    private var selectedIndex = -1
    private var highlightPlaced = false
    private var hoverDeadzoneOrigin: NSPoint?
    private(set) var isRevealed = false
    private var searching = false
    private var heroCaptureWork: DispatchWorkItem?
    private var heroIsSharp = false

    private let padding = SwitcherUI.padding
    private let sectionGap = SwitcherUI.sectionGap
    static let padding: CGFloat = 18
    static let sectionGap: CGFloat = 14

    /// Where on `screen` the panel may go: its visible frame, kept under the camera housing of a notched display. With a
    /// full-screen app in front the menu bar hides and the visible frame reaches the top edge, notch included.
    static func usableFrame(of screen: NSScreen) -> CGRect {
        usableFrame(visible: screen.visibleFrame, frame: screen.frame, topInset: screen.safeAreaInsets.top)
    }

    static func usableFrame(visible: CGRect, frame: CGRect, topInset: CGFloat) -> CGRect {
        var usable = visible
        let ceiling = frame.maxY - topInset
        if topInset > 0, usable.maxY > ceiling { usable.size.height = max(ceiling - usable.minY, 0) }
        return usable
    }

    /// The most room the panel's content gets inside `usable`: 90% of the width and 86% of the height, less the panel's
    /// padding and the search bar. The panel is centered, so it always keeps a margin to every edge.
    static func contentLimits(in usable: CGRect, searching: Bool) -> CGSize {
        let searchHeight: CGFloat = searching ? 46 + sectionGap : 0
        return CGSize(width: (usable.width * 0.9 - 2 * padding).rounded(),
                      height: (usable.height * 0.86 - 2 * padding - searchHeight).rounded())
    }

    override init() {
        super.init()
        glass.cornerRadius = SwitcherUI.cornerRadius
        root.wantsLayer = true
        glass.contentView = root
        panel.contentView = glass
        panel.delegate = self
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = container
        container.wantsLayer = true
        container.addSubview(hoverPlate)
        container.addSubview(highlight)
        hoverPlate.isHidden = true
        highlight.isHidden = true
        highlight.layer?.cornerRadius = 10
        hoverPlate.layer?.cornerRadius = 10
        hero.onClick = { [weak self] in
            guard let self, self.selectedIndex >= 0 else { return }
            self.delegate?.switcherUIClicked(self.selectedIndex)
        }
        hero.onDrop = { [weak self] files in
            guard let self, self.selectedIndex >= 0 else { return }
            self.open(files, at: self.selectedIndex)
        }
        searchBar.field.delegate = self
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 14, weight: .medium)
        emptyLabel.textColor = .secondaryLabelColor
        [searchBar, hero, scrollView, emptyLabel].forEach(root.addSubview)
    }

    // MARK: - Building

    /// Lays out the panel for `items` on `screen`. The panel is ordered in invisible (alpha 0) and made key right
    /// away, so keystrokes typed before it fades in already reach the switcher instead of the app being left.
    func present(items: [SwitcherItem], selected: Int, searching: Bool, query: String, screen: NSScreen, total: Int? = nil) {
        applyAppearance()
        build(items: items, searching: searching, query: query, screen: screen, keepPosition: false, total: total)
        select(selected, animated: false)
        if !panel.isVisible {
            panel.alphaValue = 0
            isRevealed = false
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
        }
        panel.makeKey()
        hoverDeadzoneOrigin = NSEvent.mouseLocation
        if searching { focusSearchField() }
    }

    /// Step 1 of an offscreen render: build the views. Give AppKit one run-loop turn before `captureOffscreen`.
    func prepareOffscreen(items: [SwitcherItem], selected: Int, searching: Bool, query: String, screen: NSScreen,
                          appearance: NSAppearance, badges: [String: String] = [:], total: Int? = nil) {
        panel.appearance = appearance
        build(items: items, searching: searching, query: query, screen: screen, keepPosition: false, total: total)
        updateDockBadges(badges)
        isRevealed = false
        select(selected, animated: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.display()
    }

    /// The glass's corner radius, in points.
    static let cornerRadius: CGFloat = 30

    /// Movement: the plate's glide, cards lifting or shrinking, the strip scrolling, the stage sliding. Off with the
    /// Appearance setting and while macOS's Reduce Motion is on.
    static var animatesMotion: Bool { animations(setting: Prefs.shared.panelAnimations).motion }

    /// Fades: pictures dissolving in, cards fading out, the panel and the preview fading in. Off only with the Appearance
    /// setting: under Reduce Motion they stand in for the movement.
    static var animatesFades: Bool { animations(setting: Prefs.shared.panelAnimations).fades }

    static func animations(setting: Bool, reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        -> (motion: Bool, fades: Bool) {
        (setting && !reduceMotion, setting)
    }

    /// Step 2: render what was prepared into an image. Without `backdrop`, only the contents: the caller draws the glass.
    func captureOffscreen(backdrop: Bool = true) -> CGImage? {
        let appearance = panel.appearance ?? NSAppearance(named: .darkAqua)!
        root.layoutSubtreeIfNeeded()
        let size = root.bounds.size
        let scale: CGFloat = 2
        guard size.width > 0, size.height > 0,
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        if backdrop {
            // Stand-in for the Liquid Glass backdrop, which only exists on screen.
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let radius = SwitcherUI.cornerRadius
            context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor((dark ? NSColor(white: 0.15, alpha: 0.97) : NSColor(white: 0.95, alpha: 0.97)).cgColor)
            context.fillPath()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        appearance.performAsCurrentDrawingAppearance {
            func display(_ view: NSView) {
                view.wantsLayer = true
                view.display()
                view.subviews.forEach(display)
            }
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.display()
            display(root)
            CATransaction.flush()
            // Layer geometry is flipped for flipped views; CoreGraphics draws bottom-up.
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            root.layer?.render(in: context)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// Where each tile of an offscreen render sits, in the render's points (top-left origin), and the render's size.
    func offscreenTileFrames() -> (size: CGSize, frames: [CGRect]) {
        root.layoutSubtreeIfNeeded()
        return (root.bounds.size, tiles.map { $0.convert($0.bounds, to: root) })
    }

    func reload(items: [SwitcherItem], selected: Int, searching: Bool, query: String, screen: NSScreen, total: Int? = nil) {
        build(items: items, searching: searching, query: query, screen: screen, keepPosition: searching, total: total)
        select(selected, animated: false)
        if searching { focusSearchField() }
        hoverDeadzoneOrigin = NSEvent.mouseLocation
    }

    private var removalInFlight = false
    private var removalCompletions = [() -> Void]()

    /// Shrinks and fades out the tiles whose items match (only fades them under Reduce Motion), then calls `completion` (at
    /// once when there are none, the panel isn't shown, or animations are off). Calls arriving during the animation just
    /// wait for it, then all run once.
    func animateOut(where matches: (SwitcherItem) -> Bool, completion: @escaping () -> Void) {
        removalCompletions.append(completion)
        guard !removalInFlight else { return }
        let leaving = tiles.filter { matches($0.item) }
        guard !leaving.isEmpty, isRevealed, SwitcherUI.animatesFades else {
            finishRemoval()
            return
        }
        removalInFlight = true
        // Shrunk and faded for good: never handed out again.
        leaving.forEach(keeper.discard)
        let shrinks = SwitcherUI.animatesMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true
            if leaving.contains(where: { $0.index == selectedIndex }) { highlight.animator().alphaValue = 0 }
            for tile in leaving {
                tile.animator().alphaValue = 0
                // The tile's contents are placed once, so shrink the whole layer about its center rather than its frame.
                guard shrinks, let layer = tile.layer else { continue }
                let center = CGPoint(x: layer.bounds.width * (0.5 - layer.anchorPoint.x), y: layer.bounds.height * (0.5 - layer.anchorPoint.y))
                var shrunk = CATransform3DMakeTranslation(center.x, center.y, 0)
                shrunk = CATransform3DScale(shrunk, 0.86, 0.86, 1)
                shrunk = CATransform3DTranslate(shrunk, -center.x, -center.y, 0)
                let shrink = CABasicAnimation(keyPath: "transform")
                shrink.fromValue = CATransform3DIdentity
                shrink.toValue = shrunk
                shrink.duration = 0.2
                shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
                shrink.fillMode = .forwards
                shrink.isRemovedOnCompletion = false
                layer.add(shrink, forKey: "leave")
            }
        }, completionHandler: { [weak self] in
            self?.removalInFlight = false
            self?.highlight.alphaValue = 1
            self?.finishRemoval()
        })
    }

    private func finishRemoval() {
        let completions = removalCompletions
        removalCompletions = []
        // Only the last one matters: each reloads the latest state.
        completions.last?()
    }

    /// When only what's drawn inside some tiles changed (a title, minimized, hidden…) and the layout would be the same,
    /// swaps just those tiles. Returns false when a full rebuild is needed.
    func updateInPlace(items newItems: [SwitcherItem], selected: Int) -> Bool {
        guard let layout, newItems.count == items.count, newItems.count == tiles.count, style != .stage, style != .list else { return false }
        for (old, new) in zip(items, newItems) {
            guard old.id == new.id, abs(old.aspectRatio - new.aspectRatio) < 0.02 else { return false }
        }
        let look = look(for: layout)
        for (index, item) in newItems.enumerated() {
            let old = items[index]
            guard old.title != item.title || old.isMinimized != item.isMinimized || old.isHidden != item.isHidden
                    || old.isFullscreen != item.isFullscreen || old.otherSpaceIndex != item.otherSpaceIndex else { continue }
            let replaced = tiles[index]
            let blueprint = TileBlueprint(item, look: look)
            let tile: TileView
            if keeper.holds(replaced, for: blueprint) {
                // Only the title changed: relabel the tile.
                replaced.reuse(index: index, item: item, frame: replaced.frame, layout: layout)
                tile = replaced
            } else {
                tile = TileView(index: index, item: item, frame: replaced.frame, layout: layout, scale: renderScale)
                tile.delegate = self
                keeper.keep(tile, for: blueprint)
                container.replaceSubview(replaced, with: tile)
                tiles[index] = tile
            }
            if let wid = item.wid { tile.setThumbnail(ThumbnailService.shared.image(for: wid)) }
            tile.setDockBadge(item.bundlePath.flatMap { DockBadges.current[$0] })
            if index == selected { tile.setSelected(true, animated: false) }
        }
        items = newItems
        if selected != selectedIndex { select(selected, animated: true) }
        return true
    }

    private func applyAppearance() {
        switch Prefs.shared.theme {
        case .system: panel.appearance = nil
        case .dark: panel.appearance = NSAppearance(named: .darkAqua)
        case .light: panel.appearance = NSAppearance(named: .aqua)
        }
        glass.style = Prefs.shared.glass == .clear ? .clear : .regular
    }

    /// `total`: how many windows a search looks through, for its count (the shown items when nil).
    private func build(items: [SwitcherItem], searching: Bool, query: String, screen: NSScreen, keepPosition: Bool, total: Int? = nil) {
        self.items = items
        self.searching = searching
        style = effectiveStyle
        let rightToLeft = Prefs.shared.language.isRightToLeft
        isRightToLeft = rightToLeft
        // Riffle's own language decides, not the Mac's: the scroller goes on its trailing side.
        scrollView.userInterfaceLayoutDirection = rightToLeft ? .rightToLeft : .leftToRight
        hero.isRightToLeft = rightToLeft
        searchBar.isRightToLeft = rightToLeft
        hoverPlate.isHidden = true
        highlight.isHidden = true
        highlightPlaced = false
        selectedIndex = -1
        heroCaptureWork?.cancel()

        let visible = SwitcherUI.usableFrame(of: screen)
        renderScale = max(screen.backingScaleFactor, 1)
        let size = Prefs.shared.size
        let searchHeight: CGFloat = searching ? 46 : 0
        let searchGap: CGFloat = searching ? sectionGap : 0
        let limits = SwitcherUI.contentLimits(in: visible, searching: searching)
        let maxWidth = limits.width
        let maxBody = limits.height
        let top = padding + searchHeight + searchGap
        var width: CGFloat
        var body: CGFloat
        highlight.glows = style == .deck
        let plateRadius: CGFloat = style == .deck ? 16 : (style == .titles ? 8 : 10)
        highlight.layer?.cornerRadius = plateRadius
        hoverPlate.layer?.cornerRadius = plateRadius

        switch style {
        case .deck:
            hero.isHidden = true
            let inset = TileLayout.deckInset
            let grid = TileLayout.compute(aspects: items.map { $0.isWindowless ? 1.6 : $0.aspectRatio }, style: .deck, size: size,
                                          available: CGSize(width: maxWidth - 2 * inset, height: maxBody - 2 * inset), rightToLeft: rightToLeft)
            layout = grid
            // Big cells (large size, few windows, a big display) get sharper captures; bounded to keep memory in check.
            let widest = grid.frames.map { max($0.width, grid.thumbnailHeight) }.max() ?? 0
            ThumbnailService.shared.maxPixelSize = min(max(720, (widest * screen.backingScaleFactor).rounded()), 1100)
            width = grid.contentSize.width + 2 * inset
            if searching { width = max(width, min(560, maxWidth)) }
            if items.isEmpty { width = max(width, 360) }
            width = width.rounded()
            body = items.isEmpty ? 90 : grid.viewportHeight + 2 * inset
            scrollView.frame = CGRect(x: padding, y: top, width: width, height: body)
            configureScrolling(horizontal: false)
            container.frame = CGRect(x: 0, y: 0, width: width, height: max(grid.contentSize.height + 2 * inset, body))
            placeTiles(items, grid, offset: CGPoint(x: ((width - grid.contentSize.width) / 2).rounded(), y: inset))
            emptyLabel.frame = CGRect(x: padding, y: top + body / 2 - 10, width: width, height: 20)
        case .stage:
            let factor: CGFloat = size == .small ? 0.5 : (size == .large ? 0.7 : 0.6)
            width = min(max(visible.width * factor, 640), maxWidth).rounded()
            let strip = TileLayout.compute(aspects: items.map(\.aspectRatio), style: .stage, size: size, available: CGSize(width: width, height: maxBody),
                                           rightToLeft: rightToLeft)
            layout = strip
            let stripHeight = strip.viewportHeight + 2 * TileLayout.ringInset
            let stageFactor: CGFloat = size == .small ? 0.3 : (size == .large ? 0.46 : 0.38)
            let stageHeight = max(120, min(width * 0.5, visible.height * stageFactor,
                                           maxBody - stripHeight - sectionGap - HeroView.infoHeight - HeroView.infoGap)).rounded()
            let heroHeight = stageHeight + HeroView.infoGap + HeroView.infoHeight
            hero.isHidden = false
            hero.frame = CGRect(x: padding, y: top, width: width, height: heroHeight)
            scrollView.frame = CGRect(x: padding, y: hero.frame.maxY + sectionGap, width: width, height: stripHeight)
            configureScrolling(horizontal: true)
            let stripWidth = strip.contentSize.width + 2 * TileLayout.ringInset
            container.frame = CGRect(x: 0, y: 0, width: max(stripWidth, width), height: stripHeight)
            let offsetX = max(0, ((width - stripWidth) / 2).rounded()) + TileLayout.ringInset
            placeTiles(items, strip, offset: CGPoint(x: offsetX, y: TileLayout.ringInset))
            body = heroHeight + sectionGap + stripHeight
            emptyLabel.frame = CGRect(x: padding, y: top + stageHeight / 2 - 10, width: width, height: 20)
        case .list:
            let listWidth = min(max(visible.width * 0.3, 360), 470).rounded()
            let previewWidth = min(max(visible.width * 0.36, 440), 700).rounded()
            width = min(listWidth + 20 + previewWidth, maxWidth)
            let list = TileLayout.compute(aspects: items.map(\.aspectRatio), style: .list, size: size,
                                          available: CGSize(width: listWidth, height: maxBody), rightToLeft: rightToLeft)
            layout = list
            let heroHeight = min((width - listWidth - 20) * 0.62 + HeroView.infoGap + HeroView.infoHeight, maxBody).rounded()
            body = max(min(list.contentSize.height, maxBody), heroHeight)
            // Right to left the list takes the right side and its stage the left.
            let listX = rightToLeft ? padding + width - listWidth : padding
            scrollView.frame = CGRect(x: listX, y: top, width: listWidth, height: body)
            configureScrolling(horizontal: false)
            container.frame = CGRect(x: 0, y: 0, width: listWidth, height: max(list.contentSize.height, body))
            placeTiles(items, list, offset: .zero)
            hero.isHidden = false
            hero.frame = CGRect(x: rightToLeft ? padding : padding + listWidth + 20, y: top + ((body - heroHeight) / 2).rounded(),
                                width: width - listWidth - 20, height: heroHeight)
            emptyLabel.frame = CGRect(x: listX, y: top + body / 2 - 10, width: listWidth, height: 20)
        case .titles:
            hero.isHidden = true
            // As wide as the longest title asks for, within limits.
            let rowSize = TileLayout.compute(aspects: [1], style: .titles, size: size, available: CGSize(width: 100, height: 100))
            let font = NSFont.systemFont(ofSize: rowSize.titleSize, weight: .medium)
            let longest = items.map { (TitleFormat.title(of: $0).text as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            let chrome = 10 + rowSize.iconSize + 9 + TileView.titleRowTrailing
            var listWidth = min(max(longest + chrome, 380), min(720, maxWidth)).rounded()
            if searching { listWidth = max(listWidth, min(520, maxWidth)) }
            let list = TileLayout.compute(aspects: items.map(\.aspectRatio), style: .titles, size: size,
                                          available: CGSize(width: listWidth, height: maxBody), rightToLeft: rightToLeft)
            layout = list
            width = listWidth
            body = items.isEmpty ? 64 : list.viewportHeight
            scrollView.frame = CGRect(x: padding, y: top, width: width, height: body)
            configureScrolling(horizontal: false)
            container.frame = CGRect(x: 0, y: 0, width: width, height: max(list.contentSize.height, body))
            placeTiles(items, list, offset: .zero)
            emptyLabel.frame = CGRect(x: padding, y: top + body / 2 - 10, width: width, height: 20)
        case .appIcons:
            hero.isHidden = true
            let grid = TileLayout.compute(aspects: items.map(\.aspectRatio), style: style, size: size,
                                          available: CGSize(width: maxWidth, height: maxBody), rightToLeft: rightToLeft)
            layout = grid
            width = grid.contentSize.width
            if searching { width = max(width, min(520, maxWidth)) }
            if items.isEmpty { width = max(width, 320) }
            body = items.isEmpty ? 64 : grid.viewportHeight
            scrollView.frame = CGRect(x: padding, y: top, width: width, height: body)
            configureScrolling(horizontal: false)
            container.frame = CGRect(x: 0, y: 0, width: width, height: max(grid.contentSize.height, body))
            placeTiles(items, grid, offset: CGPoint(x: ((width - grid.contentSize.width) / 2).rounded(), y: 0))
            emptyLabel.frame = CGRect(x: padding, y: top + body / 2 - 10, width: width, height: 20)
        }

        let panelSize = CGSize(width: (width + 2 * padding).rounded(), height: (top + body + padding).rounded())
        searchBar.isHidden = !searching
        searchBar.field.setAccessibilityLabel(L.t("Pencerelerde ara", "Search windows"))
        searchBar.frame = CGRect(x: padding, y: padding, width: width, height: searchHeight)
        searchBar.needsLayout = true
        // Not while an input method is composing: the field holds text the query doesn't have yet.
        if searching, !searchBar.isComposing, searchBar.field.stringValue != query { searchBar.field.stringValue = query }
        searchBar.countLabel.stringValue = searching && !query.isEmpty
            ? L.f("%1$@ / %2$@ pencere", "%1$@ of %2$@ windows", items.count, max(total ?? items.count, items.count)) : ""
        emptyLabel.isHidden = !items.isEmpty
        emptyLabel.stringValue = searching ? L.t("Eşleşen pencere yok", "No matching windows") : L.t("Açık pencere yok", "No open windows")
        if items.isEmpty { hero.show(nil, index: 0, count: 0, image: nil, direction: 0, transition: .instant) }
        root.frame = CGRect(origin: .zero, size: panelSize)

        // Centered on the screen; while searching, keep the top edge still so typing doesn't make the panel jump.
        var origin = CGPoint(x: (visible.midX - panelSize.width / 2).rounded(), y: (visible.midY - panelSize.height / 2).rounded())
        if keepPosition, panel.isVisible {
            origin = CGPoint(x: (panel.frame.midX - panelSize.width / 2).rounded(), y: (panel.frame.maxY - panelSize.height).rounded())
        }
        panel.setFrame(CGRect(origin: origin, size: panelSize), display: true)
    }

    /// A tile for each item, in place. One kept from an earlier build for the same item and look is moved and relabelled
    /// instead of being made again; the tiles this build doesn't show leave the panel (the keeper may hold on to them for later).
    private func placeTiles(_ items: [SwitcherItem], _ layout: TileLayout, offset: CGPoint) {
        let look = look(for: layout)
        // `offset` places the tiles from the container's left; right to left they keep that room from its right instead,
        // so the whole container is the mirror image of the left-to-right one.
        let originX = layout.isRightToLeft ? container.frame.width - layout.contentSize.width - offset.x : offset.x
        keeper.beginBuild()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var placed = [TileView]()
        for (index, item) in items.enumerated() {
            let frame = layout.frames[index].offsetBy(dx: originX, dy: offset.y)
            let blueprint = TileBlueprint(item, look: look)
            let tile: TileView
            if let kept = keeper.take(blueprint) {
                kept.reuse(index: index, item: item, frame: frame, layout: layout)
                tile = kept
            } else {
                tile = TileView(index: index, item: item, frame: frame, layout: layout, scale: renderScale)
                tile.delegate = self
                keeper.keep(tile, for: blueprint)
            }
            if let wid = item.wid { tile.setThumbnail(ThumbnailService.shared.image(for: wid)) }
            tile.setDockBadge(item.bundlePath.flatMap { DockBadges.current[$0] })
            placed.append(tile)
        }
        let shown = Set(placed.map(ObjectIdentifier.init))
        for case let tile as TileView in container.subviews where !shown.contains(ObjectIdentifier(tile)) {
            tile.removeFromSuperview()
        }
        for tile in placed where tile.superview !== container { container.addSubview(tile) }
        // Later tiles draw over earlier ones, as when every tile is new; kept ones may come back in another order.
        let order = container.subviews.compactMap { ($0 as? TileView)?.index }
        if zip(order, order.dropFirst()).contains(where: { $0 > $1 }) {
            container.sortSubviews({ first, second, _ in
                let (a, b) = (stackingRank(first), stackingRank(second))
                return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
            }, context: nil)
        }
        keeper.trim(to: max(64, 2 * items.count))
        tiles = placed
        CATransaction.commit()
    }

    /// What every tile of a build shares and bakes in; a kept tile made for another look isn't reused. The style is the one
    /// the build uses (`effectiveStyle`): a shortcut with a layout of its own never gets another layout's tiles.
    private func look(for layout: TileLayout) -> TileLook {
        TileLook(style: style, iconSize: layout.iconSize, titleSize: layout.titleSize, scale: renderScale,
                 appearance: panel.effectiveAppearance.name.rawValue, language: Prefs.shared.language,
                 showBadges: Prefs.shared.showBadges, showSpaceNumbers: Prefs.shared.showSpaceNumbers,
                 titleContent: Prefs.shared.titleContent, titleTruncation: Prefs.shared.titleTruncation)
    }

    private func configureScrolling(horizontal: Bool) {
        scrollView.layer?.mask = nil
        scrollView.hasVerticalScroller = !horizontal
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = horizontal ? .none : .automatic
        scrollView.horizontalScrollElasticity = horizontal ? .allowed : .none
        scrollView.contentView.setBoundsOrigin(.zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func focusSearchField() {
        // Already editing: re-focusing would restart the editing session and lose an input method's composition.
        guard searchBar.field.currentEditor() == nil else { return }
        panel.makeFirstResponder(searchBar.field)
        if let editor = searchBar.field.currentEditor() {
            editor.selectedRange = NSRange(location: searchBar.field.stringValue.utf16.count, length: 0)
        }
    }

    // MARK: - Selection

    func select(_ index: Int, animated: Bool) {
        guard tiles.indices.contains(index) else {
            highlight.isHidden = true
            if style == .stage || style == .list { hero.show(nil, index: 0, count: 0, image: nil, direction: 0, transition: .instant) }
            return
        }
        let previous = selectedIndex
        selectedIndex = index
        // Under Reduce Motion what moves (the plate, the deck's lift, the strip) jumps, and what fades still fades.
        let moves = animated && isRevealed && SwitcherUI.animatesMotion
        let fades = animated && isRevealed && SwitcherUI.animatesFades
        switch style {
        case .list, .titles:
            let target = tiles[index].frame
            moveHighlight(to: target, animated: moves, duration: 0.16, timing: CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0))
            if layout?.needsScrolling == true { container.scrollToVisible(target.insetBy(dx: 0, dy: -12)) }
            if hoverPlate.frame == target { hoverPlate.isHidden = true }
        case .deck:
            if tiles.indices.contains(previous) { tiles[previous].setSelected(false, animated: moves) }
            tiles[index].setSelected(true, animated: moves)
            // The plate glides to the new cell with a little overshoot, so the eye can follow it.
            let target = tiles[index].frame
            moveHighlight(to: target, animated: moves, duration: 0.24, timing: CAMediaTimingFunction(controlPoints: 0.3, 1.22, 0.45, 1))
            if layout?.needsScrolling == true { container.scrollToVisible(target.insetBy(dx: 0, dy: -TileLayout.deckInset)) }
            if hoverPlate.frame == target { hoverPlate.isHidden = true }
        case .stage:
            // The selection ring and the frame brightening fade; the strip scrolls.
            if tiles.indices.contains(previous) { tiles[previous].setSelected(false, animated: fades) }
            tiles[index].setSelected(true, animated: fades)
            centerStrip(on: index, animated: moves)
        case .appIcons:
            if tiles.indices.contains(previous) { tiles[previous].setSelected(false, animated: fades) }
            tiles[index].setSelected(true, animated: fades)
            if layout?.needsScrolling == true { container.scrollToVisible(tiles[index].frame.insetBy(dx: 0, dy: -14)) }
        }
        if style == .stage || style == .list {
            showOnStage(index, previous: previous, transition: HeroView.Transition(moves: moves, fades: fades))
        }
        NSAccessibility.post(element: tiles[index], notification: .focusedUIElementChanged)
    }

    private func moveHighlight(to target: CGRect, animated: Bool, duration: TimeInterval, timing: CAMediaTimingFunction) {
        highlight.isHidden = false
        if animated && highlightPlaced {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = timing
                context.allowsImplicitAnimation = true
                highlight.animator().frame = target
            }
        } else {
            highlight.frame = target
        }
        highlightPlaced = true
    }

    private func showOnStage(_ index: Int, previous: Int, transition: HeroView.Transition) {
        let item = items[index]
        let count = items.count
        var direction = 0
        if previous >= 0, previous != index, count > 1 {
            direction = (index - previous + count) % count <= count / 2 ? 1 : -1
        }
        heroIsSharp = false
        hero.show(item, index: index, count: count, image: item.wid.flatMap { ThumbnailService.shared.image(for: $0) },
                  direction: direction, transition: transition)
        requestHeroImage(delay: transition == .instant ? 0.02 : 0.09)
    }

    /// A full-resolution capture for the stage, taken once the selection settles (fast Tab-cycling skips it).
    func requestHeroImage(delay: TimeInterval = 0) {
        heroCaptureWork?.cancel()
        guard !hero.isHidden, let item = hero.item, let wid = item.wid else { return }
        let window = WindowStore.shared.windows[wid]
        let frame = window?.frame ?? item.frame
        let minimized = window?.isMinimized ?? item.isMinimized
        let maxSide = max(hero.bounds.width, hero.bounds.height) * panel.backingScaleFactor
        let work = DispatchWorkItem { [weak self] in
            ThumbnailService.shared.captureLarge(.init(wid: wid, frame: frame, isMinimized: minimized), maxSide: maxSide) { image in
                guard let self, let image, self.hero.item?.wid == wid else { return }
                self.heroIsSharp = true
                self.hero.update(image, for: wid)
            }
        }
        heroCaptureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Keeps the selected frame in the middle of the filmstrip.
    private func centerStrip(on index: Int, animated: Bool) {
        let clip = scrollView.contentView
        let visibleWidth = clip.bounds.width
        let maxX = max(0, container.frame.width - visibleWidth)
        // Measured from where the strip starts (its right end, right to left), so both directions round alike.
        let fromStart = isRightToLeft ? container.frame.width - tiles[index].frame.midX : tiles[index].frame.midX
        let scrolled = min(max(fromStart - visibleWidth / 2, 0), maxX).rounded()
        let x = isRightToLeft ? maxX - scrolled : scrolled
        guard abs(clip.bounds.origin.x - x) > 0.5 else {
            updateStripFades(originX: x, maxX: maxX)
            return
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
                clip.animator().setBoundsOrigin(NSPoint(x: x, y: 0))
            }
        } else {
            clip.setBoundsOrigin(NSPoint(x: x, y: 0))
        }
        scrollView.reflectScrolledClipView(clip)
        updateStripFades(originX: x, maxX: maxX)
    }

    /// Soft edges where the strip continues off-screen, so it reads as a carousel rather than a cut-off row.
    private func updateStripFades(originX: CGFloat, maxX: CGFloat) {
        guard style == .stage, maxX > 0 else {
            scrollView.layer?.mask = nil
            return
        }
        scrollView.wantsLayer = true
        let mask = (scrollView.layer?.mask as? CAGradientLayer) ?? CAGradientLayer()
        mask.frame = scrollView.bounds
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        let fade = min(0.08, 56 / max(scrollView.bounds.width, 1))
        let leftEdge = originX > 1 ? NSColor.clear.cgColor : NSColor.black.cgColor
        let rightEdge = originX < maxX - 1 ? NSColor.clear.cgColor : NSColor.black.cgColor
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.24)
        CATransaction.setDisableActions(!SwitcherUI.animatesFades)
        mask.colors = [leftEdge, NSColor.black.cgColor, NSColor.black.cgColor, rightEdge]
        mask.locations = [0, NSNumber(value: Double(fade)), NSNumber(value: Double(1 - fade)), 1]
        CATransaction.commit()
        scrollView.layer?.mask = mask
    }

    func updateDockBadges(_ badges: [String: String]) {
        for tile in tiles {
            tile.setDockBadge(tile.item.bundlePath.flatMap { badges[$0] })
        }
    }

    func updateThumbnail(_ wid: CGWindowID) {
        guard let image = ThumbnailService.shared.image(for: wid) else { return }
        for tile in tiles where tile.item.wid == wid {
            tile.setThumbnail(image, fades: SwitcherUI.animatesFades, moves: SwitcherUI.animatesMotion)
        }
        if !heroIsSharp, hero.item?.wid == wid { hero.update(image, for: wid) }
    }

    func tileFrameOnScreen(_ index: Int) -> CGRect? {
        guard tiles.indices.contains(index) else { return nil }
        let inWindow = tiles[index].convert(tiles[index].bounds, to: nil)
        return panel.convertToScreen(inWindow)
    }

    // MARK: - Show / hide

    func reveal(animated: Bool) {
        guard panel.isVisible, !isRevealed else { return }
        isRevealed = true
        // The mouse may have drifted while the panel was invisible: hover counts from where it is now.
        hoverDeadzoneOrigin = NSEvent.mouseLocation
        panel.ignoresMouseEvents = false
        if animated && SwitcherUI.animatesFades {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
        }
    }

    /// Makes the panel invisible at once; it is ordered out by `orderOut()` (immediately, or once the target
    /// window is in front, so the app being left can't grab focus back in between).
    func fadeOutImmediately() {
        isRevealed = false
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        heroCaptureWork?.cancel()
    }

    func orderOut() {
        isRevealed = false
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        panel.orderOut(nil)
        heroCaptureWork?.cancel()
        // The tiles stay in the hidden panel: the next summon moves the ones it shows and takes out the rest.
        tiles.removeAll()
        items = []
        selectedIndex = -1
        // A card may have been fading out with the selection on it: the next summon shows its highlight right away.
        highlight.alphaValue = 1
        hero.show(nil, index: 0, count: 0, image: nil, direction: 0, transition: .instant)
        searchBar.field.stringValue = ""
    }

    // MARK: - TileViewDelegate

    func tileHovered(_ tile: TileView, at point: NSPoint) {
        guard isRevealed else { return }
        if let origin = hoverDeadzoneOrigin {
            // Ignore the tile that happens to be under a resting cursor; react once the mouse actually moves.
            guard hypot(point.x - origin.x, point.y - origin.y) > 4 else { return }
            hoverDeadzoneOrigin = nil
        }
        if Prefs.shared.mouseHoverSelects {
            delegate?.switcherUIHovered(tile.index)
        } else if style == .list || style == .titles || style == .deck {
            hoverPlate.frame = tile.frame
            hoverPlate.isHidden = tile.frame == highlight.frame
        }
    }

    func tileClicked(_ tile: TileView) {
        delegate?.switcherUIClicked(tile.index)
    }

    func tile(_ tile: TileView, perform action: SwitcherAction) {
        delegate?.switcherUIPerform(action, at: tile.index)
    }

    /// The card under the files is where they would go: it takes the selection plate, whatever the hover setting.
    func tileDraggedOver(_ tile: TileView) {
        delegate?.switcherUIHovered(tile.index)
    }

    func tile(_ tile: TileView, open files: [URL]) {
        open(files, at: tile.index)
    }

    private func open(_ files: [URL], at index: Int) {
        // After the drag has finished with the panel: opening them ends the session and hides it.
        DispatchQueue.main.async { [weak self] in self?.delegate?.switcherUIOpen(files, at: index) }
    }

    // MARK: - NSWindowDelegate

    /// Clicking anywhere else (or another app taking focus) dismisses the switcher.
    func windowDidResignKey(_ notification: Notification) {
        delegate?.switcherUIResignedKey()
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        // Wait until the input method commits; half-composed text isn't a query yet.
        guard !searchBar.isComposing else { return }
        delegate?.switcherUIQueryChanged(searchBar.field.stringValue)
    }
}
