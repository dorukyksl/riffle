import SwiftUI

/// One row Settings search can find.
struct SettingsSearchEntry: Identifiable, Equatable {
    let section: SettingsSection
    /// Which of several alike rows it is: a shortcut's keys, an exception's app.
    let context: String?
    let label: String
    /// Other words that find it: a picker's choices, the caption under it.
    let keywords: [String]
    /// The row to bring into view (see `settingsAnchor`); nil: the section's top.
    let anchor: String?

    var id: String { [section.rawValue, anchor ?? "", context ?? "", label].joined(separator: "|") }

    /// "Section › Row", or "Section › Context › Row".
    var path: [String] { [section.title] + (context.map { [$0] } ?? []) + [label] }
}

/// The search field of the Settings sidebar: every label of every section, in the language Riffle is in. Words match
/// with case, accents and the Turkish dotted and dotless i folded away (`FuzzySearch.fold`).
enum SettingsSearch {
    /// Results shown at most.
    static let limit = 60

    /// The entries every word of `query` finds. Each word must be in the row's own words (its label or keywords) or in
    /// where it is (its section, a shortcut's keys), and at least one in the row's own: the section and context narrow a
    /// search down but never find rows on their own ("shortcuts order" finds each shortcut's Order; "shortcuts" alone,
    /// the section). Best first, by the word that matched worst: a word starting the label, inside the label, then only
    /// in a keyword.
    static func results(for query: String, in entries: [SettingsSearchEntry]) -> [SettingsSearchEntry] {
        let words = folded(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var found = [(entry: SettingsSearchEntry, rank: Int, order: Int)]()
        for (order, entry) in entries.enumerated() {
            let label = folded(entry.label)
            let keywords = entry.keywords.map(folded)
            let around = folded(entry.path.dropLast().joined(separator: " "))
            var rank = 0
            var inRow = false
            var all = true
            for word in words {
                if startsAWord(word, in: label) {
                    inRow = true
                } else if label.contains(word) {
                    (inRow, rank) = (true, max(rank, 1))
                } else if keywords.contains(where: { $0.contains(word) }) {
                    (inRow, rank) = (true, max(rank, 2))
                } else if !around.contains(word) {
                    all = false
                    break
                }
            }
            if all, inRow { found.append((entry, rank, order)) }
        }
        found.sort { ($0.rank, $0.order) < ($1.rank, $1.order) }
        return found.prefix(limit).map(\.entry)
    }

    /// The sections to list while searching: those whose name matches first, then those with a result.
    static func sections(for query: String, results: [SettingsSearchEntry]) -> [SettingsSection] {
        let words = folded(query).split(separator: " ").map(String.init)
        let named = SettingsSection.allCases.filter { section in
            let title = folded(section.title)
            return !words.isEmpty && words.allSatisfy { title.contains($0) }
        }
        return named + SettingsSection.allCases.filter { section in !named.contains(section) && results.contains { $0.section == section } }
    }

    static func folded(_ text: String) -> String {
        String(FuzzySearch.fold(text))
    }

    private static func startsAWord(_ word: String, in text: String) -> Bool {
        var start = text.startIndex
        while let range = text.range(of: word, range: start..<text.endIndex) {
            if range.lowerBound == text.startIndex { return true }
            let before = text[text.index(before: range.lowerBound)]
            if !before.isLetter && !before.isNumber { return true }
            start = text.index(after: range.lowerBound)
        }
        return false
    }

    // MARK: - The index

    /// Every row of every section for these shortcuts and exceptions, in the language Riffle is in, in the order
    /// Settings shows them. Keep it in step with the sections: a test finds every Settings label in it.
    static func index(profiles: [ShortcutProfile], exceptions: [AppException]) -> [SettingsSearchEntry] {
        var entries = [SettingsSearchEntry]()
        func add(_ section: SettingsSection, _ label: String, _ anchor: String?, context: String? = nil, _ keywords: [String] = []) {
            entries.append(SettingsSearchEntry(section: section, context: context, label: label, keywords: keywords, anchor: anchor))
        }

        // General
        add(.general, L.t("Girişte başlat", "Launch at login"), SettingsAnchor.launchAtLogin)
        add(.general, L.t("Menü çubuğunda göster", "Show in menu bar"), SettingsAnchor.menuBar)
        add(.general, L.t("Dil", "Language"), SettingsAnchor.language, AppLanguage.pickerOrder.map(\.nativeName))
        add(.general, L.t("Davranış", "Behavior"), SettingsAnchor.delay)
        add(.general, L.t("Görünme gecikmesi", "Appearance delay"), SettingsAnchor.delay, [AppearanceDelay.caption(for: Prefs.shared.profiles)])
        add(.general, L.t("Panelin gösterileceği ekran", "Show the switcher on"), SettingsAnchor.screen, [
            L.t("Farenin olduğu ekran", "Screen with the mouse"), L.t("Aktif pencerenin ekranı", "Screen with the active window"),
            L.t("Ana ekran", "Main screen"),
        ])
        add(.general, L.t("Etkileşim", "Interaction"), SettingsAnchor.hover)
        add(.general, L.t("Fareyle üzerine gelince seç", "Select on mouse hover"), SettingsAnchor.hover)
        add(.general, L.t("Seçim değişince hafif dokunsal geri bildirim", "Subtle haptic feedback on selection"), SettingsAnchor.haptics)
        add(.general, L.t("Paneli Şimdi Göster", "Show Switcher Now"), SettingsAnchor.showNow)
        let allSettings = L.t("Tüm Ayarlar", "All Settings")
        let fileCaption = L.t("Ayar dosyası kısayolları, panel tuşlarını, istisnaları, görünümü ve dili taşır: saklamak ya da başka bir Mac'e geçirmek için.",
                              "A settings file holds your shortcuts, switcher keys, exceptions, appearance and language: to keep, or to move to another Mac.")
        add(.general, allSettings, SettingsAnchor.allSettings, [fileCaption])
        add(.general, L.t("Dışa Aktar…", "Export…"), SettingsAnchor.allSettings, [allSettings, fileCaption])
        add(.general, L.t("İçe Aktar…", "Import…"), SettingsAnchor.allSettings, [allSettings, fileCaption])
        add(.general, L.t("Sıfırla…", "Reset…"), SettingsAnchor.allSettings, [allSettings, L.t("Tüm ayarlar sıfırlansın mı?", "Reset all settings?")])

        // Shortcuts: each shortcut's rows, told apart by its keys.
        let show = [L.t("Göster", "Show"), L.t("Sonda göster", "Show at the end"), L.t("Gizle", "Hide")]
        for profile in profiles {
            let keys = profile.description
            func row(_ name: String, _ label: String, _ keywords: [String] = []) {
                add(.shortcuts, label, SettingsAnchor.shortcut(profile.id, name), context: keys, keywords)
            }
            row("keys", ShortcutOptionsView.title(for: profile), [L.t("Kısayolu Sil", "Delete Shortcut")])
            row("keys", L.t("Basılı tut", "Hold"), [
                L.t("Basılı tutulacak tuşlar", "Keys to hold"),
                L.t("⌘⇥ seçildiğinde macOS'un kendi uygulama değiştiricisi kapatılır; Riffle kapanınca geri açılır.",
                    "With ⌘⇥, macOS's own app switcher is turned off while Riffle runs and restored when it quits."),
            ])
            row("apps", L.t("Uygulamalar", "Apps"), [
                L.t("Tüm uygulamalar", "All apps"), L.t("Yalnızca aktif uygulama", "Only the active app"),
                L.t("Aktif uygulama dışındakiler", "All but the active app"), L.t("İmlecin altındaki uygulama", "The app under the pointer"),
            ])
            row("place", L.t("Konum", "Where"), [
                L.t("Tüm masaüstleri", "All desktops"), L.t("Yalnızca bu masaüstü", "Only this desktop"), L.t("Yalnızca bu ekran", "Only this screen"),
            ])
            row("order", L.t("Sıralama", "Order"), [
                L.t("Son kullanılan önce", "Recently used first"), L.t("Uygulamaların açılış sırası", "App launch order"),
                L.t("Alfabetik", "Alphabetical"), L.t("Masaüstüne göre", "By desktop"),
            ])
            row("onePerApp", L.t("Uygulama başına tek pencere (en son kullanılan)", "One window per app (the most recent)"))
            row("minimized", L.t("Küçültülmüş pencereler", "Minimized windows"), show)
            row("hiddenApps", L.t("Gizli uygulamaların pencereleri", "Windows of hidden apps"), show)
            row("windowlessApps", L.t("Penceresi olmayan uygulamalar", "Apps without windows"), show)
            row("fullscreen", L.t("Tam ekran pencereleri göster", "Show full-screen windows"))
            row("style", L.t("Stil", "Style"), [L.t("Görünüm'deki gibi", "As in Appearance")] + SwitcherStyle.allCases.map(ShortcutOptionsView.name))
            row("search", L.t("Doğrudan aramayla aç (Spotlight gibi, açık kalır)", "Open straight into search (stays open, like Spotlight)"))
            if !profile.startInSearch {
                row("release", L.t("Tuşları bırakınca", "When you let go"), [
                    L.t("Seçili pencereye geç", "Switch to the selected window"), L.t("Paneli açık tut", "Keep the switcher open"),
                    L.t("Paneli açık tut ve ara", "Keep it open and search"),
                ])
            }
        }
        add(.shortcuts, L.t("Kısayol Ekle", "Add Shortcut"), SettingsAnchor.addShortcut, [
            L.f("En fazla %1$@ kısayol: her birinin kendi tuşları ve gösterdiği pencereler olur. Yeni kısayol kapalı başlar; tuşlarını seçip aç.",
                "Up to %1$@ shortcuts, each with its own keys and its own choice of windows. A new shortcut starts off: pick its keys, then turn it on.",
                ShortcutProfile.maximum),
        ])
        // While the switcher is open.
        func panelKey(_ name: String, _ label: String, _ keywords: [String] = []) {
            add(.shortcuts, label, SettingsAnchor.panelKey(name), keywords)
        }
        panelKey("backwards", L.t("Panel açıkken", "While the switcher is open"))
        panelKey("backwards", L.t("Basılı tutarken geri git", "Hold to go backwards"), ["⇧"])
        panelKey("move", L.t("Seçimi taşı", "Move the selection"))
        panelKey("switch", L.t("Seçili pencereye geç", "Switch to the selected window"), [L.t("tık", "click")])
        panelKey("jump", L.t("O sıradaki pencereye anında geç", "Jump straight to that window"))
        for slot in [PanelKey.search, .close, .minimize, .fullscreen, .hide, .quit] { panelKey(slot.rawValue, slot.title) }
        panelKey("cancel", L.t("Vazgeç (aramadayken önce aramayı temizler)", "Cancel (clears the search first)"))
        panelKey("vim", L.t("Vim tuşları", "Vim keys"), [L.t("H J K L de seçimi taşır.", "H J K L move the selection too.")])
        panelKey("vim", L.t("Varsayılan Tuşlara Dön", "Restore Default Keys"))

        // Appearance (its own file adds the anchors, `SettingsAnchor.appearance`).
        let deck = SwitcherStyle.allCases.map(ShortcutOptionsView.name)
        add(.appearance, L.t("Stil", "Style"), SettingsAnchor.appearance("style"), deck)
        add(.appearance, L.t("Boyut", "Size"), SettingsAnchor.appearance("size"), [
            L.t("Otomatik", "Automatic"), L.t("Küçük", "Small"), L.t("Orta", "Medium"), L.t("Büyük", "Large"),
            L.t("Desteyi pencere sayısına göre boyutlandırır: birkaç pencere büyük görünür, çok sayıda pencere hepsi sığacak kadar küçülür.",
                "Sizes the deck by how many windows there are: a few windows show large, many shrink until they all fit."),
        ])
        add(.appearance, L.t("Başlık", "Title"), SettingsAnchor.appearance("title"), [
            L.t("Pencere başlığı", "Window title"), L.t("Uygulama adı", "App name"), L.t("Uygulama adı — pencere başlığı", "App name — window title"),
        ])
        add(.appearance, L.t("Uzun başlıkları kısalt", "Truncate long titles"), SettingsAnchor.appearance("truncation"), [
            L.t("Sondan", "At the end"), L.t("Ortadan", "In the middle"), L.t("Baştan", "At the start"),
        ])
        add(.appearance, L.t("Tema", "Theme"), SettingsAnchor.appearance("theme"), [
            "Liquid Glass", L.t("Sistem", "System"), L.t("Koyu", "Dark"), L.t("Açık", "Light"),
        ])
        add(.appearance, L.t("Cam", "Glass"), SettingsAnchor.appearance("glass"), ["Liquid Glass", L.t("Normal", "Regular"), L.t("Şeffaf", "Clear")])
        add(.appearance, L.t("Ayrıntılar", "Details"), SettingsAnchor.appearance("badges"))
        add(.appearance, L.t("Durum rozetlerini göster (küçültülmüş, gizli, tam ekran)", "Show status badges (minimized, hidden, full screen)"),
            SettingsAnchor.appearance("badges"))
        add(.appearance, L.t("Başka masaüstündeki pencerelerde masaüstü numarasını göster", "Show the desktop number for windows on other desktops"),
            SettingsAnchor.appearance("spaceNumbers"))
        add(.appearance, L.t("Seçili pencereyi yerinde önizle", "Preview the selected window in place"), SettingsAnchor.appearance("preview"), [
            L.t("Seçtiğin pencere, ekrandaki gerçek yerinde ve gerçek boyutunda belirir.", "The selected window appears at its real place and size on screen."),
        ])
        add(.appearance, L.t("Hareket", "Motion"), SettingsAnchor.appearance("animations"))
        add(.appearance, L.t("Panel animasyonları", "Switcher animations"), SettingsAnchor.appearance("animations"), [
            L.t("Seçimin kayması, kartların solması ve panelin belirmesi. Sistem Ayarları'nda “Hareketi azalt” açıkken hareket durur, yalnızca yumuşak geçişler kalır.",
                "The selection gliding, cards fading and the switcher fading in. While “Reduce motion” is on in System Settings, only the fades remain."),
        ])
        add(.appearance, L.t("İmleci, geçtiğin pencerenin ortasına taşı", "Move the pointer to the middle of the window you switch to"),
            SettingsAnchor.appearance("pointer"))
        add(.appearance, L.t("Paneli Önizle", "Preview the Switcher"), SettingsAnchor.appearance("previewSwitcher"))

        // Exceptions: each rule's rows, told apart by its app; the rows a new rule has when there are none yet.
        add(.exclusions, L.t("Çalışan Uygulamalardan Ekle", "Add a Running App"), SettingsAnchor.addException, [
            L.t("Henüz istisna yok. Bir istisna, bir uygulamanın pencerelerini panelde gizleyebilir ya da sanal makine gibi bir uygulama öndeyken Riffle'ın kısayollarını ona bırakabilir.",
                "No exceptions yet. An exception can hide an app's windows from the switcher, or leave Riffle's shortcuts to an app such as a virtual machine while it's in front."),
        ])
        add(.exclusions, L.t("Diğer…", "Other…"), SettingsAnchor.addException)
        add(.exclusions, L.t("Hazır Ayar Ekle", "Add Preset"), SettingsAnchor.addException, [
            L.t("Sanal makineler ve uzak masaüstleri", "Virtual machines and remote desktops"), L.t("Bu Mac'te Olanların Hepsi", "All Installed on This Mac"),
        ] + AppException.presets.map(\.name))
        let prefixCaption = L.t("Önek, altındaki uygulamaları da kapsar: “com.microsoft”, “com.microsoft.Word” ile de eşleşir. Kısayollar bir uygulamaya bırakıldığında ⌘⇥ dahil hepsi doğrudan ona gider.",
                                "A prefix also covers the apps under it: “com.microsoft” matches “com.microsoft.Word” too. While an app has Riffle's shortcuts, all of them go straight to it, ⌘⇥ included.")
        for exception in exceptions.isEmpty ? [nil] : exceptions.map(Optional.some) {
            let name = exception.map(exceptionName)
            func row(_ row: String, _ label: String, _ keywords: [String] = []) {
                add(.exclusions, label, exception.map { SettingsAnchor.exception($0.id, row) } ?? SettingsAnchor.addException, context: name, keywords)
            }
            if let exception, let name {
                add(.exclusions, name, SettingsAnchor.exception(exception.id, "bundleID"), [exception.bundleID, L.t("İstisnayı Sil", "Delete Exception")])
            }
            row("bundleID", L.t("Paket kimliği", "Bundle ID"), [L.t("Tam", "Exact"), L.t("Önek", "Prefix"), prefixCaption])
            row("hiding", L.t("Panelde gizle", "Hide from the switcher"), [
                L.t("Hiçbir şeyi", "Nothing"), L.t("Tüm pencerelerini", "All its windows"),
                L.t("Penceresi yokken uygulamayı", "The app while it has no windows"),
                L.t("Başlığında şu geçen pencereleri…", "Windows whose title contains…"), L.t("Başlıkta geçen metin", "Text in the title"),
            ])
            row("shortcuts", L.t("Öndeyken Riffle'ın kısayollarını yok say", "Ignore Riffle's shortcuts while this app is in front"), [
                L.t("Hiçbir zaman", "Never"), L.t("Her zaman", "Always"), L.t("Yalnızca tam ekrandayken", "Only in full screen"),
            ])
        }

        // Permissions
        add(.permissions, L.t("Erişilebilirlik", "Accessibility"), SettingsAnchor.accessibility, [
            L.t("Pencereleri bulmak, öne getirmek ve ⌥'nin bırakılmasını algılamak için gerekli.",
                "Required to find and focus windows and to notice when ⌥ is released."),
            L.t("İzin Ver…", "Grant…"),
        ])
        add(.permissions, L.t("Ekran ve Sistem Sesi Kaydı", "Screen & System Audio Recording"), SettingsAnchor.screenRecording, [
            L.t("Canlı önizlemeler için. Görüntüler yalnızca bellekte tutulur; hiçbir şey kaydedilmez ya da gönderilmez.",
                "For live thumbnails. Images stay in memory only; nothing is saved or sent."),
            L.t("İzin Ver…", "Grant…"), PermissionText.previewsNeed, PermissionText.howToTurnOn,
        ])
        add(.permissions, L.t("Riffle'ı Yeniden Başlat", "Restart Riffle"), SettingsAnchor.screenRecording, [PermissionText.restartForPreviews])

        // About
        add(.about, L.f("Sürüm %1$@ (%2$@)", "Version %1$@ (%2$@)", AppInfo.version, AppInfo.build), SettingsAnchor.version, [
            "Riffle", L.t("macOS için hızlı bir pencere değiştirici. Her pencere, her masaüstü, tek kısayol.",
                          "A fast window switcher for macOS. Every window, every desktop, one shortcut."),
            "© 2026 Riffle · GPL-3.0",
        ])
        for label in [L.t("pencere", "windows"), L.t("uygulama", "apps"), L.t("masaüstü", "desktops"), L.t("son tarama", "last scan")] {
            add(.about, label, SettingsAnchor.stats)
        }
        add(.about, UpdateText.check, SettingsAnchor.updates, [L.t("güncelleme", "update")])
        add(.about, L.t("Güncellemeleri otomatik olarak denetle", "Check for updates automatically"), SettingsAnchor.automaticUpdates, [
            L.t("Riffle günde bir kez appriffle.com'da daha yeni bir sürüm olup olmadığına bakar ve yüklemeden önce sana sorar. Pencerelerinle ilgili hiçbir şey gönderilmez.",
                "Once a day, Riffle checks appriffle.com for a newer version and asks you before installing it. Nothing about your windows is ever sent."),
        ])
        add(.about, L.t("Günlüğü Finder'da Göster", "Show Log in Finder"), SettingsAnchor.log)
        add(.about, L.f("Soru ya da sorun için %1$@ adresine yaz.", "Questions or problems? Write to %1$@.", Support.address), SettingsAnchor.support, [
            L.t("destek", "support"), L.t("yardım", "help"), L.t("e-posta", "email"),
        ])
        return entries
    }

    /// What Settings → Exceptions calls a rule: its app, the name a preset gave it, or its identifier.
    static func exceptionName(_ exception: AppException) -> String {
        if !exception.matchesPrefix, AppLookup.url(exception.bundleID) != nil { return AppLookup.name(exception.bundleID) }
        if !exception.name.isEmpty { return exception.name }
        let id = exception.bundleID.trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? L.t("Yeni istisna", "New exception") : id
    }
}

// MARK: - Anchors

/// Rows a search result brings into view; each is the `settingsAnchor` of its row.
enum SettingsAnchor {
    static let launchAtLogin = "general.launchAtLogin"
    static let menuBar = "general.menuBar"
    static let language = "general.language"
    static let delay = "general.delay"
    static let screen = "general.screen"
    static let hover = "general.hover"
    static let haptics = "general.haptics"
    static let showNow = "general.showNow"
    static let allSettings = "general.allSettings"
    static let addShortcut = "shortcuts.add"
    static let addException = "exceptions.add"
    static let accessibility = "permissions.accessibility"
    static let screenRecording = "permissions.screenRecording"
    static let version = "about.version"
    static let stats = "about.stats"
    static let log = "about.log"
    static let updates = "about.updates"
    static let automaticUpdates = "about.automaticUpdates"
    static let support = "about.support"

