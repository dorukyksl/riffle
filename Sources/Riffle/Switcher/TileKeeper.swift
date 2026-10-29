import CoreGraphics

/// What every tile of one build shares and bakes into itself when it's made (fonts, icon sizes, colors, strings).
struct TileLook: Equatable {
    var style: SwitcherStyle
    var iconSize: CGFloat
    var titleSize: CGFloat
    /// Pixels per point the icons are drawn for.
    var scale: CGFloat
    /// The panel's appearance, by name: layer colors are resolved for it when the tile is made.
    var appearance: String
    var language: AppLanguage
    var showBadges: Bool
    var showSpaceNumbers: Bool
    var titleContent: TitleContent
    var titleTruncation: TitleTruncation
}

/// Everything a tile is made from except its title text, its number and its place: a kept tile is reused for an item only
/// when both give the same blueprint. A different title or new search matches only relabel it; another state (minimized,
/// hidden, full screen, another desktop) or another look means a new tile.
struct TileBlueprint: Equatable {
    let look: TileLook
    let id: String
    let pid: pid_t
    let bundleID: String?
    let isMinimized: Bool
    let isHidden: Bool
    let isFullscreen: Bool
    let otherSpaceIndex: Int?

    init(_ item: SwitcherItem, look: TileLook) {
        self.look = look
        id = item.id
        pid = item.pid
        bundleID = item.bundleID
        isMinimized = item.isMinimized
        isHidden = item.isHidden
        isFullscreen = item.isFullscreen
        otherSpaceIndex = item.otherSpaceIndex
    }
}

/// Tiles kept from one build to the next, one per item, so that summoning the switcher again, a reload and every search
/// keystroke move and relabel the tiles already made instead of making them again. Generic over the tile so its
/// bookkeeping can be tested without views.
final class TileKeeper<Tile: AnyObject> {
    private struct Entry {
        let tile: Tile
        let blueprint: TileBlueprint
        var lastUsed: Int
    }

    private var entries = [String: Entry]()
    private var build = 0

    var count: Int { entries.count }

    /// Starts a build: from now on `take` hands each tile out once.
    func beginBuild() {
        build += 1
    }

    /// The kept tile for the blueprint's item, if it was made from the same blueprint and this build hasn't taken it yet.
    func take(_ blueprint: TileBlueprint) -> Tile? {
        guard var entry = entries[blueprint.id], entry.blueprint == blueprint, entry.lastUsed != build else { return nil }
        entry.lastUsed = build
        entries[blueprint.id] = entry
        return entry.tile
    }

    /// Whether `tile` is the one kept for the blueprint's item and was made from that blueprint.
    func holds(_ tile: Tile, for blueprint: TileBlueprint) -> Bool {
        guard let entry = entries[blueprint.id] else { return false }
        return entry.tile === tile && entry.blueprint == blueprint
    }

    /// Keeps a newly made tile for its item, in place of any older one, as used by this build.
    func keep(_ tile: Tile, for blueprint: TileBlueprint) {
        entries[blueprint.id] = Entry(tile: tile, blueprint: blueprint, lastUsed: build)
    }

    /// Forgets `tile`: a card that faded out with its window is never shown again.
    func discard(_ tile: Tile) {
        for (id, entry) in entries where entry.tile === tile { entries[id] = nil }
    }

    /// Lets go of the tiles used longest ago until at most `limit` are kept (never one this build uses), and returns them.
    @discardableResult
    func trim(to limit: Int) -> [Tile] {
        guard entries.count > limit else { return [] }
        let oldest = entries.filter { $0.value.lastUsed != build }.sorted { $0.value.lastUsed < $1.value.lastUsed }
        var released = [Tile]()
        for (id, entry) in oldest.prefix(entries.count - limit) {
            entries[id] = nil
            released.append(entry.tile)
        }
        return released
    }
}
