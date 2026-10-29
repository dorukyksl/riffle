import Foundation

/// Brings stored settings up to date, one numbered step at a time. A step is a pure function of the stored values as
/// UserDefaults holds them (JSON data for settings, plain values for flags), so it can be tried on a copy of anyone's
/// settings. `settingsVersion` records the last step applied: each step runs once, and settings written by a newer Riffle
/// are left alone.
///
/// The first four steps are the ones every launch used to run, each behind a flag of its own. They still check their
/// flags, so settings that went through one before versions existed aren't changed again. The move from one `scope` and
/// three switches to a shortcut's own fields isn't a step: `ShortcutProfile`'s decoding reads both shapes.
enum SettingsMigration {
    typealias Stored = [String: Any]

    struct Step {
        let version: Int
        let apply: (inout Stored, Context) -> Void
    }

    struct Context {
        /// A new setup's shortcuts (they follow the Mac's Modifier Keys settings).
        var defaultProfiles: [ShortcutProfile]
    }

    static let versionKey = "settingsVersion"

    static let steps: [Step] = [
        Step(version: 1, apply: adoptDeck),
        Step(version: 2, apply: offerSearchShortcut),
        Step(version: 3, apply: keepTurkishForOlderSetups),
        Step(version: 4, apply: moveExcludedAppsToExceptions),
    ]

    static var latest: Int { steps.last?.version ?? 0 }

    /// `stored` after every step it hasn't had yet, in order, with `settingsVersion` set to the latest.
    static func migrate(_ stored: Stored, context: Context) -> Stored {
        let from = stored[versionKey] as? Int ?? 0
        guard from < latest else { return stored }
        var result = stored
        for step in steps where step.version > from { step.apply(&result, context) }
        result[versionKey] = latest
        return result
    }

    // MARK: - Steps

    /// The deck replaced the stage as the default look: everyone moves over once, and can still pick the stage.
    static func adoptDeck(_ stored: inout Stored, _ context: Context) {
        guard !flag("didAdoptDeckStyle", in: stored) else { return }
        stored["didAdoptDeckStyle"] = true
        stored["didAdoptStageStyle"] = nil
        stored[SettingsKey.style.rawValue] = encoded(SwitcherStyle.deck)
    }

    /// Shortcuts can be added and removed: settings from before the search shortcut existed get it once, and never again
    /// (it may have been removed on purpose since).
    static func offerSearchShortcut(_ stored: inout Stored, _ context: Context) {
        guard !flag("didOfferSearchShortcut", in: stored) else { return }
        stored["didOfferSearchShortcut"] = true
        // No list, or none that reads, means the defaults: they have it already.
        guard let data = SettingsSnapshot.jsonData(stored[SettingsKey.profiles.rawValue]),
              let profiles = ShortcutProfile.decodeList(from: data), profiles.count < context.defaultProfiles.count else { return }
        stored[SettingsKey.profiles.rawValue] = encoded(profiles + context.defaultProfiles.dropFirst(profiles.count))
    }

    /// Before there were 21 languages Riffle was Turkish unless told otherwise: a setup from then keeps its language. New
    /// setups start in the Mac's own language (once versions are recorded, finishing the welcome window later doesn't
    /// make a new setup look old).
    static func keepTurkishForOlderSetups(_ stored: inout Stored, _ context: Context) {
        guard stored[SettingsKey.language.rawValue] == nil, stored["hasCompletedOnboarding"] != nil else { return }
        stored[SettingsKey.language.rawValue] = encoded(AppLanguage.tr)
    }

    /// Settings from before exceptions bring their hidden apps along, still hidden.
    static func moveExcludedAppsToExceptions(_ stored: inout Stored, _ context: Context) {
        guard stored[SettingsKey.appExceptions.rawValue] == nil, let ids = excludedBundleIDs(in: stored) else { return }
        stored[SettingsKey.appExceptions.rawValue] = encoded(AppException.migrated(from: ids))
    }

    // MARK: - Helpers

    /// The hidden apps of versions before exceptions (newer ones still write them, for older ones to read).
    static func excludedBundleIDs(in stored: Stored) -> [String]? {
        SettingsSnapshot.jsonData(stored["excludedBundleIDs"]).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
    }

