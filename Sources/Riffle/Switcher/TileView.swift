import Cocoa
import QuartzCore

protocol TileViewDelegate: AnyObject {
    func tileHovered(_ tile: TileView, at point: NSPoint)
    func tileClicked(_ tile: TileView)
    func tile(_ tile: TileView, perform action: SwitcherAction)
    /// Files are being dragged over the tile, and it would take them.
    func tileDraggedOver(_ tile: TileView)
    func tile(_ tile: TileView, open files: [URL])
}

/// Caches app icons rendered at a given size, so building tiles never re-rasterizes icons.
enum IconCache {
    private static var cache = [String: CGImage]()

    static func image(for item: SwitcherItem, points: CGFloat, scale: CGFloat) -> CGImage? {
        let key = "\(item.bundleID ?? "pid\(item.pid)")-\(Int(points * scale))"
        if let cached = cache[key] { return cached }
        var rect = CGRect(x: 0, y: 0, width: points * scale, height: points * scale)
        let image = item.icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        cache[key] = image
        return image
    }
}

/// A small dark capsule with an SF Symbol and/or a number, drawn over thumbnails. Right to left the symbol comes first
/// on the right.
final class BadgeView: NSView {
    init(symbol: String?, text: String?, tooltip: String, rightToLeft: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
        layer?.cornerCurve = .continuous
        // No hover tooltips in the switcher; VoiceOver still reads what it means.
        setAccessibilityLabel(tooltip)
        let stack = NSStackView()
        if rightToLeft {
            // Both, so the stack's leading edge and the badge's are the same side.
            userInterfaceLayoutDirection = .rightToLeft
            stack.userInterfaceLayoutDirection = .rightToLeft
        }
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 5, bottom: 0, right: 5)
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            let view = NSImageView(image: image.withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) ?? image)
            view.contentTintColor = .white
            stack.addArrangedSubview(view)
        }
        if let text {
            let label = NSTextField(labelWithString: text)
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
            label.textColor = .white
            stack.addArrangedSubview(label)
        }
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        frame.size = NSSize(width: max(18, stack.fittingSize.width), height: 18)
        layer?.cornerRadius = 9
    }

    required init?(coder: NSCoder) { nil }
}

/// One quick action on a deck cell's tray: a small rounded tile with a white symbol. Close, minimize and full screen
/// keep the colors people know from window buttons; quitting the app (as ⌘Q would) is graphite, like a power switch.
final class CardButton: NSButton {
    static let side: CGFloat = 20
    let action_: SwitcherAction
    private let top: NSColor
    private let bottom: NSColor
    private let glyph: String
    private var hovering = false
    private var hoverArea: NSTrackingArea?

    /// `undo`: the window is already in that state (full screen), so the button takes it back: the green button then
    /// shows its arrows pointing inwards.
    init(_ action: SwitcherAction, label: String, undo: Bool = false) {
        action_ = action
        func rgb(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        switch action {
        case .quit: (top, bottom, glyph) = (rgb(0x5C5C63), rgb(0x232327), "power")
        case .close: (top, bottom, glyph) = (rgb(0xFF6A5E), rgb(0xE5372B), "xmark")
        case .minimize: (top, bottom, glyph) = (rgb(0xFFC23D), rgb(0xE79A00), "minus")
        default: (top, bottom, glyph) = (rgb(0x3FD46A), rgb(0x1E9E46), undo ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
        super.init(frame: NSRect(x: 0, y: 0, width: CardButton.side, height: CardButton.side))
        isBordered = false
        title = ""
        setAccessibilityLabel(label)
        focusRingType = .none
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: CardButton.side, height: CardButton.side) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let tile = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        var colors = [top, bottom]
        if isHighlighted { colors = colors.map { $0.blended(withFraction: 0.2, of: .black) ?? $0 } }
        else if hovering { colors = colors.map { $0.blended(withFraction: 0.15, of: .white) ?? $0 } }
        // The lighter color on top (the button draws flipped).
        NSGradient(colors: colors)?.draw(in: tile, angle: isFlipped ? 90 : -90)
        // A thin light edge on top, like light catching glass.
        NSColor.white.withAlphaComponent(hovering ? 0.55 : 0.3).setStroke()
        tile.lineWidth = 0.75
        tile.stroke()
        guard let symbol = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: glyph == "power" ? 10 : 9.5, weight: .bold)) else { return }
        let white = NSImage(size: symbol.size, flipped: false) { area in
            symbol.draw(in: area)
            NSColor.white.set()
            area.fill(using: .sourceAtop)
            return true
        }
        white.draw(in: NSRect(x: (bounds.midX - symbol.size.width / 2).rounded(), y: (bounds.midY - symbol.size.height / 2).rounded(),
                              width: symbol.size.width, height: symbol.size.height))
    }
}

