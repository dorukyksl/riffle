import Cocoa

/// Stand-ins for real windows, for renders that must never show anyone's real windows: `--mock` (docs) and
/// `--site-images` (the website). Shapes only, no text: each kind is recognizable by its layout and colors.
enum MockArt {
    enum Kind {
        case browser, terminal, code, notes, mail, finder, music, document
    }

    /// A window `width` pixels wide with the given width-to-height ratio.
    static func image(_ kind: Kind, width: Int, aspect: CGFloat) -> CGImage {
        let w = max(width, 200)
        let h = max(Int((CGFloat(w) / aspect).rounded()), 100)
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Drawn top-down in hundredths of the width, so every kind scales to any size.
        let unit = CGFloat(w) / 100
        context.translateBy(x: 0, y: CGFloat(h))
        context.scaleBy(x: unit, y: -unit)
        let canvas = Canvas(context: context, height: CGFloat(h) / unit)
        switch kind {
        case .browser: browser(canvas)
        case .terminal: terminal(canvas)
        case .code: code(canvas)
        case .notes: notes(canvas)
        case .mail: mail(canvas)
        case .finder: finder(canvas)
        case .music: music(canvas)
        case .document: document(canvas)
        }
        return context.makeImage()!
    }

    // MARK: - Kinds

    private static func browser(_ c: Canvas) {
        let accent: UInt32 = 0x2F6FED
        c.chrome(background: 0xFFFFFF, toolbar: 0xF3F3F5, line: 0xDCDCE1)
        c.rect(11, 2.6, 2.6, 2, 0xC4C4CA, radius: 0.5)
        c.bar(16, 3.1, 1.6, 1, 0xA9A9B0)
        c.bar(19, 3.1, 1.6, 1, 0xCFCFD4)
        c.rect(30, 1.9, 40, 3.4, 0xE5E5EA, radius: 1.7)
        c.circle(33.2, 3.6, 0.55, 0x9C9CA3)
        c.bar(35, 3.1, 19, 1, 0xA3A3AB)
        for x in [86.0, 90.0, 94.0] { c.rect(x, 2.7, 1.9, 1.9, 0xB9B9C0, radius: 0.4) }
        // The page: a site header, a headline with an image, a row of cards.
        c.rect(6, 9.6, 2.6, 2.6, accent, radius: 0.8)
        c.bar(10, 10.4, 8, 1.1, 0x26262B)
        for (index, x) in [56.0, 63.0, 70.0].enumerated() { c.bar(x, 10.4, index == 1 ? 6 : 5, 1, 0x8E8E95) }
        c.rect(80, 9.3, 14, 3.2, accent, radius: 1.6)
        c.bar(83.5, 10.4, 7, 1, 0xFFFFFF, alpha: 0.85)
        c.hline(14.4, 0xEFEFF2)
        let top: CGFloat = 19
        c.bar(6, top, 40, 3, 0x1D1D1F)
        c.bar(6, top + 4.6, 31, 3, 0x1D1D1F)
        for (index, width) in [38.0, 35, 24].enumerated() { c.bar(6, top + 11 + CGFloat(index) * 2.5, width, 1.1, 0x9A9AA2) }
        c.rect(6, top + 20, 13, 3.6, accent, radius: 1.8)
        c.bar(8.6, top + 21.3, 7.8, 1, 0xFFFFFF, alpha: 0.9)
        c.rect(21, top + 20, 12, 3.6, 0xECECF0, radius: 1.8)
        c.bar(23.6, top + 21.3, 6.8, 1, 0x55555C)
        c.gradient(52, top - 2, 42, 25, [0x8EC5FF, 0x2F6FED, 0x1D3FA8], radius: 2.2)
        c.circle(84, top + 4, 3.2, 0xFFFFFF, alpha: 0.35)
        c.rect(58, top + 13, 22, 1.4, 0xFFFFFF, radius: 0.7, alpha: 0.55)
        c.rect(58, top + 16.4, 15, 1.4, 0xFFFFFF, radius: 0.7, alpha: 0.4)
        let cardTop = top + 28
        guard cardTop + 8 < c.height else { return }
        let palettes: [[UInt32]] = [[0xFFD3A5, 0xFD6585], [0xC2E9FB, 0x81A4FD], [0xD4FC79, 0x96E6A1]]
        for (index, colors) in palettes.enumerated() {
            let x = 6 + CGFloat(index) * 30
            let height = min(c.height - cardTop - 3, 22)
            c.rect(x, cardTop, 28, height, 0xF5F5F7, radius: 1.6)
            c.gradient(x, cardTop, 28, height * 0.55, colors, radius: 1.6, roundBottom: false)
            c.bar(x + 2, cardTop + height * 0.55 + 2.2, 16, 1.1, 0x2A2A2F)
            c.bar(x + 2, cardTop + height * 0.55 + 4.6, 22, 0.9, 0xA3A3AA)
        }
    }