    /// A flag as `UserDefaults.bool(forKey:)` reads it.
    static func flag(_ key: String, in stored: Stored) -> Bool {
        switch stored[key] {
        case let number as NSNumber: return number.boolValue
        case let text as String: return ["yes", "true", "1"].contains(text.lowercased())
        default: return false
        }
    }

    static func encoded<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
}

/// What a launch makes of the stored settings: the values, the stored values that couldn't be read, and what to write
/// back. Pure, like the migrations it runs.
struct SettingsLoad {
    static let shortcutsPausedKey = "shortcutsPaused"

    /// Every key a launch reads.
    static let keys: [String] = SettingsKey.allCases.map(\.rawValue) + [
        shortcutsPausedKey, "excludedBundleIDs", "didAdoptDeckStyle", "didAdoptStageStyle", "didOfferSearchShortcut",
        "hasCompletedOnboarding", SettingsMigration.versionKey,
    ]

    enum Write {
        case set(Any)
        case remove
    }

    private(set) var settings: SettingsSnapshot
    private(set) var shortcutsPaused = false
    /// Stored values that couldn't be read, in whole or in part, exactly as they were: each must be kept (Recovered)
    /// before anything is written over it.
    private(set) var unreadable = [String: Any]()
    /// What brings the store up to date: the migrations' changes, then each unreadable value cleared (a list keeps the
    /// entries that could be read). A key in `unreadable` may only be written once its value is kept.
    private(set) var writes = [String: Write]()

    init(stored: [String: Any], defaults: SettingsSnapshot) {
        settings = defaults
        // 1. What can't be read, as found (a migration may write over it). A missing value is never one.
        var partly = Set<String>()
        for key in SettingsKey.allCases {
            guard let raw = stored[key.rawValue] else { continue }
            var probe = defaults
            switch SettingsSnapshot.jsonData(raw).map({ probe.read(key, from: $0) }) ?? .unreadable {
            case .read: continue
            case .partly: partly.insert(key.rawValue)
            case .unreadable: break
            }
            unreadable[key.rawValue] = raw
        }
        if let raw = stored[SettingsLoad.shortcutsPausedKey], SettingsLoad.bool(raw) == nil {
            unreadable[SettingsLoad.shortcutsPausedKey] = raw
        }
        // The hidden apps of older versions matter only while there are no exceptions to read instead.
        if stored[SettingsKey.appExceptions.rawValue] == nil, let raw = stored["excludedBundleIDs"],
           SettingsMigration.excludedBundleIDs(in: stored) == nil {
            unreadable["excludedBundleIDs"] = raw
        }

        // 2. Migrations.
        let migrated = SettingsMigration.migrate(stored, context: .init(defaultProfiles: defaults.profiles))

        // 3. Values: whatever can be read, the default for the rest.
        for key in SettingsKey.allCases {
            guard let data = SettingsSnapshot.jsonData(migrated[key.rawValue]) else { continue }
            _ = settings.read(key, from: data)
        }
        // A version from before exceptions may have written its list of hidden apps since the migration ran.
        if migrated[SettingsKey.appExceptions.rawValue] == nil {
            settings.appExceptions = AppException.migrated(from: SettingsMigration.excludedBundleIDs(in: migrated) ?? [])
        }
        settings.profiles = Prefs.sanitized(settings.profiles)
        shortcutsPaused = migrated[SettingsLoad.shortcutsPausedKey].flatMap(SettingsLoad.bool) ?? false

        // 4. Writes.
        for key in Set(stored.keys).union(migrated.keys) where !SettingsLoad.same(stored[key], migrated[key]) {
            writes[key] = migrated[key].map(Write.set) ?? .remove
        }
        for (key, raw) in unreadable where SettingsLoad.same(migrated[key], raw) {
            if partly.contains(key), let settingsKey = SettingsKey(rawValue: key) {
                writes[key] = .set(settings.encoded(settingsKey))
            } else {
                writes[key] = .remove
            }
        }
    }

    private static func bool(_ raw: Any) -> Bool? {
        SettingsSnapshot.jsonData(raw).flatMap { try? JSONDecoder().decode(Bool.self, from: $0) }
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return (a as AnyObject).isEqual(b as AnyObject)
        default: return false
        }
    }
}
