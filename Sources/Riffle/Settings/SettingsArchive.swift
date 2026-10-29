import Foundation

/// A settings file: every setting of `SettingsSnapshot`, with the format's version and the Riffle that wrote it.
///
///     {"format": "riffle-settings", "formatVersion": 1, "appVersion": "1.4 (52)", "exportedAt": "…", "settings": {…}}
///
/// Reading is strict: a file that isn't complete, or has a value that can't be read, or comes from a newer format, is
/// refused as a whole, so an import changes everything or nothing.
struct SettingsArchive: Equatable {
    static let format = "riffle-settings"
    static let currentFormatVersion = 1
    /// Backups made before a reset or an import are named after it ("settings-<date>.json").
    static let backupName = "settings"

    var settings: SettingsSnapshot
    var formatVersion = SettingsArchive.currentFormatVersion
    /// "1.4 (52)": the Riffle that wrote it.
    var appVersion: String
    var exportedAt: Date?

    init(settings: SettingsSnapshot, appVersion: String = SettingsArchive.thisAppVersion, exportedAt: Date? = Date()) {
        self.settings = settings
        self.appVersion = appVersion
        self.exportedAt = exportedAt
    }

    static var thisAppVersion: String { "\(AppInfo.version) (\(AppInfo.build))" }

    enum Problem: Error, Equatable {
        /// The file itself couldn't be read (or is far too big to be settings).
        case unreadableFile
        /// Not JSON at all: damaged, or some other kind of file.
        case notJSON
        /// JSON, but not Riffle's settings.
        case notSettings
        /// Written by a newer Riffle in a format this one doesn't know.
        case newerFormat(appVersion: String?)
        /// Settings missing from it.
        case incomplete([SettingsKey])
        /// A value that can't be read; nil when it's the file's own description.
        case damaged(SettingsKey?)
        /// A shortcut with no ⌃, ⌥ or ⌘ to hold: its key would switch windows in every app instead of typing.
        case shortcutWithoutHold
    }

    /// Settings files are a few kilobytes; anything far bigger isn't one.
    static let sizeLimit = 2_000_000

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(File(format: SettingsArchive.format, formatVersion: formatVersion, appVersion: appVersion,
                                       exportedAt: exportedAt, settings: settings))
    }

    private struct File: Encodable {
        let format: String
        let formatVersion: Int
        let appVersion: String
        let exportedAt: Date?
        let settings: SettingsSnapshot
    }

    static func read(_ data: Data) -> Result<SettingsArchive, Problem> {
        guard data.count <= sizeLimit else { return .failure(.unreadableFile) }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return .failure(.notJSON) }
        guard let file = object as? [String: Any], file["format"] as? String == format else { return .failure(.notSettings) }
        guard let version = file["formatVersion"] as? Int, version >= 1 else { return .failure(.damaged(nil)) }
        guard version <= currentFormatVersion else { return .failure(.newerFormat(appVersion: file["appVersion"] as? String)) }
        guard let values = file["settings"] as? [String: Any] else { return .failure(.incomplete(SettingsKey.allCases)) }
        let missing = SettingsKey.allCases.filter { values[$0.rawValue] == nil }
        guard missing.isEmpty else { return .failure(.incomplete(missing)) }
        // Said as such rather than "damaged": the one value that would quietly take a key from every app.
        if let json = SettingsSnapshot.jsonData(values[SettingsKey.profiles.rawValue]),
           ShortcutProfile.decodeList(from: json)?.contains(where: { $0.holdModifiers.intersection(.holdable).isEmpty }) == true {
            return .failure(.shortcutWithoutHold)
        }
        // Every value read in full, over a starting point whose own values never show through.
        var settings = SettingsSnapshot.defaults(language: .en, profiles: [])
        for key in SettingsKey.allCases {
            guard let json = SettingsSnapshot.jsonData(values[key.rawValue]), settings.read(key, from: json) == .read else {
                return .failure(.damaged(key))
            }
        }
        // Shortcuts exactly as Riffle keeps them: at least one, at most nine, each with an id of its own.
        guard Prefs.sanitized(settings.profiles) == settings.profiles else { return .failure(.damaged(.profiles)) }
        var archive = SettingsArchive(settings: settings, appVersion: file["appVersion"] as? String ?? "?", exportedAt: nil)
        archive.formatVersion = version
        archive.exportedAt = (file["exportedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return .success(archive)
    }

    static func read(contentsOf url: URL) -> Result<SettingsArchive, Problem> {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= sizeLimit,
              let data = try? Data(contentsOf: url) else { return .failure(.unreadableFile) }
        return read(data)
    }
}

/// What an import would change, grouped the way Settings is.
enum SettingsChange: Equatable {
    case shortcuts(from: Int, to: Int)
    case exceptions(from: Int, to: Int)
    case panelKeys
    case appearance
    case general
    case language(from: AppLanguage, to: AppLanguage)
}

extension SettingsSnapshot {
    /// What would change if `new` replaced these settings, in the order Settings shows them.
    func changes(to new: SettingsSnapshot) -> [SettingsChange] {
        var changes = [SettingsChange]()
        if new.language != language { changes.append(.language(from: language, to: new.language)) }
        if new.showDelayMs != showDelayMs || new.screen != screen || new.mouseHoverSelects != mouseHoverSelects
            || new.hapticFeedback != hapticFeedback || new.showMenuBarIcon != showMenuBarIcon {
            changes.append(.general)
        }
        if new.profiles != profiles { changes.append(.shortcuts(from: profiles.count, to: new.profiles.count)) }
        if new.panelKeys != panelKeys { changes.append(.panelKeys) }
        if new.style != style || new.size != size || new.theme != theme || new.glass != glass || new.showBadges != showBadges
            || new.showSpaceNumbers != showSpaceNumbers || new.previewSelectedWindow != previewSelectedWindow
            || new.titleContent != titleContent || new.titleTruncation != titleTruncation || new.panelAnimations != panelAnimations
            || new.pointerFollowsSwitch != pointerFollowsSwitch {
            changes.append(.appearance)
        }
        // A rule's id only tells rules apart on one Mac: the same rules from another one change nothing.
        if !SettingsSnapshot.sameRules(appExceptions, new.appExceptions) {
            changes.append(.exceptions(from: appExceptions.count, to: new.appExceptions.count))
        }
        return changes
    }

    private static func sameRules(_ a: [AppException], _ b: [AppException]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { first, second in
            var first = first
            first.id = second.id
            return first == second
        }
    }
}