    private static func terminal(_ c: Canvas) {
        c.chrome(background: 0x1D1D20, toolbar: 0x2B2B2F, line: 0x111113)
        c.bar(40, 3.1, 20, 1, 0x7A7A80)
        let green: UInt32 = 0x30D158, white: UInt32 = 0xE6E6E9, gray: UInt32 = 0x8E8E94
        let cyan: UInt32 = 0x64D2FF, yellow: UInt32 = 0xFFD60A, pink: UInt32 = 0xFF6482
        let lines: [[(UInt32, CGFloat)]] = [
            [(green, 9), (cyan, 6), (white, 16)],
            [(gray, 30)],
            [(gray, 12), (cyan, 22), (gray, 9)],
            [(gray, 12), (cyan, 18), (gray, 9)],
            [(gray, 12), (cyan, 26), (gray, 9)],
            [(yellow, 8), (gray, 34)],
            [(gray, 12), (cyan, 20), (gray, 9)],
            [(green, 6), (gray, 24)],
            [],
            [(green, 9), (cyan, 6), (white, 22), (pink, 7)],
            [(gray, 18), (white, 12)],
            [(gray, 26)],
            [(gray, 21)],
            [],
            [(green, 9), (cyan, 6)],
        ]
        var y: CGFloat = 9.5
        for (index, line) in lines.enumerated() {
            guard y + 2 < c.height else { break }
            var x: CGFloat = 3
            for (color, width) in line {
                c.bar(x, y, width, 1.35, color)
                x += width + 1.2
            }
            if index == lines.count - 1 { c.rect(x, y - 0.35, 1.2, 2.1, white, radius: 0.2) }
            y += 3.4
        }
    }

