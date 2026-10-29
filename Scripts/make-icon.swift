// Draws Riffle's app icon with CoreGraphics and writes an .iconset folder.
// Usage: swift Scripts/make-icon.swift <output.iconset> [--layers <folder>]
// With --layers it also writes the icon's parts as 1024-pixel PNGs, each in place on a clear canvas (plate, card-back,
// card-middle, card-front, arrow), for the website to fan the cards out.
//
// What the app does, in one picture: a hand of windows fanned out like cards, the front one being riffled
// forward, and an arrow sweeping across them — switching from one window to the next. The window that comes
// forward carries the name, in the website's display face (Bricolage Grotesque, SIL OFL) and the icon's own sunset.
import AppKit
import CoreGraphics
import CoreText
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Riffle.iconset")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// The website's copy of the face, ExtraBold at its largest optical size. Falls back to the system font (heavy,
/// rounded) if the file is missing.
let brandFace: CTFontDescriptor = {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("website/fonts/bricolage-latin.woff2")
    if let data = try? Data(contentsOf: file),
       let faces = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor], let face = faces.first {
        let weight: UInt32 = 0x77676874, opticalSize: UInt32 = 0x6F70737A // 'wght', 'opsz'
        let variation = [weight: 800, opticalSize: 96] as CFDictionary
        return CTFontDescriptorCreateCopyWithAttributes(face, [kCTFontVariationAttribute: variation] as CFDictionary)
    }
    FileHandle.standardError.write("make-icon: \(file.path) is missing, using the system font\n".data(using: .utf8)!)
    let system = NSFont.systemFont(ofSize: 100, weight: .heavy).fontDescriptor.withDesign(.rounded)
    return (system ?? NSFont.systemFont(ofSize: 100, weight: .heavy).fontDescriptor) as CTFontDescriptor
}()

/// "Riffle" set `width` wide (ink bounds), with the face's own slightly tight display spacing.
func nameLine(width: CGFloat) -> (line: CTLine, bounds: CGRect) {
    func line(size: CGFloat) -> CTLine {
        let attributes: [CFString: Any] = [kCTFontAttributeName: CTFontCreateWithFontDescriptor(brandFace, size, nil),
                                           kCTKernAttributeName: -0.01 * size]
        return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "Riffle" as CFString, attributes as CFDictionary))
    }
    var size: CGFloat = 100
    for _ in 0..<3 { size *= width / CTLineGetBoundsWithOptions(line(size: size), .useGlyphPathBounds).width }
    let fitted = line(size: size)
    return (fitted, CTLineGetBoundsWithOptions(fitted, .useGlyphPathBounds))
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// The icon's parts, back to front.
enum Layer: String, CaseIterable { case plate, cardBack = "card-back", cardMiddle = "card-middle", cardFront = "card-front", arrow }

