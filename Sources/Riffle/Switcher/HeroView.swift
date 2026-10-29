import Cocoa
import QuartzCore

/// The stage: the selected window shown large and live, with what it is underneath (icon, title, app, where it
/// lives) and where it sits in the list. Changing the selection slides the next window in.
final class HeroView: FlippedView {
    static let infoHeight: CGFloat = 52
    static let infoGap: CGFloat = 12

    var onClick: (() -> Void)?
    /// Files dropped on the stage, for the window it shows.
    var onDrop: (([URL]) -> Void)?
    private(set) var item: SwitcherItem?

    /// Arabic and Hebrew: the line under the stage reads right to left (icon on the right, the counter on the left), and
    /// the next window slides in from the left, the way the list runs. The window itself is never flipped.
    var isRightToLeft = false {
        didSet {
            guard isRightToLeft != oldValue else { return }
            counterLabel.alignment = isRightToLeft ? .left : .right
            chips.userInterfaceLayoutDirection = isRightToLeft ? .rightToLeft : .leftToRight
            needsLayout = true
        }
    }

    private let backdrop = CALayer()
    private let imageShadow = CALayer()
    private let imageLayer = CALayer()
    private let iconLayer = CALayer()
    private let infoIcon = CALayer()
    private let captionLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let counterLabel = NSTextField(labelWithString: "")
    private let chips = NSStackView()
    private var imageSize: CGSize?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        backdrop.cornerRadius = 18
        backdrop.cornerCurve = .continuous
        backdrop.actions = ["backgroundColor": CABasicAnimation(keyPath: "backgroundColor")]
        layer?.addSublayer(backdrop)
        imageShadow.shadowColor = NSColor.black.cgColor
        imageShadow.shadowOpacity = 0.35
        imageShadow.shadowRadius = 14
        imageShadow.shadowOffset = CGSize(width: 0, height: -4)
        layer?.addSublayer(imageShadow)
        imageLayer.cornerRadius = 12
        imageLayer.cornerCurve = .continuous
        imageLayer.masksToBounds = true
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
        iconLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(iconLayer)
        infoIcon.contentsGravity = .resizeAspect
        layer?.addSublayer(infoIcon)
        for label in [captionLabel, titleLabel, subtitleLabel, counterLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        captionLabel.alignment = .center
        captionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        captionLabel.textColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        counterLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        counterLabel.textColor = .tertiaryLabelColor
        counterLabel.alignment = .right
        chips.orientation = .horizontal
        chips.spacing = 6
        addSubview(chips)
        applyColors()
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// The stage takes on a faint tint of the window it shows, like ambient light from a screen.
    private var ambient: NSColor?

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = NSColor.labelColor.withAlphaComponent(0.05)
            backdrop.backgroundColor = (ambient.map { $0.withAlphaComponent(0.2) } ?? base).cgColor
            backdrop.borderColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
            backdrop.borderWidth = 1
        }
    }

    static func averageColor(_ image: CGImage) -> NSColor? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let alpha = CGFloat(pixel[3]) / 255
        guard alpha > 0.05 else { return nil }
        return NSColor(srgbRed: CGFloat(pixel[0]) / 255 / alpha, green: CGFloat(pixel[1]) / 255 / alpha, blue: CGFloat(pixel[2]) / 255 / alpha, alpha: 1)
    }

    private var stageRect: CGRect {
        CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - HeroView.infoHeight - HeroView.infoGap))
    }

    /// How the stage changes to another window: at once, dissolving (under Reduce Motion), or sliding in.
    enum Transition {
        case instant, fade, slide

        init(moves: Bool, fades: Bool) {
            self = moves ? .slide : (fades ? .fade : .instant)
        }
    }

    /// Which side a window comes in from when the selection moves `direction` (+1 forward, -1 back): forward is towards
    /// the end of the list, which lies to the right, or to the left when the panel reads right to left.
    static func slideSubtype(direction: Int, rightToLeft: Bool) -> CATransitionSubtype {
        (direction > 0) != rightToLeft ? .fromRight : .fromLeft
    }

    /// Shows `item`. `direction` (+1 forward, -1 back, 0 none) picks which side the new window slides in from.
    func show(_ item: SwitcherItem?, index: Int, count: Int, image: CGImage?, direction: Int, transition: Transition) {
        let changed = self.item?.id != item?.id
        self.item = item
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if changed && transition != .instant && direction != 0 {
            let change = CATransition()
            if transition == .slide {
                change.type = .push
                change.subtype = HeroView.slideSubtype(direction: direction, rightToLeft: isRightToLeft)
            } else {
                change.type = .fade
            }
            change.duration = 0.2
            change.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            imageLayer.add(change, forKey: "slide")
            iconLayer.add(change, forKey: "slide")
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.16
            imageShadow.add(fade, forKey: "fade")
        }
        setImage(image)
        updateInfo(index: index, count: count)
        CATransaction.commit()
        needsLayout = true
    }

    /// A sharper or fresher capture for the window on stage; it dissolves in unless the panel's animations are off.
    func update(_ image: CGImage, for wid: CGWindowID) {
        guard item?.wid == wid else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(imageLayer.contents == nil || !SwitcherUI.animatesFades)
        setImage(image)
        CATransaction.commit()
        layoutStage()
    }

    private func setImage(_ image: CGImage?) {
        guard let item else {
            imageLayer.contents = nil
            iconLayer.contents = nil
            captionLabel.isHidden = true
            return
        }
        if let image {
            imageLayer.contents = image
            imageSize = CGSize(width: image.width, height: image.height)
            ambient = HeroView.averageColor(image)
            applyColors()
            iconLayer.contents = nil
            imageLayer.isHidden = false
            imageShadow.isHidden = false
            captionLabel.isHidden = true
        } else {
            imageLayer.contents = nil
            imageSize = nil
            ambient = nil
            applyColors()
            imageLayer.isHidden = true
            imageShadow.isHidden = true
            iconLayer.contents = IconCache.image(for: item, points: 128, scale: 2)
            // Without Screen Recording no preview is coming: the icon alone, not a promise that never ends.
            captionLabel.isHidden = !item.isWindowless && !ThumbnailService.shared.isAvailable
            captionLabel.stringValue = item.isWindowless
                ? L.t("Açık penceresi yok — ↩ ile yeni pencere aç", "No open windows — press ↩ to open one")
                : L.t("Önizleme hazırlanıyor…", "Preparing preview…")
        }
        let dim: Float = (item.isMinimized || item.isHidden) ? 0.6 : 1
        imageLayer.opacity = dim
        imageShadow.opacity = dim * 0.35
    }

    private func updateInfo(index: Int, count: Int) {
        guard let item else {
            titleLabel.stringValue = ""
            subtitleLabel.stringValue = ""
            counterLabel.stringValue = ""
            chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
            infoIcon.contents = nil
            return
        }
        infoIcon.contents = IconCache.image(for: item, points: 34, scale: 2)
        let truncation = Prefs.shared.titleTruncation.lineBreakMode
        let title = TitleFormat.title(of: item)
        let detail = TitleFormat.stageDetail(of: item)
        let alignment: NSTextAlignment = isRightToLeft ? .right : .natural
        titleLabel.lineBreakMode = truncation
        subtitleLabel.lineBreakMode = truncation
        titleLabel.attributedStringValue = TileView.highlighted(title.text, matches: title.matches, font: titleLabel.font!, color: .labelColor,
                                                                alignment: alignment, lineBreakMode: truncation)
        subtitleLabel.attributedStringValue = TileView.highlighted(detail?.text ?? "", matches: detail?.matches ?? [], font: subtitleLabel.font!,
                                                                   color: .secondaryLabelColor, alignment: alignment, lineBreakMode: truncation)
        counterLabel.stringValue = count > 1 ? "\(index + 1) / \(count)" : ""
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for chip in HeroView.chips(for: item, rightToLeft: isRightToLeft) { chips.addArrangedSubview(chip) }
    }

    static func chips(for item: SwitcherItem, rightToLeft: Bool = false) -> [NSView] {
        var result = [NSView]()
        if let space = item.otherSpaceIndex, Prefs.shared.showSpaceNumbers {
            result.append(Chip(symbol: "square.on.square", text: L.f("Masaüstü %1$@", "Desktop %1$@", space), rightToLeft: rightToLeft))
        }
        if item.isFullscreen {
            result.append(Chip(symbol: "arrow.up.left.and.arrow.down.right", text: L.t("Tam ekran", "Full screen"), rightToLeft: rightToLeft))
        }
        if item.isMinimized { result.append(Chip(symbol: "dock.arrow.down.rectangle", text: L.t("Küçültülmüş", "Minimized"), rightToLeft: rightToLeft)) }
        if item.isHidden { result.append(Chip(symbol: "eye.slash", text: L.t("Gizli", "Hidden"), rightToLeft: rightToLeft)) }
        if item.isWindowless { result.append(Chip(symbol: "moon.zzz", text: L.t("Pencere yok", "No windows"), rightToLeft: rightToLeft)) }
        if let badge = item.bundlePath.flatMap({ DockBadges.current[$0] }) {
            result.append(Chip(symbol: "bell.badge.fill", text: badge, tint: .systemRed, rightToLeft: rightToLeft))
        }
        return result
    }

    /// `rect` as laid out left to right, mirrored when the stage reads right to left.
    private func mirrored(_ rect: CGRect) -> CGRect {
        isRightToLeft ? rect.mirrored(within: bounds.width) : rect
    }

    override func layout() {
        super.layout()
        layoutStage()
        let infoTop = stageRect.maxY + HeroView.infoGap
        infoIcon.frame = mirrored(CGRect(x: 4, y: infoTop + 6, width: 38, height: 38))
        let textX: CGFloat = 54
        let counterWidth: CGFloat = 70
        titleLabel.frame = mirrored(CGRect(x: textX, y: infoTop + 4, width: bounds.width - textX - counterWidth - 8, height: 22))
        counterLabel.frame = mirrored(CGRect(x: bounds.width - counterWidth, y: infoTop + 7, width: counterWidth, height: 16))
        // No second line when the title already names the app and the window: the chips take its place.
        let hasSubtitle = subtitleLabel.attributedStringValue.length > 0
        let subtitleWidth = hasSubtitle ? min(ceil(subtitleLabel.attributedStringValue.size().width) + 6, bounds.width * 0.45) : 0
        let subtitle = CGRect(x: textX, y: infoTop + 29, width: subtitleWidth, height: 17)
        subtitleLabel.frame = mirrored(subtitle)
        let chipsX = hasSubtitle ? subtitle.maxX + 10 : textX
        let chipsSize = chips.fittingSize
        chips.frame = mirrored(CGRect(x: chipsX, y: infoTop + 27, width: min(chipsSize.width, bounds.width - chipsX), height: 20))
    }

    private func layoutStage() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let stage = stageRect
        backdrop.frame = stage
        let inner = stage.insetBy(dx: 16, dy: 16)
        if let imageSize {
            let fitted = TileView.aspectFit(imageSize, in: inner)
            imageLayer.frame = fitted
            imageShadow.frame = fitted
            imageShadow.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: fitted.size), cornerWidth: 12, cornerHeight: 12, transform: nil)
        }
        let side = min(128, inner.height * 0.5)
        iconLayer.frame = CGRect(x: stage.midX - side / 2, y: stage.midY - side / 2 - 12, width: side, height: side)
        captionLabel.frame = CGRect(x: stage.minX + 20, y: iconLayer.frame.maxY + 12, width: stage.width - 40, height: 18)
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if stageRect.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    // MARK: - Dropping files

    private func takesDrop(_ sender: NSDraggingInfo) -> Bool {
        guard let item else { return false }
        return FileDrop.route(for: item, files: FileDrop.files(on: sender.draggingPasteboard)) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        takesDrop(sender) ? FileDrop.operation(allowed: sender.draggingSourceOperationMask) : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard takesDrop(sender) else { return false }
        onDrop?(FileDrop.files(on: sender.draggingPasteboard))
        return true
    }
}

/// A small capsule label: icon + text (the icon on the right, right to left).
final class Chip: NSView {
    init(symbol: String, text: String, tint: NSColor? = nil, rightToLeft: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        // A little less room on the icon's side.
        if rightToLeft {
            // Both, so the stack's leading edge and the chip's are the same side.
            userInterfaceLayoutDirection = .rightToLeft
            stack.userInterfaceLayoutDirection = .rightToLeft
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 7)
        } else {
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 8)
        }
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9.5, weight: .semibold)) ?? NSImage())
        image.contentTintColor = tint ?? .secondaryLabelColor
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = tint ?? .secondaryLabelColor
        stack.addArrangedSubview(image)
        stack.addArrangedSubview(label)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 19),
        ])
        self.tint = tint
        applyColors()
    }

    private var tint: NSColor?

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (tint ?? .labelColor).withAlphaComponent(tint == nil ? 0.08 : 0.16).cgColor
        }
    }
}
