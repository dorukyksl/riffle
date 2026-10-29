import Foundation

/// A rule for one app, or a family of apps (Settings → Exceptions): keep some or all of its windows out of the switcher,
/// and/or leave Riffle's shortcuts to it while it's in front, as a virtual machine or a remote desktop wants.
struct AppException: Codable, Equatable, Identifiable {
    enum Hiding: String, Codable, CaseIterable {
        case nothing
        case allWindows
        /// The app itself, while it has no windows.
        case whenWindowless
        case titleContains
    }

    /// When Riffle lets go of its shortcuts while the app is in front.
    enum ShortcutRule: String, Codable, CaseIterable {
        case never, always, whileFullscreen
    }

    var id = UUID()
    /// A bundle identifier or, with `matchesPrefix`, the start of one in whole parts: "com.microsoft" covers
    /// "com.microsoft.Word" but not "com.microsoftedge".
    var bundleID: String
    var matchesPrefix = false
    /// What to call it when the identifier names no app on this Mac (a prefix, say).
    var name = ""
    var hiding: Hiding = .allWindows
    var titleText = ""
    var ignoresShortcuts: ShortcutRule = .never

    func matches(_ candidate: String?) -> Bool {
        let pattern = AppException.normalized(bundleID)
        guard let candidate = candidate?.lowercased(), !pattern.isEmpty else { return false }
        if candidate == pattern { return true }
        return matchesPrefix && candidate.hasPrefix(pattern + ".")
    }

    /// Lower case, without the spaces, trailing dot or "*" people type when they mean "and everything under it".
    static func normalized(_ identifier: String) -> String {
        var text = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while text.hasSuffix("*") || text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Whether this rule keeps a window with `title` out of the list.
    func hidesWindow(titled title: String) -> Bool {
        switch hiding {
        case .allWindows:
            return true
        case .titleContains:
            let text = AppException.folded(titleText.trimmingCharacters(in: .whitespacesAndNewlines))
            return !text.isEmpty && AppException.folded(title).contains(text)
        case .nothing, .whenWindowless:
            return false
        }
    }

    /// Whether this rule keeps the app out of the list while it has no windows.
    var hidesWindowlessApp: Bool { hiding == .allWindows || hiding == .whenWindowless }

    /// Case, accents and the Turkish dotted and dotless i don't matter when comparing titles.
    private static func folded(_ text: String) -> String {
        text.replacingOccurrences(of: "ı", with: "i")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The strictest "ignore Riffle's shortcuts" of the exceptions that match the app.
    static func shortcutRule(for bundleID: String?, in exceptions: [AppException]) -> ShortcutRule {
        let rules = exceptions.filter { $0.matches(bundleID) }.map(\.ignoresShortcuts)
        if rules.contains(.always) { return .always }
        if rules.contains(.whileFullscreen) { return .whileFullscreen }
        return .never
    }

    static func ignoresShortcuts(_ rule: ShortcutRule, isFullscreen: Bool) -> Bool {
        switch rule {
        case .never: return false
        case .always: return true
        case .whileFullscreen: return isFullscreen
        }
    }

    /// Settings from before exceptions: every app that was hidden stays hidden.
    static func migrated(from excludedBundleIDs: [String]) -> [AppException] {
        var seen = Set<String>()
        return excludedBundleIDs.filter { !normalized($0).isEmpty && seen.insert(normalized($0)).inserted }
            .map { AppException(bundleID: $0) }
    }

    /// Whether `other` is about the same identifier, matched the same way.
    func coversSameApps(as other: AppException) -> Bool {
        matchesPrefix == other.matchesPrefix && AppException.normalized(bundleID) == AppException.normalized(other.bundleID)
    }

    /// `exceptions` with `added` after them. One that's already there isn't added twice: it takes the added one's
    /// shortcut rule if it had none.
    static func adding(_ added: [AppException], to exceptions: [AppException]) -> [AppException] {
        var result = exceptions
        for exception in added {
            if let index = result.firstIndex(where: { $0.coversSameApps(as: exception) }) {
                if result[index].ignoresShortcuts == .never { result[index].ignoresShortcuts = exception.ignoresShortcuts }
            } else {
                result.append(exception)
            }
        }
        return result
    }

    /// A saved list, read rule by rule: a damaged one is dropped, the others stay.
    static func decodeList(from data: Data) -> [AppException]? {
        (try? JSONDecoder().decode([LossyElement<AppException>].self, from: data))?.compactMap(\.value)
    }
}

extension AppException {
    private enum CodingKeys: String, CodingKey {
        case id, bundleID, matchesPrefix, name, hiding, titleText, ignoresShortcuts
    }

    /// Field by field with defaults. A value this version doesn't know never hides anything or takes shortcuts away.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
        }
        self.init(bundleID: value(.bundleID) ?? "")
        id = value(.id) ?? UUID()
        matchesPrefix = value(.matchesPrefix) ?? false
        name = value(.name) ?? ""
        hiding = (value(.hiding) as String?).flatMap(Hiding.init(rawValue:)) ?? .nothing
        titleText = value(.titleText) ?? ""
        ignoresShortcuts = (value(.ignoresShortcuts) as String?).flatMap(ShortcutRule.init(rawValue:)) ?? .never
    }
}