/// The frosted strip the quick actions sit on, so they read on any thumbnail. The first button is on the left, or on
/// the right when the cell reads right to left (as window buttons are in a right-to-left title bar).
final class CardTray: NSView {
    static let padding: CGFloat = 4
    static let spacing: CGFloat = 5

    init(buttons: [CardButton], rightToLeft: Bool = false) {
        let count = CGFloat(buttons.count)
        let width = count * CardButton.side + (count - 1) * CardTray.spacing + 2 * CardTray.padding
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: CardButton.side + 2 * CardTray.padding))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 5
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        for (offset, button) in buttons.enumerated() {
            let place = CGRect(x: CardTray.padding + CGFloat(offset) * (CardButton.side + CardTray.spacing), y: CardTray.padding,
                               width: CardButton.side, height: CardButton.side)
            button.frame.origin = (rightToLeft ? place.mirrored(within: width) : place).origin
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { nil }
}

/// One switcher tile: a window (thumbnail, icon, title, status) or an app without windows.
///
/// - `.deck`: a cell with a header (app icon, title, status) over the window's thumbnail; the selection plate
///   sliding behind the cells is drawn by `SwitcherUI`.
/// - `.stage`: a filmstrip frame under the stage: edge-to-edge capture, the app icon in its corner.
/// - `.appIcons`: a big icon with the title below.
/// - `.titles`: a compact row (icon, title, status, number).
/// - `.list`: a row (icon, title, app, number).
final class TileView: NSView {
    weak var delegate: TileViewDelegate?
    /// Both change when a kept tile is reused in a later build (see `reuse`).
    private(set) var index: Int
    private(set) var item: SwitcherItem
    private var layout: TileLayout
    private let style: SwitcherStyle

    private let thumbnailShadow = CALayer()
    private let thumbnailLayer = CALayer()
    private let placeholderLayer = CALayer()
    private let iconShadow = CALayer()
    private let iconLayer = CALayer()
    private let ringLayer = CALayer()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let numberLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var badges = [BadgeView]()
    private var dockBadge: NSTextField?
    private var windowlessCaption: NSTextField?
    private var cardButtons: NSView?
    /// Where the thumbnail may go; `thumbnailRect` is where it is (the capture fitted into the box).
    private var thumbnailBox = CGRect.zero
    private var thumbnailRect = CGRect.zero
    private var thumbnail: CGImage?
    private var hasThumbnail = false
    private(set) var isSelected = false
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    static let ringWidth: CGFloat = 2.5

    override var isFlipped: Bool { true }

