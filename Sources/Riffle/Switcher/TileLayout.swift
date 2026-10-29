import CoreGraphics

/// Pure layout of switcher tiles: balanced wrapping rows, shrink-to-fit and arrow-key geometry. No AppKit, fully testable.
struct TileLayout {
    enum Move { case left, right, up, down }

    static let spacing: CGFloat = 10
    static let stripSpacing: CGFloat = 14
    /// Room around strip frames for the selection ring.
    static let ringInset: CGFloat = 7
    /// Between deck cells; the cells' own insets add to it.
    static let deckSpacing: CGFloat = 6
    /// Room around the deck for the selection plate's glow.
    static let deckInset: CGFloat = 8
    /// Inside a deck cell: around the header and the thumbnail, and between the two.
    static let cellInset: CGFloat = 10
    static let headerGap: CGFloat = 8

    let style: SwitcherStyle
    /// Tile frames in a flipped (top-left origin) content space.
    let frames: [CGRect]
    let rows: [Range<Int>]
    let contentSize: CGSize
    /// The tallest a thumbnail can be inside a deck cell, or the height of a strip frame.
    let thumbnailHeight: CGFloat
    /// Side of the icon in app-icons and list styles, and of the header icon in deck cells.
    let iconSize: CGFloat
    /// Height of the visible viewport; smaller than `contentSize.height` when the content scrolls.
    let viewportHeight: CGFloat
    /// Deck cells: point size of the title in the header.
    var titleSize: CGFloat = 13
    /// Arabic and Hebrew: the first tile is on the right and the order runs leftwards, rows still top to bottom.
    var isRightToLeft = false

    var needsScrolling: Bool { contentSize.height > viewportHeight + 0.5 }

    /// How many rows of cells fit on the screen at each size. Automatic starts as large and lets the cells shrink as
    /// windows are added.
    static func deckRows(_ size: SwitcherSize) -> CGFloat {
        switch size {
        case .small: return 4
        case .medium: return 3
        case .large, .auto: return 2.4
        }
    }

    /// The fixed size the styles other than the deck use for `auto`.
    static func fixed(_ size: SwitcherSize) -> SwitcherSize { size == .auto ? .medium : size }

    /// The deck cell header's icon side and title size.
    static func header(_ size: SwitcherSize) -> (icon: CGFloat, title: CGFloat) {
        switch size {
        case .small: return (24, 14)
        case .medium: return (28, 15)
        case .large, .auto: return (32, 16)
        }
    }

    /// `rightToLeft`: laid out as for left to right, then mirrored (see `mirrored()`).
    static func compute(aspects: [CGFloat], style: SwitcherStyle, size: SwitcherSize, available: CGSize,
                        rightToLeft: Bool = false) -> TileLayout {
        let layout: TileLayout
        switch style {
        case .deck: layout = size == .auto ? autoDeck(aspects, available) : deck(aspects, header(size), deckRows(size), available)
        case .stage: layout = strip(aspects.count, fixed(size))
        case .appIcons: layout = appIcons(aspects.count, fixed(size), available)
        case .titles: layout = titles(aspects.count, fixed(size), available)
        case .list: layout = list(aspects.count, fixed(size), available)
        }
        return rightToLeft ? layout.mirrored() : layout
    }

    /// The same layout read the other way: every frame reflected across the middle of the content, so each row starts at
    /// its right end. Sizes, rows and the order of the items don't change.
    func mirrored() -> TileLayout {
        TileLayout(style: style, frames: frames.map { $0.mirrored(within: contentSize.width) }, rows: rows, contentSize: contentSize,
                   thumbnailHeight: thumbnailHeight, iconSize: iconSize, viewportHeight: viewportHeight, titleSize: titleSize,
                   isRightToLeft: !isRightToLeft)
    }

    // MARK: - Styles

    /// Up to this many windows always sit side by side on one row.
    static let singleRowLimit = 4

