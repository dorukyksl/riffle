import Cocoa

/// What a window's label says: its title, its app's name, or both.
enum TitleContent: String, Codable, CaseIterable {
    case windowTitle, appName, appAndWindowTitle
}

/// Where a label too long for its room is cut short.
enum TitleTruncation: String, Codable, CaseIterable {
    case end, middle, start

    var lineBreakMode: NSLineBreakMode {
        switch self {
        case .end: return .byTruncatingTail
        case .middle: return .byTruncatingMiddle
        case .start: return .byTruncatingHead
        }
    }
}

/// The words on a switcher row, as the Appearance settings ask for them: the label every layout shows, the line under
/// it in the list and on the stage, and what VoiceOver reads.
enum TitleFormat {
    /// Text, and the characters of it a search matched.
    struct Label: Equatable {
        let text: String
        let matches: [Int]
    }

    /// Between the app's name and the window's title.
    static let separator = " — "

    /// The row's label. A window without a title, or an app without windows, goes by the app's name whatever the setting.
    static func title(of item: SwitcherItem, showing content: TitleContent = Prefs.shared.titleContent) -> Label {
        guard !item.title.isEmpty else { return Label(text: item.appName, matches: item.appNameMatches) }
        switch content {
        case .windowTitle:
            return Label(text: item.title, matches: item.titleMatches)
        case .appName:
            return Label(text: item.appName, matches: item.appNameMatches)
        case .appAndWindowTitle:
            // Matches count characters: the title's move along by the name and the separator before it.
            let shift = item.appName.count + separator.count
            return Label(text: item.appName + separator + item.title, matches: item.appNameMatches + item.titleMatches.map { $0 + shift })
        }
    }

    /// The list row's second line: whichever of the app's name and the window's title the label leaves out, or that an app
    /// has no windows. Nil when the label already says it all.
    static func listDetail(of item: SwitcherItem, showing content: TitleContent = Prefs.shared.titleContent) -> Label? {
        if item.isWindowless { return Label(text: L.t("Açık pencere yok", "No open windows"), matches: []) }
        guard !item.title.isEmpty else { return nil }
        switch content {
        case .windowTitle: return Label(text: item.appName, matches: item.appNameMatches)
        case .appName: return Label(text: item.title, matches: item.titleMatches)
        case .appAndWindowTitle: return nil
        }
    }

    /// The stage's line under its title: the app's name under a window title, the window's title under an app name.
    /// Nil when the title already says both.
    static func stageDetail(of item: SwitcherItem, showing content: TitleContent = Prefs.shared.titleContent) -> Label? {
        switch content {
        case .windowTitle: return Label(text: item.appName, matches: item.title.isEmpty ? [] : item.appNameMatches)
        case .appName: return item.title.isEmpty ? nil : Label(text: item.title, matches: item.titleMatches)
        case .appAndWindowTitle: return nil
        }
    }

    /// What VoiceOver reads for a row: its label first, as the card shows it, then what the label leaves out (the app's
    /// name or the window's title), then its state ("Inbox, Mail, minimized, Dock badge: 3").
    static func spokenDescription(of item: SwitcherItem, showing content: TitleContent = Prefs.shared.titleContent,
                                  dockBadge: String? = nil) -> String {
        var parts: [String]
        if item.title.isEmpty {
            parts = item.isWindowless ? [item.appName, L.t("Açık pencere yok", "No open windows")] : [item.appName]
        } else {
            parts = content == .windowTitle ? [item.title, item.appName] : [item.appName, item.title]
        }
        if item.isMinimized { parts.append(L.t("Küçültülmüş", "Minimized")) }
        if item.isHidden { parts.append(L.t("Gizli", "Hidden")) }
        if item.isFullscreen { parts.append(L.t("Tam ekran", "Full screen")) }
        if let space = item.otherSpaceIndex { parts.append(L.f("%1$@. masaüstünde", "On desktop %1$@", space)) }
        if let dockBadge, !dockBadge.isEmpty { parts.append(L.f("Dock rozeti: %1$@", "Dock badge: %1$@", dockBadge)) }
        return parts.joined(separator: ", ")
    }
}