extension AppException {
    /// An app that wants ⌘⇥ and the like for the system inside it. `appIDs` are its actual bundle identifiers, to find
    /// its icon and whether it's on this Mac.
    struct Preset {
        let name: String
        let bundleID: String
        let matchesPrefix: Bool
        let appIDs: [String]

        var exception: AppException {
            AppException(bundleID: bundleID, matchesPrefix: matchesPrefix, name: name, hiding: .nothing, ignoresShortcuts: .whileFullscreen)
        }
    }

    /// Virtual machines and remote desktops: in full screen they get Riffle's shortcuts, ⌘⇥ included.
    static let presets: [Preset] = [
        Preset(name: "Parallels Desktop", bundleID: "com.parallels", matchesPrefix: true, appIDs: ["com.parallels.desktop.console"]),
        Preset(name: "VMware Fusion", bundleID: "com.vmware.fusion", matchesPrefix: true, appIDs: ["com.vmware.fusion"]),
        Preset(name: "VirtualBox", bundleID: "org.virtualbox.app", matchesPrefix: true,
               appIDs: ["org.virtualbox.app.VirtualBox", "org.virtualbox.app.VirtualBoxVM"]),
        Preset(name: "UTM", bundleID: "com.utmapp.UTM", matchesPrefix: false, appIDs: ["com.utmapp.UTM"]),
        // Microsoft's Remote Desktop became Windows App and kept its identifier.
        Preset(name: "Windows App", bundleID: "com.microsoft.rdc", matchesPrefix: true, appIDs: ["com.microsoft.rdc.macos"]),
        Preset(name: "Screen Sharing", bundleID: "com.apple.ScreenSharing", matchesPrefix: false, appIDs: ["com.apple.ScreenSharing"]),
        Preset(name: "Jump Desktop", bundleID: "com.p5sys.jump", matchesPrefix: true,
               appIDs: ["com.p5sys.jump.mac.viewer", "com.p5sys.jump.mac.viewer.web"]),
        Preset(name: "Citrix Workspace", bundleID: "com.citrix", matchesPrefix: true,
               appIDs: ["com.citrix.receiver.nomas", "com.citrix.receiver.icaviewer.mac"]),
        Preset(name: "TeamViewer", bundleID: "com.teamviewer", matchesPrefix: true, appIDs: ["com.teamviewer.TeamViewer"]),
        Preset(name: "AnyDesk", bundleID: "com.philandro.anydesk", matchesPrefix: false, appIDs: ["com.philandro.anydesk"]),
    ]
}