    static func shortcut(_ id: Int, _ row: String) -> String { "shortcut.\(id).\(row)" }
    static func panelKey(_ row: String) -> String { "panelKeys.\(row)" }
    static func exception(_ id: UUID, _ row: String) -> String { "exception.\(id.uuidString).\(row)" }
    static func appearance(_ row: String) -> String { "appearance.\(row)" }
}

private struct SettingsHighlightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The row a search result just brought into view, lit up for a moment.
    var settingsHighlight: String? {
        get { self[SettingsHighlightKey.self] }
        set { self[SettingsHighlightKey.self] = newValue }
    }
}

extension View {
    /// Lets a Settings search result bring this row into view, and light it up for a moment.
    func settingsAnchor(_ anchor: String) -> some View {
        modifier(SettingsAnchorModifier(anchor: anchor))
    }
}

private struct SettingsAnchorModifier: ViewModifier {
    let anchor: String
    @Environment(\.settingsHighlight) private var highlight

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(highlight == anchor ? 0.18 : 0))
                    .padding(.horizontal, -6)
                    .padding(.vertical, -4)
                    .animation(.easeOut(duration: 0.4), value: highlight == anchor)
            }
            .id(anchor)
    }
}

// MARK: - Sidebar

/// A section in the Settings sidebar: its name on a tinted icon.
struct SettingsSectionLabel: View {
    let section: SettingsSection

    var body: some View {
        Label {
            Text(section.title)
        } icon: {
            SettingsSectionIcon(section: section, side: 22)
        }
    }
}

struct SettingsSectionIcon: View {
    let section: SettingsSection
    let side: CGFloat

    var body: some View {
        Image(systemName: section.symbol)
            .font(.system(size: side / 2, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(section.tint.gradient, in: RoundedRectangle(cornerRadius: side * 0.27, style: .continuous))
    }
}

/// A search result in the sidebar: "Section › Row", with its section's icon.
struct SettingsSearchResultRow: View {
    let entry: SettingsSearchEntry

    var body: some View {
        let path = Text(verbatim: entry.path.dropLast().joined(separator: " › ") + " › ").foregroundStyle(.secondary)
        let row = Text(verbatim: entry.label).foregroundStyle(.primary)
        Label {
            Text("\(path)\(row)")
                .lineLimit(2)
        } icon: {
            SettingsSectionIcon(section: entry.section, side: 18)
        }
    }
}