    /// Big cells: a header (icon, title) over the window's thumbnail, every cell the same height and as wide as its
    /// window's shape asks for, within limits that keep titles readable. Up to four windows stay on one row (the cells
    /// shrink to fit if they must); more are spread over balanced rows (no lone cell on the last row), centered. When
    /// there are too many windows the cells shrink, then the deck scrolls.
    private static func deck(_ aspects: [CGFloat], _ header: (icon: CGFloat, title: CGFloat), _ rowsOnScreen: CGFloat,
                             _ available: CGSize) -> TileLayout {
        let (icon, title) = header
        let fixed = 2 * cellInset + icon + headerGap
        // A cell never gets smaller than its header plus a thumbnail worth seeing; past that the deck scrolls.
        let smallestCell = fixed + 48

        func cellHeight(rowsOnScreen: CGFloat) -> CGFloat {
            max(((available.height - deckSpacing * (rowsOnScreen.rounded(.up) - 1)) / rowsOnScreen).rounded(.down), smallestCell)
        }
        /// How wide each cell is: as its window's shape asks, but a wide window takes at most a third of a row (so even
        /// wide windows sit three across) and a narrow one is never narrower than 85% of its thumbnail's height (so its
        /// title stays readable).
        func widths(cellHeight: CGFloat) -> [CGFloat] {
            let thumbnailHeight = cellHeight - fixed
            let widestThumbnail = ((available.width - 2 * deckSpacing) / 3 - 2 * cellInset).rounded(.down)
            let narrowestCell = (thumbnailHeight * 0.85 + 2 * cellInset).rounded()
            return aspects.map { aspect in
                let shape = aspect > 0 ? aspect : 1.6
                return max(min(widestThumbnail, thumbnailHeight * shape) + 2 * cellInset, narrowestCell).rounded()
            }
        }
        func width(of row: Range<Int>, _ widths: [CGFloat]) -> CGFloat {
            row.reduce(CGFloat(0)) { $0 + widths[$1] } + deckSpacing * CGFloat(max(row.count - 1, 0))
        }

        var height = cellHeight(rowsOnScreen: rowsOnScreen)
        var cellWidths = widths(cellHeight: height)
        var rowRanges: [Range<Int>]
        if aspects.count <= singleRowLimit {
            // Side by side: shrink the cells until the row fits.
            let all = 0..<aspects.count
            while width(of: all, cellWidths) > available.width, height > smallestCell {
                height = max((height * 0.95).rounded(.down), smallestCell)
                cellWidths = widths(cellHeight: height)
            }
            if width(of: all, cellWidths) > available.width {
                let squeeze = (available.width - deckSpacing * CGFloat(max(aspects.count - 1, 0))) / max(width(of: all, cellWidths) - deckSpacing * CGFloat(max(aspects.count - 1, 0)), 1)
                cellWidths = cellWidths.map { max(($0 * squeeze).rounded(.down), 1) }
            }
            rowRanges = aspects.isEmpty ? [] : [all]
        } else {
            var rows = rowsOnScreen
            while true {
                rowRanges = balancedRows(cellWidths, maxWidth: available.width, spacing: deckSpacing)
                let contentHeight = CGFloat(rowRanges.count) * (height + deckSpacing) - deckSpacing
                if contentHeight <= available.height || rows >= 7 || height <= smallestCell { break }
                rows += 1
                height = cellHeight(rowsOnScreen: rows)
                cellWidths = widths(cellHeight: height)
            }
        }

        let contentWidth = rowRanges.map { width(of: $0, cellWidths) }.max() ?? 0
        let contentHeight = rowRanges.isEmpty ? 0 : CGFloat(rowRanges.count) * (height + deckSpacing) - deckSpacing
        var frames = Array(repeating: CGRect.zero, count: cellWidths.count)
        for (rowIndex, row) in rowRanges.enumerated() {
            var x = ((contentWidth - width(of: row, cellWidths)) / 2).rounded()
            let y = CGFloat(rowIndex) * (height + deckSpacing)
            for index in row {
                frames[index] = CGRect(x: x, y: y, width: cellWidths[index], height: height)
                x += cellWidths[index] + deckSpacing
            }
        }
        // When scrolling, show whole rows only.
        var viewport = contentHeight
        if contentHeight > available.height {
            let visible = max(1, Int((available.height + deckSpacing) / (height + deckSpacing)))
            viewport = CGFloat(visible) * (height + deckSpacing) - deckSpacing
        }
        return TileLayout(style: .deck, frames: frames, rows: rowRanges, contentSize: CGSize(width: contentWidth, height: contentHeight),
                          thumbnailHeight: height - fixed, iconSize: icon, viewportHeight: viewport, titleSize: title)
    }

    /// Automatic size: cells as big as the large size for a few windows, shrinking as more are added until every one
    /// fits on screen (only past the smallest readable cell does the deck scroll). The header follows the cells down.
    private static func autoDeck(_ aspects: [CGFloat], _ available: CGSize) -> TileLayout {
        let large = deck(aspects, header(.large), deckRows(.large), available)
        guard let cell = large.frames.first?.height else { return large }
        // Rows of this height that would fill the screen: past three the cells are medium sized, past four small.
        let rowsOnScreen = (available.height + deckSpacing) / (cell + deckSpacing)
        let size: SwitcherSize = rowsOnScreen > 3.6 ? .small : (rowsOnScreen > 2.8 ? .medium : .large)
        return size == .large ? large : deck(aspects, header(size), deckRows(.large), available)
    }