    private static func code(_ c: Canvas) {
        c.chrome(background: 0x1F1F23, toolbar: 0x2A2A2E, line: 0x131315)
        c.triangle(11.6, 2.6, 2, 0xB4B4BA)
        c.rect(15, 2.7, 1.9, 1.9, 0x8A8A90, radius: 0.3)
        c.rect(32, 1.9, 36, 3.4, 0x37373C, radius: 1.7)
        c.rect(33.6, 2.9, 1.4, 1.4, 0xF0703C, radius: 0.3)
        c.bar(36, 3.1, 9, 1, 0xB0B0B6)
        c.bar(47, 3.1, 14, 1, 0x707076)
        // Project navigator.
        c.rect(0, 7.2, 19, c.height - 7.2, 0x252529)
        c.vline(19, from: 7.2, 0x141416)
        let rows: [(CGFloat, UInt32, CGFloat)] = [
            (0, 0x4FA3FF, 7), (1.6, 0x4FA3FF, 6), (3.2, 0xF0703C, 9), (3.2, 0xF0703C, 11), (3.2, 0xF0703C, 8),
            (3.2, 0xF0703C, 10), (1.6, 0x4FA3FF, 7), (3.2, 0xF0703C, 9), (3.2, 0xF0703C, 7), (1.6, 0x4FA3FF, 8), (3.2, 0x9D9DA3, 6),
        ]
        var y: CGFloat = 9.8
        for (index, row) in rows.enumerated() {
            guard y + 2 < c.height else { break }
            if index == 3 { c.rect(1, y - 0.75, 17, 2.6, 0x3A3A42, radius: 0.6) }
            c.rect(2 + row.0, y - 0.15, 1.4, 1.4, row.1, radius: 0.3)
            c.bar(4.2 + row.0, y, row.2, 1, index == 3 ? 0xFFFFFF : 0xA9A9AF)
            y += 2.85
        }
        // Editor: a tab, line numbers, highlighted Swift.
        c.rect(19, 7.2, 81, 3.8, 0x28282C)
        c.rect(20, 7.2, 17, 3.8, 0x1F1F23)
        c.rect(21.4, 8.4, 1.4, 1.4, 0xF0703C, radius: 0.3)
        c.bar(23.6, 8.6, 11, 1, 0xD0D0D4)
        let keyword: UInt32 = 0xFF7AB2, type: UInt32 = 0x5DD8FF, function: UInt32 = 0x67B7A4, string: UInt32 = 0xFF8170
        let plain: UInt32 = 0xDFDFE0, comment: UInt32 = 0x7F8C98, number: UInt32 = 0xD9C97C
        let code: [(CGFloat, [(UInt32, CGFloat)])] = [
            (0, [(comment, 26)]),
            (0, [(keyword, 6), (plain, 5)]),
            (0, []),
            (0, [(keyword, 4.5), (keyword, 5), (type, 17), (plain, 1.2)]),
            (1, [(keyword, 4.5), (plain, 9), (plain, 1.2), (type, 12)]),
            (1, [(keyword, 4), (plain, 13), (plain, 1.2), (number, 2)]),
            (1, []),
            (1, [(keyword, 4), (function, 10), (plain, 5), (type, 6), (plain, 1.2)]),
            (2, [(keyword, 5), (plain, 4), (plain, 1.2), (type, 9), (plain, 3)]),
            (2, [(plain, 7), (function, 8), (string, 14)]),
            (2, [(keyword, 3), (plain, 8), (keyword, 2.2), (plain, 6), (plain, 1.2)]),
            (3, [(plain, 6), (function, 11), (plain, 3)]),
            (2, [(plain, 1.2)]),
            (1, [(plain, 1.2)]),
            (0, [(plain, 1.2)]),
        ]
        y = 13.6
        for (index, line) in code.enumerated() {
            guard y + 2 < c.height else { break }
            c.bar(index + 1 >= 10 ? 20.6 : 21.4, y, index + 1 >= 10 ? 2.2 : 1.3, 1, 0x5D5D64)
            var x: CGFloat = 26 + line.0 * 3
            for (color, width) in line.1 {
                c.bar(x, y, width, 1.15, color)
                x += width + 1.1
            }
            y += 2.75
        }
    }

    private static func notes(_ c: Canvas) {
        let yellow: UInt32 = 0xF5C33B
        c.chrome(background: 0xFFFFFF, toolbar: 0xF7F6F3, line: 0xE4E2DD)
        c.rect(0, 7.2, 17, c.height - 7.2, 0xF1EFEA)
        c.vline(17, from: 7.2, 0xE1DED8)
        var y: CGFloat = 10.4
        for index in 0..<6 {
            guard y + 2 < c.height else { break }
            if index == 1 { c.rect(1, y - 0.8, 15, 2.8, 0xE3E0D9, radius: 0.6) }
            c.rect(2.4, y - 0.2, 1.4, 1.4, yellow, radius: 0.35)
            c.bar(4.8, y, [8, 9, 6.5, 8, 7, 9][index], 1, 0x6F6C67)
            y += 3.1
        }
        c.rect(17, 7.2, 26, c.height - 7.2, 0xFBFAF8)
        c.vline(43, from: 7.2, 0xE8E6E1)
        y = 9
        for index in 0..<6 {
            guard y + 7 < c.height else { break }
            if index == 0 { c.rect(18, y, 24, 7, 0xFBE7A0, radius: 1) }
            c.bar(20, y + 1.6, [15, 12, 16, 11, 14, 13][index], 1.2, 0x2B2925)
            c.bar(20, y + 4.1, 3.6, 0.9, 0xA5A29C)
            c.bar(24.6, y + 4.1, [14, 12, 10, 13, 11, 12][index], 0.9, 0xBDBAB4)
            y += 7.6
        }
        c.bar(48, 12, 30, 2.6, 0x1E1E1E)
        c.bar(48, 16.6, 9, 0.9, 0xA9A6A0)
        y = 21
        for width in [44.0, 41, 46, 28] {
            guard y + 2 < c.height else { break }
            c.bar(48, y, width, 1.1, 0x8D8A85)
            y += 2.6
        }
        y += 2.2
        for (index, width) in [22.0, 27, 18, 24].enumerated() {
            guard y + 2 < c.height else { break }
            if index < 2 {
                c.circle(49, y + 0.5, 1, yellow)
                c.bar(51.6, y, width, 1.1, 0xB5B2AC)
            } else {
                c.circle(49, y + 0.5, 1, 0xC9C6C0)
                c.circle(49, y + 0.5, 0.75, 0xFFFFFF)
                c.bar(51.6, y, width, 1.1, 0x55524D)
            }
            y += 3.2
        }
    }

