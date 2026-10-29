import Cocoa
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// The choice made in Riffle (the welcome window or Settings), and the copy of the app it was made for: macOS drops
    /// the login item of an app that's moved or reinstalled, and Riffle makes it again at its next launch.
    private static let wantedKey = "launchAtLoginWanted"
    private static let copyKey = "launchAtLoginCopy"

    enum LaunchCheck: Equatable {
        case nothing
        /// On: it's wanted, for this copy of the app.
        case remember
        /// Wanted, but macOS lost it when the app moved or was reinstalled: make it again.
        case restore
        /// Gone while the app stayed the same copy in the same place: taken off in System Settings, a choice too.
        case forget
    }

    /// What a launch does about the login item, from what macOS has and what was last chosen (`thisCopy` and
    /// `wantedCopy` are `LoginItem.thisCopy` now and when it was chosen).
    static func launchCheck(status: SMAppService.Status, wanted: Bool, wantedFor wantedCopy: String?, thisCopy: String) -> LaunchCheck {
        switch status {
        case .enabled:
            return .remember
        case .notRegistered, .notFound:
            guard wanted else { return .nothing }
            return wantedCopy == thisCopy ? .forget : .restore
        default:
            // Waiting for approval in System Settings: asked once, when it was chosen, never again at every launch.
            return .nothing
        }
    }

    /// This copy of the app: where it is, and its folder's number on disk, which a reinstall in the same place changes.
    static var thisCopy: String {
        let path = Bundle.main.bundlePath
        let number = (try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? UInt64
        return path + "#" + (number.map(String.init) ?? "?")
    }

    /// Keeps "launch at login" as it was chosen; see `launchCheck`.
    static func restoreIfWanted(in store: UserDefaults = .standard) {
        let copy = thisCopy
        let chosen = wish(in: store)
        switch launchCheck(status: SMAppService.mainApp.status, wanted: chosen.wanted, wantedFor: chosen.copy, thisCopy: copy) {
        case .nothing:
            return
        case .remember:
            remember(true, for: copy, in: store)
        case .restore:
            do {
                try SMAppService.mainApp.register()
                Log.info("login item made again: the app was moved or reinstalled")
            } catch {
                Log.warn("login item: \(error.localizedDescription)")
            }
            remember(true, for: copy, in: store)
        case .forget:
            Log.info("login item was turned off outside Riffle")
            remember(false, for: copy, in: store)
        }
    }

    /// What `restoreIfWanted` goes by.
    static func remember(_ wanted: Bool, for copy: String, in store: UserDefaults) {
        store.set(wanted, forKey: wantedKey)
        store.set(copy, forKey: copyKey)
    }

    static func wish(in store: UserDefaults) -> (wanted: Bool, copy: String?) {
        (store.bool(forKey: wantedKey), store.string(forKey: copyKey))
    }

    /// Switched in the welcome window or in Settings: the choice is kept, whatever macOS makes of it.
    static func set(_ enabled: Bool) {
        remember(enabled, for: thisCopy, in: .standard)
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.warn("login item: \(error.localizedDescription)")
        }
        if enabled && needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

/// Which shortcuts failed to register (another app owns them). Shown in Settings.
final class ShortcutStatus: ObservableObject {
    static let shared = ShortcutStatus()
    @Published var failures = [Int: OSStatus]()
    /// Shortcuts whose keys another (earlier) Riffle shortcut already has: they don't work.
    @Published var duplicates = Set<Int>()
}