    /// Splits `widths` into as few rows as fit `maxWidth`, keeping the order, with rows as even as possible (the
    /// widest row as narrow as it can be). Among equally good splits the earlier rows take more.
    static func balancedRows(_ widths: [CGFloat], maxWidth: CGFloat, spacing: CGFloat) -> [Range<Int>] {
        let count = widths.count
        guard count > 0 else { return [] }
        var prefix = [CGFloat](repeating: 0, count: count + 1)
        for (index, width) in widths.enumerated() { prefix[index + 1] = prefix[index] + width }
        func rowWidth(_ start: Int, _ end: Int) -> CGFloat { prefix[end] - prefix[start] + spacing * CGFloat(end - start - 1) }
        let lowerBound = min(count, max(1, Int(((prefix[count] + spacing * CGFloat(count - 1)) / max(maxWidth, 1)).rounded(.up))))
        var fallback: [Range<Int>] = []
        for rowCount in lowerBound...count {
            // best[m][j]: the narrowest possible widest row when the first j cards go into m rows.
            var best = [[CGFloat]](repeating: [CGFloat](repeating: .infinity, count: count + 1), count: rowCount + 1)
            var split = [[Int]](repeating: [Int](repeating: 0, count: count + 1), count: rowCount + 1)
            best[0][0] = 0
            for m in 1...rowCount {
                for j in m...count {
                    for i in (m - 1)..<j where best[m - 1][i] < .infinity {
                        let candidate = max(best[m - 1][i], rowWidth(i, j))
                        // `<=`: the last row starts as late as possible, so earlier rows take more.
                        if candidate <= best[m][j] {
                            best[m][j] = candidate
                            split[m][j] = i
                        }
                    }
                }
            }
            var rows = [Range<Int>]()
            var end = count
            for m in stride(from: rowCount, through: 1, by: -1) {
                let start = split[m][end]
                rows.insert(start..<end, at: 0)
                end = start
            }
            if best[rowCount][count] <= maxWidth + 0.5 { return rows }
            fallback = rows
        }
        return fallback
    }

    static func stripItemSize(_ size: SwitcherSize) -> CGSize {
        switch size {
        case .small: return CGSize(width: 104, height: 66)
        case .medium, .auto: return CGSize(width: 128, height: 80)
        case .large: return CGSize(width: 156, height: 98)
        }
    }

    /// One row of equal frames: the filmstrip under the stage. It scrolls sideways instead of wrapping.
    private static func strip(_ count: Int, _ size: SwitcherSize) -> TileLayout {
        let item = stripItemSize(size)
        let frames = (0..<count).map { CGRect(x: CGFloat($0) * (item.width + stripSpacing), y: 0, width: item.width, height: item.height) }
        let width = count == 0 ? 0 : CGFloat(count) * (item.width + stripSpacing) - stripSpacing
        return TileLayout(style: .stage, frames: frames, rows: count == 0 ? [] : [0..<count],
                          contentSize: CGSize(width: width, height: item.height), thumbnailHeight: item.height, iconSize: 22,
                          viewportHeight: item.height)
    }

    private static func appIcons(_ count: Int, _ size: SwitcherSize, _ available: CGSize) -> TileLayout {
        let icon: CGFloat
        switch size {
        case .small: icon = 60
        case .medium, .auto: icon = 80
        case .large: icon = 104
        }
        let width = icon + 44
        let height = 12 + icon + 8 + 30 + 8
        let widths = Array(repeating: width, count: count)
        let rows = wrap(widths, maxWidth: available.width)
        return place(rows: rows, widths: widths, tileHeight: height, style: .appIcons, thumbnailHeight: 0, iconSize: icon, available: available)
    }

    /// The titles style: one compact row per window, as wide as `available`, scrolling past the screen's height.
    private static func titles(_ count: Int, _ size: SwitcherSize, _ available: CGSize) -> TileLayout {
        let (rowHeight, icon, title): (CGFloat, CGFloat, CGFloat)
        switch size {
        case .small: (rowHeight, icon, title) = (30, 18, 13)
        case .large: (rowHeight, icon, title) = (40, 26, 15)
        case .medium, .auto: (rowHeight, icon, title) = (34, 22, 14)
        }
        let width = available.width.rounded()
        let frames = (0..<count).map { CGRect(x: 0, y: CGFloat($0) * (rowHeight + 2), width: width, height: rowHeight) }
        let contentHeight = count == 0 ? 0 : CGFloat(count) * (rowHeight + 2) - 2
        // When scrolling, show whole rows only.
        var viewport = contentHeight
        if contentHeight > available.height {
            let visible = max(1, Int((available.height + 2) / (rowHeight + 2)))
            viewport = CGFloat(visible) * (rowHeight + 2) - 2
        }
        return TileLayout(style: .titles, frames: frames, rows: (0..<count).map { $0..<($0 + 1) },
                          contentSize: CGSize(width: width, height: contentHeight), thumbnailHeight: 0, iconSize: icon,
                          viewportHeight: viewport, titleSize: title)
    }