    private static func mail(_ c: Canvas) {
        let blue: UInt32 = 0x2F7BF5
        c.chrome(background: 0xFFFFFF, toolbar: 0xF5F5F7, line: 0xDEDFE3)
        c.rect(0, 7.2, 17, c.height - 7.2, 0xEEF0F4)
        c.vline(17, from: 7.2, 0xDDE0E6)
        var y: CGFloat = 10.4
        for index in 0..<7 {
            guard y + 2 < c.height else { break }
            if index == 0 { c.rect(1, y - 0.8, 15, 2.8, 0xD9DEE8, radius: 0.6) }
            c.rect(2.4, y - 0.2, 1.4, 1.4, blue, radius: 0.35)
            c.bar(4.8, y, [7, 6, 8, 5.5, 7.5, 6, 8][index], 1, 0x5F6672)
            if index == 0 { c.bar(13.4, y, 1.6, 1, 0x8D95A3) }
            y += 3.1
        }
        c.vline(45, from: 7.2, 0xE3E5EA)
        y = 7.2
        for index in 0..<7 {
            guard y + 8 < c.height else { break }
            let selected = index == 1
            if selected { c.rect(17.6, y + 0.4, 26.8, 8, blue, radius: 1) }
            if index < 3 && !selected { c.circle(19, y + 2.4, 0.55, blue) }
            c.bar(20.4, y + 1.9, [10, 9, 12, 8, 11, 9.5, 10][index], 1.15, selected ? 0xFFFFFF : 0x15181E)
            c.bar(39, y + 1.9, 3.6, 0.9, selected ? 0xD6E4FE : 0x9AA1AD)
            c.bar(20.4, y + 4.2, [18, 16, 20, 14, 17, 19, 15][index], 1, selected ? 0xF2F6FF : 0x3A3F4A)
            c.bar(20.4, y + 6.2, [21, 19, 22, 18, 20, 16, 21][index], 0.85, selected ? 0xC8DBFF : 0xA2A8B3)
            if !selected && index != 0 { c.hline(y, 0xEEF0F3, from: 18, to: 45) }
            y += 8.6
        }
        c.gradientCircle(50.5, 13.6, 2.4, [0xFDBA74, 0xF97316])
        c.bar(54.6, 12, 12, 1.15, 0x15181E)
        c.bar(54.6, 14.4, 17, 0.9, 0x8A919C)
        c.bar(88, 12, 7, 0.9, 0x9AA1AD)
        c.bar(48, 20, 31, 1.7, 0x15181E)
        y = 25
        for width in [46.0, 43, 47, 30, 0, 44, 39] {
            guard y + 2 < c.height else { break }
            if width > 0 { c.bar(48, y, width, 1, 0x6B7280) }
            y += 2.5
        }
        if y + 9 < c.height { c.gradient(48, y + 1, 20, 8, [0xE0E7FF, 0xC7D2FE], radius: 1.2) }
    }

