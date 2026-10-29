import SwiftUI

/// The rows of a shortcut's section that decide which windows it lists, in what order and how (the keys are above them).
struct ShortcutOptionsView: View {
    @Binding var profile: ShortcutProfile

    var body: some View {
        Picker(L.t("Uygulamalar", "Apps"), selection: $profile.apps) {
            Text(L.t("Tüm uygulamalar", "All apps")).tag(AppScope.allApps)
            Text(L.t("Yalnızca aktif uygulama", "Only the active app")).tag(AppScope.activeApp)
            Text(L.t("Aktif uygulama dışındakiler", "All but the active app")).tag(AppScope.otherApps)
            Text(L.t("İmlecin altındaki uygulama", "The app under the pointer")).tag(AppScope.appUnderPointer)
        }
        .settingsAnchor(SettingsAnchor.shortcut(profile.id, "apps"))
        Picker(L.t("Konum", "Where"), selection: $profile.place) {
            Text(L.t("Tüm masaüstleri", "All desktops")).tag(PlaceScope.allDesktops)
            Text(L.t("Yalnızca bu masaüstü", "Only this desktop")).tag(PlaceScope.thisDesktop)
            Text(L.t("Yalnızca bu ekran", "Only this screen")).tag(PlaceScope.thisScreen)
        }
        .settingsAnchor(SettingsAnchor.shortcut(profile.id, "place"))
        Picker(L.t("Sıralama", "Order"), selection: $profile.order) {
            Text(L.t("Son kullanılan önce", "Recently used first")).tag(WindowOrder.recentlyUsed)
            Text(L.t("Uygulamaların açılış sırası", "App launch order")).tag(WindowOrder.launchOrder)
            Text(L.t("Alfabetik", "Alphabetical")).tag(WindowOrder.alphabetical)
            Text(L.t("Masaüstüne göre", "By desktop")).tag(WindowOrder.byDesktop)
        }
        .settingsAnchor(SettingsAnchor.shortcut(profile.id, "order"))
        Toggle(L.t("Uygulama başına tek pencere (en son kullanılan)", "One window per app (the most recent)"), isOn: $profile.onePerApp)
            .settingsAnchor(SettingsAnchor.shortcut(profile.id, "onePerApp"))
        ShowOptionPicker(title: L.t("Küçültülmüş pencereler", "Minimized windows"), selection: $profile.minimized)
            .settingsAnchor(SettingsAnchor.shortcut(profile.id, "minimized"))
        ShowOptionPicker(title: L.t("Gizli uygulamaların pencereleri", "Windows of hidden apps"), selection: $profile.hiddenApps)
            .settingsAnchor(SettingsAnchor.shortcut(profile.id, "hiddenApps"))
        ShowOptionPicker(title: L.t("Penceresi olmayan uygulamalar", "Apps without windows"), selection: $profile.windowlessApps)
            .disabled(!profile.listsWindowlessApps)
            .settingsAnchor(SettingsAnchor.shortcut(profile.id, "windowlessApps"))
        Toggle(L.t("Tam ekran pencereleri göster", "Show full-screen windows"), isOn: $profile.showFullscreen)
            .settingsAnchor(SettingsAnchor.shortcut(profile.id, "fullscreen"))
        Picker(L.t("Stil", "Style"), selection: $profile.style) {
            Text(L.t("Görünüm'deki gibi", "As in Appearance")).tag(SwitcherStyle?.none)
            ForEach(SwitcherStyle.allCases, id: \.self) { style in
                Text(ShortcutOptionsView.name(of: style)).tag(SwitcherStyle?.some(style))
            }
        }
        .settingsAnchor(SettingsAnchor.shortcut(profile.id, "style"))
        Toggle(L.t("Doğrudan aramayla aç (Spotlight gibi, açık kalır)", "Open straight into search (stays open, like Spotlight)"), isOn: $profile.startInSearch)
            .settingsAnchor(SettingsAnchor.shortcut(profile.id, "search"))
    }

    static func name(of style: SwitcherStyle) -> String {
        switch style {
        case .deck: return L.t("Deste", "Deck")
        case .stage: return L.t("Sahne", "Stage")
        case .appIcons: return L.t("Simgeler", "Icons")
        case .titles: return L.t("Başlıklar", "Titles")
        case .list: return L.t("Liste", "List")
        }
    }

    /// The section's heading: whose windows and where, at a glance.
    static func title(for profile: ShortcutProfile) -> String {
        var title: String
        switch profile.apps {
        case .activeApp: title = L.t("Aktif uygulamanın pencereleri", "Windows of the active app")
        case .otherApps: title = L.t("Diğer uygulamaların pencereleri", "Windows of the other apps")
        case .appUnderPointer: title = L.t("İmlecin altındaki uygulamanın pencereleri", "Windows of the app under the pointer")
        case .allApps:
            switch profile.place {
            case .allDesktops: title = L.t("Tüm pencereler", "All windows")
            case .thisDesktop: title = L.t("Bu masaüstündeki pencereler", "Windows on this desktop")
            case .thisScreen: title = L.t("Bu ekrandaki pencereler", "Windows on this screen")
            }
        }
        if profile.apps != .allApps {
            switch profile.place {
            case .allDesktops: break
            case .thisDesktop: title += L.t(" · bu masaüstü", " · this desktop")
            case .thisScreen: title += L.t(" · bu ekran", " · this screen")
            }
        }
        return profile.startInSearch ? title + L.t(" · arama", " · search") : title
    }
}

/// Show in place, show at the end, or hide.
private struct ShowOptionPicker: View {
    let title: String
    @Binding var selection: ShowOption

    var body: some View {
        Picker(title, selection: $selection) {
            Text(L.t("Göster", "Show")).tag(ShowOption.show)
            Text(L.t("Sonda göster", "Show at the end")).tag(ShowOption.showAtEnd)
            Text(L.t("Gizle", "Hide")).tag(ShowOption.hide)
        }
    }
}