func drawIcon(size: Int, only layer: Layer? = nil) -> CGImage {
    func draws(_ part: Layer) -> Bool { layer == nil || layer == part }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.interpolationQuality = .high

    // Plate on the standard macOS icon grid.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = roundedRect(body, 186)
    if draws(.plate) {
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x2A0A3D, 0.45))
    context.addPath(bodyPath)
    context.setFillColor(color(0x6A2BD9))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    // Sunset: warm orange top-left through pink to violet bottom-right.
    let base = CGGradient(colorsSpace: space, colors: [color(0xFF9A4D), color(0xFF4F7B), color(0x7B3BF2)] as CFArray, locations: [0, 0.48, 1])!
    context.drawLinearGradient(base, start: CGPoint(x: 130, y: 900), end: CGPoint(x: 900, y: 120), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.32), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 300, y: 860), startRadius: 0, endCenter: CGPoint(x: 300, y: 860), endRadius: 560, options: [])
    context.restoreGState()
    }

    // The fan: cards rotate around a pivot below the middle, like a hand of cards.
    let pivot = CGPoint(x: 548, y: 178)
    let cardSize = CGSize(width: 452, height: 320)

    func card(angle: CGFloat, lift: CGFloat, fill: CGColor, front: Bool) {
        context.saveGState()
        context.translateBy(x: pivot.x, y: pivot.y)
        context.rotate(by: -angle * .pi / 180)
        let rect = CGRect(x: -cardSize.width / 2, y: 150 + lift, width: cardSize.width, height: cardSize.height)
        let path = roundedRect(rect, 38)
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: front ? 36 : 22, color: color(0x3A0A4A, front ? 0.5 : 0.35))
        context.addPath(path)
        context.setFillColor(fill)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        if front {
            // Title bar with traffic lights.
            context.saveGState()
            context.addPath(path)
            context.clip()
            context.setFillColor(color(0xF1ECF7))
            context.fill(CGRect(x: rect.minX, y: rect.maxY - 64, width: rect.width, height: 64))
            context.restoreGState()
            for (index, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
                context.setFillColor(color(hex))
                context.fillEllipse(in: CGRect(x: rect.minX + 30 + CGFloat(index) * 38, y: rect.maxY - 46, width: 26, height: 26))
            }
            // The name fills the window, in a deeper cut of the plate's sunset so it reads on white. Under 64 px it
            // could only be a smudge, so the smallest sizes show the window empty.
            if size >= 64 {
                let content = CGRect(x: rect.minX + 46, y: rect.minY, width: rect.width - 92, height: rect.height - 64)
                let name = nameLine(width: content.width)
                let ink = CGGradient(colorsSpace: space, colors: [color(0xE8552E), color(0xD3245F), color(0x5A2BD9)] as CFArray,
                                     locations: [0, 0.5, 1])!
                context.saveGState()
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: content.midX - name.bounds.midX, y: content.midY - name.bounds.midY)
                context.setTextDrawingMode(.clip)
                CTLineDraw(name.line, context)
                context.drawLinearGradient(ink, start: CGPoint(x: content.minX, y: content.maxY), end: CGPoint(x: content.maxX, y: content.minY), options: [])
                context.restoreGState()
            }
        }
        context.restoreGState()
    }

    if draws(.cardBack) { card(angle: -24, lift: -10, fill: color(0xFFFFFF, 0.42), front: false) }
    if draws(.cardMiddle) { card(angle: -10, lift: 0, fill: color(0xFFFFFF, 0.66), front: false) }
    if draws(.cardFront) { card(angle: 7, lift: 22, fill: color(0xFFFFFF, 1), front: true) }
    guard draws(.arrow) else { return context.makeImage()! }

    // The riffle: an arrow sweeping over the fan, from the back cards to the front one.
    context.saveGState()
    let arcCenter = CGPoint(x: 512, y: 150)
    let radius: CGFloat = 640
    let start: CGFloat = 118 * .pi / 180
    let end: CGFloat = 64 * .pi / 180
    let arrow = CGMutablePath()
    arrow.addArc(center: arcCenter, radius: radius, startAngle: start, endAngle: end, clockwise: true)
    context.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: color(0x3A0A4A, 0.35))
    context.addPath(arrow)
    context.setStrokeColor(color(0xFFFFFF, 0.95))
    context.setLineWidth(30)
    context.setLineCap(.round)
    context.strokePath()
    // Arrowhead at the end of the sweep, pointing along the arc.
    let tip = CGPoint(x: arcCenter.x + radius * cos(end), y: arcCenter.y + radius * sin(end))
    let tangent = CGPoint(x: sin(end), y: -cos(end)) // clockwise direction
    let normal = CGPoint(x: -tangent.y, y: tangent.x)
    let head = CGMutablePath()
    let length: CGFloat = 70
    let spread: CGFloat = 50
    head.move(to: CGPoint(x: tip.x + tangent.x * length * 0.55, y: tip.y + tangent.y * length * 0.55))
    head.addLine(to: CGPoint(x: tip.x - tangent.x * length * 0.45 + normal.x * spread, y: tip.y - tangent.y * length * 0.45 + normal.y * spread))
    head.addLine(to: CGPoint(x: tip.x - tangent.x * length * 0.45 - normal.x * spread, y: tip.y - tangent.y * length * 0.45 - normal.y * spread))
    head.closeSubpath()
    context.addPath(head)
    context.setFillColor(color(0xFFFFFF, 0.95))
    context.fillPath()
    context.restoreGState()

    return context.makeImage()!
}

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in entries {
    let image = drawIcon(size: pixels)
    let url = output.appendingPathComponent("\(name).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}
if let index = CommandLine.arguments.firstIndex(of: "--layers"), index + 1 < CommandLine.arguments.count {
    let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for layer in Layer.allCases {
        let url = folder.appendingPathComponent("\(layer.rawValue).png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, drawIcon(size: 1024, only: layer), nil)
        CGImageDestinationFinalize(destination)
    }
}
print("wrote \(output.path)")