    private static func finder(_ c: Canvas) {
        let blue: UInt32 = 0x2F7BF5
        c.chrome(background: 0xFFFFFF, toolbar: 0xF5F5F7, line: 0xDEDFE3)
        c.bar(24, 3.1, 14, 1.1, 0x5F6672)
        c.rect(0, 7.2, 17, c.height - 7.2, 0xEEF0F4)
        c.vline(17, from: 7.2, 0xDDE0E6)
        var y: CGFloat = 10.4
        for index in 0..<8 {
            guard y + 2 < c.height else { break }
            if index == 2 { c.rect(1, y - 0.8, 15, 2.8, 0xD9DEE8, radius: 0.6) }
            c.rect(2.4, y - 0.2, 1.4, 1.4, index < 5 ? blue : [0xFF453A, 0xFF9F0A, 0x30D158][index - 5], radius: index < 5 ? 0.35 : 0.7)
            c.bar(4.8, y, [7, 8, 9, 6, 7.5, 5, 6, 5.5][index], 1, 0x5F6672)
            y += 3.1
        }
        enum Item { case folder, document(UInt32), picture([UInt32]), archive }
        let items: [Item] = [
            .folder, .folder, .document(0xEF4444), .picture([0xFFB199, 0xFF0844]), .folder,
            .picture([0x84FAB0, 0x8FD3F4]), .document(0x2F7BF5), .archive, .document(0x34C759), .picture([0xA18CD1, 0xFBC2EB]),
            .folder, .document(0xF59E0B), .picture([0xF6D365, 0xFDA085]), .folder, .document(0xEF4444),
        ]
        let columns = 5
        let cellWidth: CGFloat = 15.4, cellHeight: CGFloat = 15
        for (index, item) in items.enumerated() {
            let x = 21 + CGFloat(index % columns) * cellWidth
            let top = 11 + CGFloat(index / columns) * cellHeight
            guard top + cellHeight - 2 < c.height else { break }
            let cx = x + cellWidth / 2
            switch item {
            case .folder:
                c.rect(cx - 4.6, top + 0.6, 4, 1.8, 0x7FC0FA, radius: 0.6)
                c.rect(cx - 4.6, top + 1.6, 9.2, 6.6, 0x5AA9F5, radius: 0.8)
                c.rect(cx - 4.6, top + 2.8, 9.2, 5.4, 0x6BB5F8, radius: 0.8)
            case .document(let band):
                c.rect(cx - 3.2, top, 6.4, 8.4, 0xD9DCE1, radius: 0.6)
                c.rect(cx - 3, top + 0.2, 6, 8, 0xFFFFFF, radius: 0.5)
                for row in 0..<4 { c.bar(cx - 2, top + 1.6 + CGFloat(row) * 1.3, row == 3 ? 2.6 : 4, 0.5, 0xC5C9D0) }
                c.rect(cx - 3, top + 6.6, 6, 1.6, band, radius: 0.3)
            case .picture(let colors):
                c.rect(cx - 4.4, top + 1, 8.8, 6.6, 0xFFFFFF, radius: 0.6)
                c.gradient(cx - 4, top + 1.4, 8, 5.8, colors, radius: 0.4)
            case .archive:
                c.rect(cx - 3.4, top + 0.6, 6.8, 7.6, 0xB8BCC4, radius: 0.8)
                for row in 0..<4 { c.rect(cx - 0.5, top + 1.2 + CGFloat(row) * 1.5, 1, 0.8, 0x8E939C) }
            }
            if index == 6 {
                c.rect(cx - 5, top + 9.6, 10, 2, blue, radius: 1)
                c.bar(cx - 3.6, top + 10.1, 7.2, 0.9, 0xFFFFFF)
            } else {
                c.bar(cx - 3.8, top + 10.1, [7.6, 6, 7, 5.4, 6.6][index % 5], 0.9, 0x3A3F4A)
            }
        }
    }

