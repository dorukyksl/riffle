import AppKit
import Combine
import Sparkle

/// Riffle's updates, by Sparkle. Once a day (unless it's turned off in Settings → About) Riffle reads
/// https://appriffle.com/updates/appcast.xml, and a newer version, signed with Riffle's update key and its Developer ID,
/// is offered, never installed without asking. Riffle has no window of its own, so an update found while someone is busy
/// waits in the menu bar menu instead of opening a window over their work; one found just after launch or after the Mac
/// sat idle, or asked for with Check for Updates…, shows Sparkle's window. A build without a feed in its Info.plist
/// (`swift run`, the tests) never starts the updater, so it never reaches the server.
final class Updates: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    static let shared = Updates()

    /// Check for Updates… can run (not while a check or an installation is under way).
    @Published private(set) var canCheck = false
    @Published private(set) var checksAutomatically = false
    /// The version a check in the background found, offered by the menu bar menu until it gets looked at.
    @Published private(set) var waiting: String?

    private var controller: SPUStandardUpdaterController?

    /// This copy has a feed to check: release builds do.
    var isAvailable: Bool { controller != nil }

    func start() {
        guard controller == nil else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        guard let feed = info["SUFeedURL"] as? String, !feed.isEmpty, let key = info["SUPublicEDKey"] as? String, !key.isEmpty else {
            Log.info("updates: off, this build has no update feed")
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$checksAutomatically)
    }

    /// Looks now, or brings an update found earlier to the front.
    func check() {
        guard let controller else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    func setChecksAutomatically(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
    }

    // MARK: - SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle's window when it would come up in focus anyway (just after launch, or after the Mac sat idle); otherwise the
    /// menu bar menu offers it. With the menu bar icon hidden there's no menu to offer it in, so Sparkle shows it.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus || !Prefs.shared.showMenuBarIcon
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        Log.info("updates: Riffle \(update.displayVersionString) is out, offered in the menu bar menu")
        waiting = update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        waiting = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        waiting = nil
    }
}

enum UpdateText {
    /// The menu bar menu's item and the button in Settings → About.
    static var check: String { L.t("Güncellemeleri Denetle…", "Check for Updates…") }
}

/// Where questions and problems go: help@appriffle.com, forwarded by Cloudflare's Email Routing.
enum Support {
    static let address = "help@appriffle.com"

    /// A new mail to it whose subject says which Riffle and which macOS it's about.
    static var mailURL: URL? {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        var mail = URLComponents()
        mail.scheme = "mailto"
        mail.path = address
        mail.queryItems = [URLQueryItem(name: "subject", value: "Riffle \(AppInfo.version) (\(AppInfo.build)), macOS "
                                        + "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")]
        return mail.url
    }
}