    private static func list(_ count: Int, _ size: SwitcherSize, _ available: CGSize) -> TileLayout {
        let rowHeight: CGFloat
        let icon: CGFloat
        switch size {
        case .small: rowHeight = 36; icon = 22
        case .medium, .auto: rowHeight = 44; icon = 28
        case .large: rowHeight = 54; icon = 36
        }
        let width = min(available.width, min(max(available.width * 0.48, 560), 780)).rounded()
        var frames = [CGRect]()
        var rows = [Range<Int>]()
        for index in 0..<count {
            frames.append(CGRect(x: 0, y: CGFloat(index) * (rowHeight + 2), width: width, height: rowHeight))
            rows.append(index..<(index + 1))
        }
        let contentHeight = count == 0 ? 0 : CGFloat(count) * (rowHeight + 2) - 2
        return TileLayout(style: .list, frames: frames, rows: rows, contentSize: CGSize(width: width, height: contentHeight),
                          thumbnailHeight: 0, iconSize: icon, viewportHeight: min(contentHeight, available.height))
    }

    // MARK: - Helpers

    static func wrap(_ widths: [CGFloat], maxWidth: CGFloat) -> [Range<Int>] {
        var rows = [Range<Int>]()
        var start = 0
        var rowWidth: CGFloat = 0
        for (index, width) in widths.enumerated() {
            let needed = rowWidth == 0 ? width : rowWidth + spacing + width
            if needed > maxWidth, index > start {
                rows.append(start..<index)
                start = index
                rowWidth = width
            } else {
                rowWidth = needed
            }
        }
        if start < widths.count { rows.append(start..<widths.count) }
        return rows
    }

    private static func place(rows: [Range<Int>], widths: [CGFloat], tileHeight: CGFloat, style: SwitcherStyle,
                              thumbnailHeight: CGFloat, iconSize: CGFloat, available: CGSize) -> TileLayout {
        let rowWidths = rows.map { row in row.reduce(CGFloat(0)) { $0 + widths[$1] } + spacing * CGFloat(max(row.count - 1, 0)) }
        let contentWidth = rowWidths.max() ?? 0
        var frames = Array(repeating: CGRect.zero, count: widths.count)
        for (rowIndex, row) in rows.enumerated() {
            var x = ((contentWidth - rowWidths[rowIndex]) / 2).rounded()
            let y = CGFloat(rowIndex) * (tileHeight + spacing)
            for index in row {
                frames[index] = CGRect(x: x, y: y, width: widths[index], height: tileHeight)
                x += widths[index] + spacing
            }
        }
        let contentHeight = rows.isEmpty ? 0 : CGFloat(rows.count) * (tileHeight + spacing) - spacing
        // When scrolling, show whole rows only.
        var viewport = contentHeight
        if contentHeight > available.height {
            let visibleRows = max(1, Int((available.height + spacing) / (tileHeight + spacing)))
            viewport = CGFloat(visibleRows) * (tileHeight + spacing) - spacing
        }
        return TileLayout(style: style, frames: frames, rows: rows, contentSize: CGSize(width: contentWidth, height: contentHeight),
                          thumbnailHeight: thumbnailHeight, iconSize: iconSize, viewportHeight: viewport)
    }

    func row(of index: Int) -> Int? {
        rows.firstIndex { $0.contains(index) }
    }

    /// Where an arrow key moves the selection. Wraps around at the edges.
    ///
    /// Left and right go by the order the tiles read in: towards the end of the list is rightwards, or leftwards when the
    /// layout reads right to left. Past the end of a row that is the next row's first tile, at its other side, as a text
    /// cursor moves. Up and down pick the nearest tile by position, which mirroring keeps.
    func target(from index: Int, _ move: Move) -> Int {
        let count = frames.count
        guard count > 0 else { return 0 }
        guard index >= 0, index < count else { return 0 }
        switch move {
        case .left, .right:
            let forward = (move == .right) != isRightToLeft
            return forward ? (index + 1) % count : (index - 1 + count) % count
        case .up, .down:
            guard let row = row(of: index), rows.count > 1 else {
                return move == .up ? (index - 1 + count) % count : (index + 1) % count
            }
            let targetRow = move == .up ? (row - 1 + rows.count) % rows.count : (row + 1) % rows.count
            let x = frames[index].midX
            return rows[targetRow].min { abs(frames[$0].midX - x) < abs(frames[$1].midX - x) } ?? index
        }
    }
}

extension CGRect {
    /// This rect reflected across the middle of a box `width` wide that starts at x = 0: where it goes when the box is
    /// laid out right to left. Reflecting twice gives the rect back.
    func mirrored(within width: CGFloat) -> CGRect {
        CGRect(x: width - maxX, y: minY, width: self.width, height: height)
    }
}