    init(index: Int, item: SwitcherItem, frame: CGRect, layout: TileLayout, scale: CGFloat = 2) {
        self.index = index
        self.item = item
        self.layout = layout
        self.scale = scale
        style = layout.style
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        // One element for VoiceOver: the card is a button that says what it shows; its labels and badges aren't read
        // again on their own (the window buttons that appear on hover stay their own buttons).
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(TitleFormat.spokenDescription(of: item, showing: titleContent))
        build()
        for label in [titleLabel, subtitleLabel, numberLabel, statusLabel] { label.setAccessibilityElement(false) }
        badges.forEach { $0.setAccessibilityElement(false) }
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The panel screen's pixels per point; icons are rasterized for it.
    private let scale: CGFloat
    /// What the labels say and where long ones are cut, as the settings were when the tile was made (see `TileLook`).
    private let titleContent = Prefs.shared.titleContent
    private let titleTruncation = Prefs.shared.titleTruncation.lineBreakMode
    private var isDimmed: Bool { item.isMinimized || item.isHidden }

    // MARK: - Direction

    /// Contents are placed as for left to right, then mirrored inside the tile when it reads right to left. Mirroring
    /// twice gives the rect back, so this also turns a placed frame back into its left-to-right place.
    private func mirrored(_ rect: CGRect) -> CGRect {
        layout.isRightToLeft ? rect.mirrored(within: bounds.width) : rect
    }

    /// Titles start at the reading direction's side; numbers sit at the other end.
    private var leadingAlignment: NSTextAlignment { layout.isRightToLeft ? .right : .natural }
    private var trailingAlignment: NSTextAlignment { layout.isRightToLeft ? .left : .right }

    // MARK: - Building

    private func build() {
        ringLayer.borderWidth = TileView.ringWidth
        ringLayer.cornerCurve = .continuous
        ringLayer.opacity = 0
        thumbnailShadow.shadowColor = NSColor.black.cgColor
        thumbnailShadow.shadowOpacity = 0.3
        thumbnailShadow.shadowRadius = 6
        thumbnailShadow.shadowOffset = CGSize(width: 0, height: -2)
        thumbnailLayer.cornerCurve = .continuous
        thumbnailLayer.masksToBounds = true
        thumbnailLayer.minificationFilter = .trilinear
        thumbnailLayer.borderWidth = 0.5
        placeholderLayer.contentsGravity = .resizeAspect
        iconLayer.contentsGravity = .resizeAspect
        iconShadow.shadowColor = NSColor.black.cgColor
        iconShadow.shadowOpacity = 0.35
        iconShadow.shadowRadius = 4
        iconShadow.shadowOffset = CGSize(width: 0, height: -1)
        for sublayer in [ringLayer, thumbnailShadow, thumbnailLayer, placeholderLayer, iconShadow, iconLayer] {
            layer?.addSublayer(sublayer)
        }
        // Labels after the layers, so text always sits on top.
        for label in [titleLabel, subtitleLabel, numberLabel, statusLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.truncatesLastVisibleLine = true
            label.allowsDefaultTighteningForTruncation = true
            label.isHidden = true
            addSubview(label)
        }
        titleLabel.lineBreakMode = titleTruncation
        subtitleLabel.lineBreakMode = titleTruncation
        switch style {
        case .deck: buildDeckCell()
        case .stage: buildStripItem()
        case .appIcons: buildIconTile()
        case .titles: buildTitleRow()
        case .list: buildListRow()
        }
        // Deck cells show their status in the header instead.
        if Prefs.shared.showBadges, style != .deck { buildBadges() }
        layoutContents()
        updateTitle()
        updateNumber()
    }

    /// Puts everything inside the tile in place for its size: when it's made, and when a reused tile changes size.
    private func layoutContents() {
        switch style {
        case .deck: layoutDeckCell()
        case .stage: layoutStripItem()
        case .appIcons: layoutIconTile()
        case .titles: layoutTitleRow()
        case .list: layoutListRow()
        }
        layoutBadges()
        // The capture (or the placeholder) fits the new box.
        if style == .deck || style == .stage { setThumbnail(thumbnail) }
    }

    private func buildDeckCell() {
        iconLayer.contents = IconCache.image(for: item, points: layout.iconSize, scale: scale)
        iconLayer.opacity = isDimmed ? 0.6 : 1
        iconShadow.isHidden = true
        // Status at the far end of the header: minimized, hidden, full screen, the desktop it lives on.
        if let status = TileView.statusText(for: item, size: layout.titleSize, rightToLeft: layout.isRightToLeft) {
            statusLabel.attributedStringValue = status
            statusLabel.isHidden = false
        }
        titleLabel.isHidden = false
        thumbnailLayer.cornerRadius = 10
        thumbnailLayer.contentsGravity = .resizeAspectFill
        thumbnailShadow.shadowOpacity = 0.24
        thumbnailShadow.shadowRadius = 8
    }

    private func layoutDeckCell() {
        let inset = TileLayout.cellInset
        let side = layout.iconSize
        let icon = CGRect(x: inset, y: inset, width: side, height: side)
        iconLayer.frame = mirrored(icon)
        var right = bounds.width - inset
        if !statusLabel.isHidden {
            let width = min(ceil(statusLabel.fittingSize.width) + 2, bounds.width * 0.4)
            let status = CGRect(x: right - width, y: inset + ((side - 18) / 2).rounded(), width: width, height: 18)
            statusLabel.frame = mirrored(status)
            right = status.minX - 6
        }
        let titleX = icon.maxX + 8
        let lineHeight = ceil(layout.titleSize * 1.3)
        titleLabel.frame = mirrored(CGRect(x: titleX, y: inset + ((side - lineHeight) / 2).rounded(), width: max(right - titleX, 10), height: lineHeight))
        thumbnailBox = CGRect(x: inset, y: inset + side + TileLayout.headerGap,
                              width: max(bounds.width - 2 * inset, 1), height: max(bounds.height - inset - side - TileLayout.headerGap - inset, 1))
    }

    private static let stripIconSide: CGFloat = 22

    private func buildStripItem() {
        thumbnailLayer.cornerRadius = 10
        thumbnailLayer.contentsGravity = .resizeAspectFill
        iconLayer.contents = IconCache.image(for: item, points: TileView.stripIconSide, scale: 2)
        ringLayer.cornerRadius = 13
        alphaValue = 0.62
    }

    private func layoutStripItem() {
        thumbnailBox = bounds
        let side = TileView.stripIconSide
        iconLayer.frame = mirrored(CGRect(x: 6, y: bounds.height - side - 6, width: side, height: side))
        iconShadow.frame = iconLayer.frame
        iconShadow.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: iconLayer.frame.size), cornerWidth: 5, cornerHeight: 5, transform: nil)
        ringLayer.frame = bounds.insetBy(dx: -4, dy: -4)
    }

    private func buildIconTile() {
        let side = layout.iconSize
        iconLayer.contents = IconCache.image(for: item, points: side, scale: scale)
        iconLayer.opacity = isDimmed ? 0.55 : 1
        iconShadow.isHidden = true
        ringLayer.cornerRadius = side * 0.3
        titleLabel.isHidden = false
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 2
        titleLabel.cell?.wraps = true
    }

    private func layoutIconTile() {
        let side = layout.iconSize
        iconLayer.frame = CGRect(x: (bounds.width - side) / 2, y: 12, width: side, height: side)
        ringLayer.frame = iconLayer.frame.insetBy(dx: -9, dy: -9)
        titleLabel.frame = CGRect(x: 6, y: iconLayer.frame.maxY + 8, width: bounds.width - 12, height: 32)
    }

    /// Room a title row keeps on its trailing side for the status badges and the number.
    static let titleRowTrailing: CGFloat = 96

    /// The titles style: the icon and one line of title, the badges and the number at the end.
    private func buildTitleRow() {
        iconLayer.contents = IconCache.image(for: item, points: layout.iconSize, scale: scale)
        iconLayer.opacity = isDimmed ? 0.55 : 1
        iconShadow.isHidden = true
        titleLabel.isHidden = false
        numberLabel.isHidden = false
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        numberLabel.textColor = .tertiaryLabelColor
        numberLabel.alignment = trailingAlignment
    }

    private func layoutTitleRow() {
        let side = layout.iconSize
        let icon = CGRect(x: 10, y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
        iconLayer.frame = mirrored(icon)
        let numberWidth: CGFloat = 22
        let number = CGRect(x: bounds.width - numberWidth - 10, y: ((bounds.height - 15) / 2).rounded(), width: numberWidth, height: 15)
        numberLabel.frame = mirrored(number)
        let textX = icon.maxX + 9
        let lineHeight = ceil(layout.titleSize * 1.3)
        titleLabel.frame = mirrored(CGRect(x: textX, y: ((bounds.height - lineHeight) / 2).rounded(),
                                           width: max(number.minX - 8 - textX, 10), height: lineHeight))
    }

    private func buildListRow() {
        iconLayer.contents = IconCache.image(for: item, points: layout.iconSize, scale: scale)
        iconLayer.opacity = isDimmed ? 0.55 : 1
        iconShadow.isHidden = true
        titleLabel.isHidden = false
        numberLabel.isHidden = false
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        numberLabel.textColor = .tertiaryLabelColor
        numberLabel.alignment = trailingAlignment
    }

    /// The title over its second line, or alone and centered when the title says it all.
    private func layoutListRow() {
        let side = layout.iconSize
        let icon = CGRect(x: 12, y: (bounds.height - side) / 2, width: side, height: side)
        iconLayer.frame = mirrored(icon)
        let textX = icon.maxX + 10
        let numberWidth: CGFloat = 26
        let textWidth = bounds.width - textX - numberWidth - 90
        let titleHeight: CGFloat = 18
        let subtitleHeight: CGFloat = subtitleLabel.isHidden ? 0 : 15
        let top = (bounds.height - titleHeight - subtitleHeight) / 2
        titleLabel.frame = mirrored(CGRect(x: textX, y: top, width: textWidth, height: titleHeight))
        subtitleLabel.frame = mirrored(CGRect(x: textX, y: top + titleHeight, width: textWidth, height: subtitleHeight))
        numberLabel.frame = mirrored(CGRect(x: bounds.width - numberWidth - 10, y: (bounds.height - 15) / 2, width: numberWidth, height: 15))
    }

    /// The label for the current item, as the settings ask (and the list's line under it), its search matches highlighted.
    private func updateTitle() {
        let title = TitleFormat.title(of: item, showing: titleContent)
        switch style {
        case .deck:
            let font = NSFont.systemFont(ofSize: layout.titleSize, weight: isSelected ? .semibold : .medium)
            titleLabel.attributedStringValue = TileView.highlighted(title.text, matches: title.matches, font: font,
                                                                    color: isDimmed && !isSelected ? .secondaryLabelColor : .labelColor,
                                                                    alignment: leadingAlignment, lineBreakMode: titleTruncation)
        case .appIcons:
            let font = NSFont.systemFont(ofSize: 11.5, weight: isSelected ? .semibold : .medium)
            titleLabel.attributedStringValue = TileView.highlighted(title.text, matches: title.matches, font: font,
                                                                    color: isSelected ? .labelColor : .secondaryLabelColor, alignment: .center,
                                                                    lineBreakMode: titleTruncation)
        case .titles:
            let font = NSFont.systemFont(ofSize: layout.titleSize, weight: .medium)
            titleLabel.attributedStringValue = TileView.highlighted(title.text, matches: title.matches, font: font,
                                                                    color: isDimmed ? .secondaryLabelColor : .labelColor,
                                                                    alignment: leadingAlignment, lineBreakMode: titleTruncation)
        case .list:
            titleLabel.font = .systemFont(ofSize: bounds.height > 40 ? 14 : 13, weight: .medium)
            titleLabel.attributedStringValue = TileView.highlighted(title.text, matches: title.matches, font: titleLabel.font!, color: .labelColor,
                                                                    alignment: leadingAlignment, lineBreakMode: titleTruncation)
            let detail = TitleFormat.listDetail(of: item, showing: titleContent)
            subtitleLabel.attributedStringValue = TileView.highlighted(detail?.text ?? "", matches: detail?.matches ?? [],
                                                                       font: subtitleLabel.font!, color: .secondaryLabelColor,
                                                                       alignment: leadingAlignment, lineBreakMode: titleTruncation)
            if subtitleLabel.isHidden != (detail == nil) {
                subtitleLabel.isHidden = detail == nil
                layoutListRow()
            }
        case .stage:
            break
        }
        settleVibrancy(of: titleLabel)
        settleVibrancy(of: subtitleLabel)
    }

    /// A label in the panel's glass is drawn vibrant only while its text has nothing but label colors (a search match's
    /// accent turns that off), and on macOS 27 AppKit settles that once, when the label joins the panel. A kept tile
    /// changes its text in place, so its labels settle it again: otherwise a relabelled tile keeps the look its earlier
    /// text gave it and draws unlike a new one.
    private func settleVibrancy(of label: NSTextField) {
        guard label.window != nil, label.allowsVibrancy != label.effectiveAppearance.allowsVibrancy else { return }
        // Only a change of the label's own appearance makes AppKit decide again.
        label.appearance = label.effectiveAppearance
        label.appearance = nil
    }

    private func updateNumber() {
        guard style == .titles || style == .list else { return }
        numberLabel.stringValue = index < 9 ? "\(index + 1)" : ""
    }

    // MARK: - Reuse

    /// Takes this tile into a later build for `item`, which gives the same blueprint (see `TileKeeper`): moves it to `frame`,
    /// lays its contents out again if its size changed, and renews what may differ: the title (and its search matches),
    /// the number, the colors. Whatever the last session left on it (selection, hover buttons) is cleared.
    func reuse(index: Int, item: SwitcherItem, frame newFrame: CGRect, layout: TileLayout) {
        self.index = index
        self.item = item
        self.layout = layout
        layer?.removeAnimation(forKey: "leave")
        if isSelected { setSelected(false, animated: false) }
        alphaValue = style == .stage ? 0.62 : 1
        isHovered = false
        // Rebuilt on the next hover, for the cell's new size.
        cardButtons?.removeFromSuperview()
        cardButtons = nil
        let resized = frame.size != newFrame.size
        frame = newFrame
        if resized { layoutContents() }
        updateTitle()
        updateNumber()
        applyColors()
        setAccessibilityLabel(TitleFormat.spokenDescription(of: item, showing: titleContent))
    }

    /// The header's status: small symbols, and the desktop number when the window lives on another one. Drawn at draw
    /// time, so the symbols follow light and dark. Right to left the first symbol is on the right and each number on its
    /// symbol's left, as the badges of the other layouts read.
    static func statusText(for item: SwitcherItem, size: CGFloat, rightToLeft: Bool = false) -> NSAttributedString? {
        var parts = [(String, String?, String)]()
        if item.isMinimized { parts.append(("dock.arrow.down.rectangle", nil, L.t("Küçültülmüş", "Minimized"))) }
        if item.isHidden { parts.append(("eye.slash", nil, L.t("Gizli", "Hidden"))) }
        if item.isFullscreen { parts.append(("arrow.up.left.and.arrow.down.right", nil, L.t("Tam ekran", "Full screen"))) }
        if Prefs.shared.showSpaceNumbers, let space = item.otherSpaceIndex {
            parts.append(("square.on.square", "\(space)", L.f("%1$@. masaüstünde", "On desktop %1$@", space)))
        }
        guard Prefs.shared.showBadges, !parts.isEmpty else { return nil }
        let result = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: max(size - 2, 11), weight: .semibold)
        for (offset, part) in parts.enumerated() {
            if offset > 0 { result.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            if let symbol = NSImage(systemSymbolName: part.0, accessibilityDescription: part.2)?
                .withSymbolConfiguration(.init(pointSize: max(size - 3, 10), weight: .semibold)) {
                let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                    symbol.draw(in: rect)
                    NSColor.secondaryLabelColor.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                let attachment = NSTextAttachment()
                attachment.image = tinted
                attachment.bounds = CGRect(x: 0, y: -2, width: symbol.size.width, height: symbol.size.height)
                result.append(NSAttributedString(attachment: attachment))
            }
            if let text = part.1 {
                result.append(NSAttributedString(string: " " + text, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            }
        }
        if rightToLeft {
            // Symbols and digits have no direction of their own: the paragraph's decides their order.
            let paragraph = NSMutableParagraphStyle()
            paragraph.baseWritingDirection = .rightToLeft
            paragraph.alignment = .right
            result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        }
        return result
    }

    private func buildBadges() {
        var specs = [(String?, String?, String)]()
        if item.isWindowless { specs.append(("moon.zzz.fill", nil, L.t("Açık pencere yok", "No open windows"))) }
        if item.isMinimized { specs.append(("dock.arrow.down.rectangle", nil, L.t("Küçültülmüş", "Minimized"))) }
        if item.isHidden { specs.append(("eye.slash.fill", nil, L.t("Gizli uygulama", "Hidden app"))) }
        if item.isFullscreen { specs.append(("arrow.up.left.and.arrow.down.right", nil, L.t("Tam ekran", "Full screen"))) }
        if Prefs.shared.showSpaceNumbers, let space = item.otherSpaceIndex {
            specs.append(("square.on.square", "\(space)", L.f("%1$@. masaüstünde", "On desktop %1$@", space)))
        }
        guard !specs.isEmpty else { return }
        badges = specs.map { BadgeView(symbol: $0.0, text: $0.1, tooltip: $0.2, rightToLeft: layout.isRightToLeft) }
        badges.forEach(addSubview)
    }

    /// Placed as for left to right (frames read back through `mirrored`), then mirrored.
    private func layoutBadges() {
        guard !badges.isEmpty else { return }
        func place(_ badge: BadgeView, at origin: CGPoint) {
            badge.frame = mirrored(CGRect(origin: origin, size: badge.frame.size))
        }
        switch style {
        case .deck:
            break
        case .stage:
            var x: CGFloat = 5
            for badge in badges {
                place(badge, at: CGPoint(x: x, y: 5))
                x += badge.frame.width + 3
            }
        case .appIcons:
            // Top-left of the icon: the top-right corner belongs to the Dock badge.
            let icon = mirrored(iconLayer.frame)
            var left = max(4, icon.minX - 10)
            for badge in badges {
                place(badge, at: CGPoint(x: left, y: max(2, icon.minY - 6)))
                left += badge.frame.width + 3
            }
        case .list, .titles:
            var x = mirrored(numberLabel.frame).minX - 8
            for badge in badges.reversed() {
                x -= badge.frame.width
                place(badge, at: CGPoint(x: x, y: ((bounds.height - 18) / 2).rounded()))
                x -= 4
            }
            // A title stops where the badges begin.
            if style == .titles {
                var title = mirrored(titleLabel.frame)
                title.size.width = max(x - 4 - title.minX, 10)
                titleLabel.frame = mirrored(title)
            }
        }
    }

    // MARK: - State

    func setSelected(_ selected: Bool, animated: Bool) {
        guard style != .list, style != .titles, selected != isSelected else { return }
        isSelected = selected
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.3, 1.3, 0.5, 1))
        if style == .deck {
            // The chosen thumbnail comes forward a touch.
            let lift = selected ? CATransform3DMakeScale(1.025, 1.025, 1) : CATransform3DIdentity
            thumbnailLayer.transform = lift
            thumbnailShadow.transform = lift
            thumbnailShadow.shadowOpacity = selected ? 0.38 : 0.24
            thumbnailShadow.shadowRadius = selected ? 14 : 8
        } else {
            ringLayer.opacity = selected ? 1 : 0
        }
        CATransaction.commit()
        if style == .stage {
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    animator().alphaValue = selected ? 1 : 0.62
                }
            } else {
                alphaValue = selected ? 1 : 0.62
            }
        }
        updateTitle()
    }

    /// The app's Dock badge (unread count etc.), pinned to the icon's corner like the Dock draws it: the top right, or the
    /// top left when the tile reads right to left.
    func setDockBadge(_ label: String?) {
        setAccessibilityLabel(TitleFormat.spokenDescription(of: item, showing: titleContent, dockBadge: label))
        guard let label, !label.isEmpty else {
            dockBadge?.removeFromSuperview()
            dockBadge = nil
            return
        }
        let badge = dockBadge ?? {
            let field = NSTextField(labelWithString: "")
            field.alignment = .center
            field.textColor = .white
            field.wantsLayer = true
            field.layer?.backgroundColor = NSColor.systemRed.cgColor
            field.layer?.cornerCurve = .continuous
            // The card's own label already says it.
            field.setAccessibilityElement(false)
            addSubview(field)
            dockBadge = field
            return field
        }()
        let small = style != .appIcons || layout.iconSize < 40
        badge.font = .systemFont(ofSize: small ? 9 : 11, weight: .bold)
        badge.stringValue = label
        let height: CGFloat = small ? 14 : 18
        let width = max(height, ceil(badge.intrinsicContentSize.width) + (small ? 7 : 9))
        let icon = mirrored(iconLayer.isHidden && !placeholderLayer.isHidden ? placeholderLayer.frame : iconLayer.frame)
        badge.frame = mirrored(CGRect(x: icon.maxX - width * 0.6, y: icon.minY - height * 0.35, width: width, height: height))
        badge.layer?.cornerRadius = height / 2
        badge.setAccessibilityLabel(L.f("Dock rozeti: %1$@", "Dock badge: %1$@", label))
    }

    /// Shows a window capture, or the app icon on a soft plate when there is none yet. A fresher capture of a window
    /// already showing one dissolves in when `fades`; if its shape changed, the picture glides to it only when `moves`
    /// too (under Reduce Motion it takes the new shape at once).
    func setThumbnail(_ image: CGImage?, fades: Bool = false, moves: Bool = false) {
        guard style == .deck || style == .stage else { return }
        thumbnail = image
        CATransaction.begin()
        CATransaction.setDisableActions(!fades || !hasThumbnail || image == nil)
        let plate: CGRect
        if let image {
            plate = style == .deck ? TileView.aspectFit(CGSize(width: image.width, height: image.height), in: thumbnailBox) : thumbnailBox
            thumbnailLayer.contents = image
            placeholderLayer.isHidden = true
            thumbnailShadow.isHidden = false
            hasThumbnail = true
        } else {
            thumbnailLayer.contents = nil
            if style == .deck {
                // The window's own shape (a plain card for apps without windows), so nothing jumps when the capture lands.
                let shape = item.isWindowless ? CGSize(width: 16, height: 10) : CGSize(width: max(item.aspectRatio, 0.5) * 100, height: 100)
                plate = TileView.aspectFit(shape, in: thumbnailBox)
                let side = min(64, plate.height * 0.46, plate.width * 0.46).rounded()
                let lift: CGFloat = item.isWindowless ? 9 : 0
                placeholderLayer.frame = CGRect(x: plate.midX - side / 2, y: plate.midY - side / 2 - lift, width: side, height: side)
            } else {
                plate = thumbnailBox
                let side = min(34, plate.height * 0.5, plate.width * 0.5)
                placeholderLayer.frame = CGRect(x: plate.midX - side / 2, y: plate.midY - side / 2 - 4, width: side, height: side)
            }
            thumbnailShadow.isHidden = style == .stage
            placeholderLayer.contents = IconCache.image(for: item, points: placeholderLayer.frame.width, scale: scale)
            placeholderLayer.isHidden = false
            hasThumbnail = false
        }
        CATransaction.begin()
        if !moves { CATransaction.setDisableActions(true) }
        // Bounds and position rather than frame: the deck may be scaling the layer (selection).
        for target in [thumbnailLayer, thumbnailShadow] {
            target.bounds = CGRect(origin: .zero, size: plate.size)
            target.position = CGPoint(x: plate.midX, y: plate.midY)
        }
        thumbnailShadow.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: plate.size), cornerWidth: thumbnailLayer.cornerRadius,
                                            cornerHeight: thumbnailLayer.cornerRadius, transform: nil)
        CATransaction.commit()
        thumbnailRect = plate
        let dim: Float = isDimmed ? 0.55 : 1
        thumbnailLayer.opacity = dim
        placeholderLayer.opacity = dim
        switch style {
        case .stage:
            // The corner icon is only needed when the frame shows a capture; otherwise the placeholder is the icon.
            iconLayer.isHidden = !hasThumbnail
            iconShadow.isHidden = !hasThumbnail
        case .deck:
            if item.isWindowless {
                let caption = windowlessCaption ?? {
                    let label = NSTextField(labelWithString: L.t("Açık pencere yok", "No open windows"))
                    label.font = .systemFont(ofSize: 11.5, weight: .medium)
                    label.textColor = .tertiaryLabelColor
                    label.alignment = .center
                    addSubview(label)
                    windowlessCaption = label
                    return label
                }()
                caption.frame = CGRect(x: plate.minX, y: placeholderLayer.frame.maxY + 6, width: plate.width, height: 15)
            }
            placeCardButtons()
        default:
            break
        }
        applyColors()
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        updateTitle()
    }

    /// Layer colors don't follow the appearance by themselves; resolve them for the current one.
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            thumbnailLayer.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            thumbnailLayer.backgroundColor = hasThumbnail ? nil : NSColor.labelColor.withAlphaComponent(0.07).cgColor
            ringLayer.borderColor = Palette.accent.cgColor
            ringLayer.backgroundColor = style == .appIcons ? Palette.accent.withAlphaComponent(0.14).cgColor : nil
        }
    }

    // MARK: - Hover buttons (deck)

    func showCardButtons(_ show: Bool) {
        guard style == .deck else { return }
        if show, cardButtons == nil {
            // Quitting the app first, then closing this window, then minimize and full screen. An app without windows
            // can only be quit.
            // Finder can't be quit (macOS keeps it running), nor Riffle from its own switcher: no button that would only beep.
            let unquittable = item.bundleID == "com.apple.finder" || item.pid == ProcessInfo.processInfo.processIdentifier
            let quit = unquittable ? [] : [CardButton(.quit, label: L.t("Uygulamadan çık", "Quit app"))]
            var buttons = item.isWindowless ? quit : quit + [CardButton(.close, label: L.t("Pencereyi kapat", "Close window")),
                                                        CardButton(.minimize, label: item.isMinimized ? L.t("Geri getir", "Restore") : L.t("Küçült", "Minimize")),
                                                        item.isFullscreen
                                                            ? CardButton(.fullscreen, label: L.t("Tam ekrandan çık", "Exit full screen"), undo: true)
                                                            : CardButton(.fullscreen, label: L.t("Tam ekran", "Full screen"))]
            // A narrow cell keeps the first ones that fit: the tray must stay inside the cell to be clickable.
            let room = bounds.width - 8 - 2 * CardTray.padding + CardTray.spacing
            let fits = max(1, Int(room / (CardButton.side + CardTray.spacing)))
            if buttons.count > fits { buttons = Array(buttons.prefix(fits)) }
            for button in buttons {
                button.target = self
                button.action = #selector(cardButtonPressed(_:))
            }
            guard !buttons.isEmpty else { return }
            let tray = CardTray(buttons: buttons, rightToLeft: layout.isRightToLeft)
            addSubview(tray)
            cardButtons = tray
            placeCardButtons()
        }
        cardButtons?.isHidden = !show
    }

    /// At the thumbnail's top left (top right, right to left), but never sticking out of the cell.
    private func placeCardButtons() {
        guard let tray = cardButtons else { return }
        let thumbnail = mirrored(thumbnailRect)
        let x = max(4, min(thumbnail.minX + 6, bounds.width - tray.frame.width - 4))
        tray.frame = mirrored(CGRect(origin: CGPoint(x: x, y: thumbnail.minY + 6), size: tray.frame.size))
    }

    @objc private func cardButtonPressed(_ sender: CardButton) {
        delegate?.tile(self, perform: sender.action_)
    }

    static func aspectFit(_ size: CGSize, in box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let width = max((size.width * scale).rounded(), 1)
        let height = max((size.height * scale).rounded(), 1)
        return CGRect(x: (box.midX - width / 2).rounded(), y: (box.midY - height / 2).rounded(), width: width, height: height)
    }

    static func highlighted(_ text: String, matches: [Int], font: NSFont, color: NSColor, matchColor: NSColor? = nil,
                            alignment: NSTextAlignment = .natural, lineBreakMode: NSLineBreakMode = .byTruncatingTail) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreakMode
        paragraph.alignment = alignment
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        guard !matches.isEmpty else { return result }
        let matchSet = Set(matches)
        let bold = NSFont.systemFont(ofSize: font.pointSize, weight: .heavy)
        var offset = 0
        for (index, character) in text.enumerated() {
            let length = String(character).utf16.count
            if matchSet.contains(index) {
                result.addAttributes([.font: bold, .foregroundColor: matchColor ?? Palette.accent], range: NSRange(location: offset, length: length))
            }
            offset += length
        }
        return result
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        delegate?.tileHovered(self, at: NSEvent.mouseLocation)
    }

    override func mouseMoved(with event: NSEvent) {
        if !isHovered, window?.ignoresMouseEvents == false {
            isHovered = true
            showCardButtons(true)
        }
        delegate?.tileHovered(self, at: NSEvent.mouseLocation)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        showCardButtons(false)
    }

    /// VoiceOver's "press" (VO-Space) switches to the window, like a click.
    override func accessibilityPerformPress() -> Bool {
        delegate?.tileClicked(self)
        return true
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { delegate?.tileClicked(self) }
    }

    // MARK: - Dropping files

    /// Whether the files of the drag in progress may land here; settled once, when it comes over the tile.
    private var takesDrop = false

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        takesDrop = FileDrop.route(for: item, files: FileDrop.files(on: sender.draggingPasteboard)) != nil
        let operation = draggingUpdated(sender)
        if !operation.isEmpty { delegate?.tileDraggedOver(self) }
        return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        takesDrop ? FileDrop.operation(allowed: sender.draggingSourceOperationMask) : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        takesDrop = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = FileDrop.files(on: sender.draggingPasteboard)
        guard takesDrop, FileDrop.route(for: item, files: files) != nil else { return false }
        takesDrop = false
        delegate?.tile(self, open: files)
        return true
    }
}