    private static func music(_ c: Canvas) {
        let red: UInt32 = 0xFA2D48
        c.chrome(background: 0xFFFFFF, toolbar: 0xF7F7F8, line: 0xE2E2E6)
        c.rect(32, 1.4, 36, 4.4, 0xECECEF, radius: 1)
        c.gradient(32.6, 1.9, 3.4, 3.4, [0xFF9A3C, 0xFA2D48], radius: 0.5)
        c.bar(37.4, 2.2, 14, 1, 0x2C2C30)
        c.bar(37.4, 3.9, 9, 0.8, 0x96969C)
        c.rect(53, 3.6, 13, 0.6, 0xD1D1D6, radius: 0.3)
        c.rect(53, 3.6, 5.5, 0.6, red, radius: 0.3)
        c.rect(0, 7.2, 17, c.height - 7.2, 0xF2F2F4)
        c.vline(17, from: 7.2, 0xE3E3E7)
        var y: CGFloat = 10.4
        for index in 0..<8 {
            guard y + 2 < c.height else { break }
            if index == 1 { c.rect(1, y - 0.8, 15, 2.8, 0xE4E4E8, radius: 0.6) }
            c.rect(2.4, y - 0.2, 1.4, 1.4, red, radius: 0.35)
            c.bar(4.8, y, [7, 8, 6, 9, 7, 5.5, 8, 6.5][index], 1, 0x55555B)
            y += 3.1
        }
        c.bar(21, 11, 18, 2.2, 0x111114)
        c.bar(88, 11.6, 6, 1, red)
        let covers: [[UInt32]] = [
            [0xFA2D48, 0xFF9A3C], [0x4776E6, 0x8E54E9], [0x11998E, 0x38EF7D], [0xF7971E, 0xFFD200],
            [0xEC008C, 0xFC6767], [0x3A1C71, 0xFFAF7B], [0x00B4DB, 0x0083B0], [0xC33764, 0x1D2671],
        ]
        let side: CGFloat = 16.6, gap: CGFloat = 2.3
        for (index, colors) in covers.enumerated() {
            let x = 21 + CGFloat(index % 4) * (side + gap)
            let top = 16 + CGFloat(index / 4) * (side + 7.4)
            guard top + side + 4 < c.height else { break }
            c.gradient(x, top, side, side, colors, radius: 1)
            c.circle(x + side * 0.7, top + side * 0.32, side * 0.16, 0xFFFFFF, alpha: 0.22)
            c.bar(x, top + side + 1.4, [11, 9, 12, 8][index % 4], 1, 0x1C1C1E)
            c.bar(x, top + side + 3.4, [7, 8, 6, 9][index % 4], 0.85, 0x8E8E93)
        }
    }

    private static func document(_ c: Canvas) {
        c.chrome(background: 0xDADADF, toolbar: 0xF5F5F7, line: 0xD5D5DA)
        c.bar(24, 3.1, 16, 1.1, 0x55555B)
        let page = CGRect(x: 11, y: 11, width: 78, height: max(c.height - 15, 20))
        c.shadowed(page, 0xFFFFFF)
        let left = page.minX + 6, right = page.maxX - 6
        c.rect(left, page.minY + 6, 6, 6, 0xF97316, radius: 1.4)
        c.bar(right - 16, page.minY + 6.4, 16, 1.1, 0x4B5563)
        c.bar(right - 12, page.minY + 8.6, 12, 0.9, 0x9CA3AF)
        c.bar(right - 14, page.minY + 10.6, 14, 0.9, 0x9CA3AF)
        c.bar(left, page.minY + 18, 28, 2.4, 0x111827)
        c.bar(left, page.minY + 22.4, 18, 1, 0x9CA3AF)
        var y = page.minY + 30
        c.rect(left, y, right - left, 4, 0xF3F4F6, radius: 0.6)
        c.bar(left + 2, y + 1.5, 12, 1, 0x6B7280)
        c.bar(right - 10, y + 1.5, 8, 1, 0x6B7280)
        y += 4
        for (index, width) in [26.0, 20, 31, 18, 24].enumerated() {
            guard y + 5 < page.maxY - 14 else { break }
            c.bar(left + 2, y + 1.7, width, 1.05, 0x374151)
            c.bar(right - 2 - [8.0, 6.5, 9, 7, 8][index], y + 1.7, [8.0, 6.5, 9, 7, 8][index], 1.05, 0x374151)
            c.hline(y + 4.4, 0xE5E7EB, from: left, to: right)
            y += 4.4
        }
        guard y + 10 < page.maxY else { return }
        c.bar(right - 30, y + 3, 9, 1.1, 0x6B7280)
        c.bar(right - 13, y + 2.6, 11, 1.8, 0x111827)
        c.bar(left, page.maxY - 6, 30, 0.9, 0xB0B6BF)
        c.bar(left, page.maxY - 4, 22, 0.9, 0xB0B6BF)
    }
}

