import SwiftUI

// MARK: - Appearance

struct AppearanceSettings: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ForEach(SwitcherStyle.allCases, id: \.self) { style in
                        StyleCard(style: style, selected: prefs.style == style) { prefs.style = style }
                    }
                }
                .padding(.vertical, 4)
                .settingsAnchor(SettingsAnchor.appearance("style"))
                Picker(L.t("Boyut", "Size"), selection: $prefs.size) {
                    Text(L.t("Otomatik", "Automatic")).tag(SwitcherSize.auto)
                    Text(L.t("Küçük", "Small")).tag(SwitcherSize.small)
                    Text(L.t("Orta", "Medium")).tag(SwitcherSize.medium)
                    Text(L.t("Büyük", "Large")).tag(SwitcherSize.large)
                }
                .pickerStyle(.segmented)
                .settingsAnchor(SettingsAnchor.appearance("size"))
                if prefs.size == .auto {
                    Text(L.t("Desteyi pencere sayısına göre boyutlandırır: birkaç pencere büyük görünür, çok sayıda pencere hepsi sığacak kadar küçülür.",
                             "Sizes the deck by how many windows there are: a few windows show large, many shrink until they all fit."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker(L.t("Başlık", "Title"), selection: $prefs.titleContent) {
                    Text(L.t("Pencere başlığı", "Window title")).tag(TitleContent.windowTitle)
                    Text(L.t("Uygulama adı", "App name")).tag(TitleContent.appName)
                    Text(L.t("Uygulama adı — pencere başlığı", "App name — window title")).tag(TitleContent.appAndWindowTitle)
                }
                .settingsAnchor(SettingsAnchor.appearance("title"))
                Picker(L.t("Uzun başlıkları kısalt", "Truncate long titles"), selection: $prefs.titleTruncation) {
                    Text(L.t("Sondan", "At the end")).tag(TitleTruncation.end)
                    Text(L.t("Ortadan", "In the middle")).tag(TitleTruncation.middle)
                    Text(L.t("Baştan", "At the start")).tag(TitleTruncation.start)
                }
                .settingsAnchor(SettingsAnchor.appearance("truncation"))
            } header: {
                Text(L.t("Stil", "Style"))
            }
            Section {
                Picker(L.t("Tema", "Theme"), selection: $prefs.theme) {
                    Text(L.t("Sistem", "System")).tag(ThemeMode.system)
                    Text(L.t("Koyu", "Dark")).tag(ThemeMode.dark)
                    Text(L.t("Açık", "Light")).tag(ThemeMode.light)
                }
                .settingsAnchor(SettingsAnchor.appearance("theme"))
                Picker(L.t("Cam", "Glass"), selection: $prefs.glass) {
                    Text(L.t("Normal", "Regular")).tag(GlassStyle.regular)
                    Text(L.t("Şeffaf", "Clear")).tag(GlassStyle.clear)
                }
                .settingsAnchor(SettingsAnchor.appearance("glass"))
            } header: {
                Text("Liquid Glass")
            }
            Section {
                Toggle(L.t("Durum rozetlerini göster (küçültülmüş, gizli, tam ekran)", "Show status badges (minimized, hidden, full screen)"), isOn: $prefs.showBadges)
                    .settingsAnchor(SettingsAnchor.appearance("badges"))
                Toggle(L.t("Başka masaüstündeki pencerelerde masaüstü numarasını göster", "Show the desktop number for windows on other desktops"), isOn: $prefs.showSpaceNumbers)
                    .settingsAnchor(SettingsAnchor.appearance("spaceNumbers"))
                Toggle(isOn: $prefs.previewSelectedWindow) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("Seçili pencereyi yerinde önizle", "Preview the selected window in place"))
                        Text(L.t("Seçtiğin pencere, ekrandaki gerçek yerinde ve gerçek boyutunda belirir.",
                                 "The selected window appears at its real place and size on screen."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .settingsAnchor(SettingsAnchor.appearance("preview"))
            } header: {
                Text(L.t("Ayrıntılar", "Details"))
            }
            Section {
                Toggle(isOn: $prefs.panelAnimations) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("Panel animasyonları", "Switcher animations"))
                        Text(L.t("Seçimin kayması, kartların solması ve panelin belirmesi. Sistem Ayarları'nda “Hareketi azalt” açıkken hareket durur, yalnızca yumuşak geçişler kalır.",
                                 "The selection gliding, cards fading and the switcher fading in. While “Reduce motion” is on in System Settings, only the fades remain."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .settingsAnchor(SettingsAnchor.appearance("animations"))
                Toggle(L.t("İmleci, geçtiğin pencerenin ortasına taşı", "Move the pointer to the middle of the window you switch to"),
                       isOn: $prefs.pointerFollowsSwitch)
                    .settingsAnchor(SettingsAnchor.appearance("pointer"))
            } header: {
                Text(L.t("Hareket", "Motion"))
            }
            Section {
                Button(L.t("Paneli Önizle", "Preview the Switcher")) { SwitcherController.shared.showSticky() }
                    .settingsAnchor(SettingsAnchor.appearance("previewSwitcher"))
            }
        }
        .formStyle(.grouped)
    }
}

private struct StyleCard: View {
    let style: SwitcherStyle
    let selected: Bool
    let action: () -> Void

    private var title: String {
        switch style {
        case .deck: return L.t("Deste", "Deck")
        case .stage: return L.t("Sahne", "Stage")
        case .appIcons: return L.t("Simgeler", "Icons")
        case .titles: return L.t("Başlıklar", "Titles")
        case .list: return L.t("Liste", "List")
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary)
                    preview.padding(10)
                }
                .frame(height: 78)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                Text(title).font(.callout.weight(selected ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var preview: some View {
        switch style {
        case .deck:
            // Cells: an icon and a title line over each thumbnail, the selected one on a plate.
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 1.5).fill(.secondary.opacity(0.6)).frame(width: 5, height: 5)
                            Capsule().fill(.secondary.opacity(0.5)).frame(height: 3)
                        }
                        RoundedRectangle(cornerRadius: 2.5).fill(.secondary.opacity(0.35))
                    }
                    .padding(3)
                    .background(index == 1 ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(index == 1 ? Color.accentColor : .clear, lineWidth: 1))
                }
            }
        case .stage:
            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.7))
                HStack(spacing: 4) {
                    ForEach(0..<5) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(index == 2 ? Color.accentColor.opacity(0.7) : .secondary.opacity(0.35))
                            .frame(height: 10)
                    }
                }
            }
        case .appIcons:
            HStack(spacing: 6) {
                ForEach(0..<4) { index in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 5).fill(index == 1 ? Color.accentColor.opacity(0.7) : .secondary.opacity(0.35)).aspectRatio(1, contentMode: .fit)
                        Capsule().fill(.secondary.opacity(0.5)).frame(height: 3)
                    }
                }
            }
        case .titles:
            // Compact rows: an icon and a title each, the selected one on a plate.
            VStack(spacing: 3) {
                ForEach(0..<5) { index in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1.5).fill(.secondary.opacity(0.55)).frame(width: 6, height: 6)
                        Capsule().fill(.secondary.opacity(index == 1 ? 0.75 : 0.4)).frame(width: [34, 26, 40, 22, 30][index], height: 3)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1.5)
                    .background(index == 1 ? Color.accentColor.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 2.5))
                }
            }
        case .list:
            // Rows on the left, the selected window's preview on the right.
            HStack(spacing: 6) {
                VStack(spacing: 4) {
                    ForEach(0..<4) { index in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.5)).frame(width: 8, height: 8)
                            Capsule().fill(index == 1 ? Color.accentColor.opacity(0.7) : .secondary.opacity(0.35)).frame(height: 4)
                        }
                    }
                }
                RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.45))
            }
        }
    }
}