/// Drawing helpers in the art's units (hundredths of the width, top-left origin).
private struct Canvas {
    let context: CGContext
    let height: CGFloat

    static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hex: UInt32, radius: CGFloat = 0, alpha: CGFloat = 1) {
        context.setFillColor(Canvas.color(hex, alpha))
        let rect = CGRect(x: x, y: y, width: w, height: h)
        let r = min(radius, w / 2, h / 2)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        context.fillPath()
    }

    /// A rounded line of "text".
    func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hex: UInt32, alpha: CGFloat = 1) {
        rect(x, y, w, h, hex, radius: h / 2, alpha: alpha)
    }

    func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ hex: UInt32, alpha: CGFloat = 1) {
        context.setFillColor(Canvas.color(hex, alpha))
        context.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
    }

    func triangle(_ x: CGFloat, _ y: CGFloat, _ side: CGFloat, _ hex: UInt32) {
        context.setFillColor(Canvas.color(hex))
        context.move(to: CGPoint(x: x, y: y))
        context.addLine(to: CGPoint(x: x + side * 0.9, y: y + side / 2))
        context.addLine(to: CGPoint(x: x, y: y + side))
        context.closePath()
        context.fillPath()
    }

    func hline(_ y: CGFloat, _ hex: UInt32, from: CGFloat = 0, to: CGFloat = 100) {
        rect(from, y, to - from, 0.18, hex)
    }

    func vline(_ x: CGFloat, from: CGFloat, _ hex: UInt32) {
        rect(x, from, 0.18, height - from, hex)
    }

    func gradient(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hexes: [UInt32], radius: CGFloat = 0, roundBottom: Bool = true) {
        context.saveGState()
        let rect = CGRect(x: x, y: y, width: w, height: h)
        let r = min(radius, w / 2, h / 2)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        if !roundBottom { context.addRect(CGRect(x: x, y: y + h / 2, width: w, height: h / 2)) }
        context.clip()
        let colors = hexes.map { Canvas.color($0) } as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) {
            context.drawLinearGradient(gradient, start: CGPoint(x: x, y: y), end: CGPoint(x: x + w, y: y + h), options: [])
        }
        context.restoreGState()
    }

    func gradientCircle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ hexes: [UInt32]) {
        context.saveGState()
        context.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        context.clip()
        let colors = hexes.map { Canvas.color($0) } as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) {
            context.drawLinearGradient(gradient, start: CGPoint(x: cx - r, y: cy - r), end: CGPoint(x: cx + r, y: cy + r), options: [])
        }
        context.restoreGState()
    }

    func shadowed(_ rect: CGRect, _ hex: UInt32) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 0.4), blur: 2.4, color: Canvas.color(0x000000, 0.18))
        self.rect(rect.minX, rect.minY, rect.width, rect.height, hex, radius: 0.4)
        context.restoreGState()
    }

    /// Window background, toolbar and the three window buttons.
    func chrome(background: UInt32, toolbar: UInt32, line: UInt32) {
        rect(0, 0, 100, height, background)
        rect(0, 0, 100, 7.2, toolbar)
        hline(7.2 - 0.18, line)
        for (index, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
            circle(3 + CGFloat(index) * 2.7, 3.6, 0.85, hex)
        }
    }
}
