import Carbon
import Cocoa
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, shortcuts, appearance, exclusions, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L.t("Genel", "General")
        case .shortcuts: return L.t("Kısayollar", "Shortcuts")
        case .appearance: return L.t("Görünüm", "Appearance")
        case .exclusions: return L.t("İstisnalar", "Exceptions")
        case .permissions: return L.t("İzinler", "Permissions")
        case .about: return L.t("Hakkında", "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .shortcuts: return "command"
        case .appearance: return "paintpalette.fill"
        case .exclusions: return "eye.slash.fill"
        case .permissions: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .shortcuts: return .blue
        case .appearance: return .purple
        case .exclusions: return .orange
        case .permissions: return .green
        case .about: return .indigo
        }
    }
}

/// Where Settings is: the section, the sidebar's search, and the row a search result brings into view. Kept outside the
/// views, which are built anew when the language changes.
final class SettingsNavigation: ObservableObject {
    enum SidebarItem: Hashable {
        case section(SettingsSection)
        case result(String)
    }

    /// A row to bring into view; a new one each time a result is picked, even the same result again.
    struct Target: Equatable {
        let anchor: String?
        let token = UUID()
    }

    @Published var selection: SettingsSection = .general
    @Published var query = ""
    /// The search result last picked, while it's still listed.
    @Published private(set) var pickedResult: String?
    @Published private(set) var target: Target?
    /// The row lit up for a moment once it's in view.
    @Published var highlight: String?

    var sidebarItem: SidebarItem {
        if !query.isEmpty, let pickedResult { return .result(pickedResult) }
        return .section(selection)
    }

    func open(_ section: SettingsSection) {
        selection = section
        pickedResult = nil
        target = nil
    }

    func open(_ entry: SettingsSearchEntry) {
        selection = entry.section
        pickedResult = entry.id
        target = Target(anchor: entry.anchor)
    }
}

final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private let navigation = SettingsNavigation()

    /// `offscreen`: for the language audit, invisible, never activated, its frame not remembered.
    func show(section: SettingsSection? = nil, offscreen: Bool = false) {
        if let section { navigation.open(section) }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsRootView(navigation: navigation))
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 820, height: 600))
            window.contentMinSize = NSSize(width: 760, height: 520)
            window.center()
            if !offscreen { window.setFrameAutosaveName("RiffleSettings") }
            self.window = window
        }
        updateTitle()
        if offscreen {
            // Out of sight: under the desktop picture, where the WindowServer still draws it.
            window?.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            window?.orderBack(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var currentWindow: NSWindow? { window }

    /// For the language audit: the sidebar's search, as if typed.
    var navigationState: SettingsNavigation { navigation }

    /// The title follows the language setting.
    func updateTitle() {
        window?.title = L.t("Riffle Ayarları", "Riffle Settings")
    }
}

// MARK: - Root

struct SettingsRootView: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject private var prefs = Prefs.shared

    private var results: [SettingsSearchEntry] {
        guard !navigation.query.isEmpty else { return [] }
        return SettingsSearch.results(for: navigation.query, in: SettingsSearch.index(profiles: prefs.profiles, exceptions: prefs.appExceptions))
    }

    var body: some View {
        let results = self.results
        let sections = navigation.query.isEmpty ? SettingsSection.allCases : SettingsSearch.sections(for: navigation.query, results: results)
        // Only ever a row that's listed: the list mishandles a selection it can't show.
        let selected: SettingsNavigation.SidebarItem? = switch navigation.sidebarItem {
        case .section(let section): sections.contains(section) ? .section(section) : nil
        case .result(let id): results.contains { $0.id == id } ? .result(id) : nil
        }
        NavigationSplitView {
            List(selection: Binding(get: { selected }, set: { pick($0, in: results) })) {
                ForEach(sections) { section in
                    SettingsSectionLabel(section: section).tag(SettingsNavigation.SidebarItem.section(section))
                }
                ForEach(results) { entry in
                    SettingsSearchResultRow(entry: entry).tag(SettingsNavigation.SidebarItem.result(entry.id))
                }
            }
            // Laid out anew when a search starts or ends rather than changed row by row, which trips up the list.
            .id(navigation.query.isEmpty)
            .overlay {
                if sections.isEmpty {
                    Text(L.t("Sonuç Yok", "No Results")).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $navigation.query, placement: .sidebar, prompt: Text(L.t("Ayarlarda Ara", "Search Settings")))
            .onSubmit(of: .search) {
                if let first = results.first { navigation.open(first) }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            ScrollViewReader { proxy in
                Group {
                    switch navigation.selection {
                    case .general: GeneralSettings()
                    case .shortcuts: ShortcutSettings()
                    case .appearance: AppearanceSettings()
                    case .exclusions: ExceptionSettings()
                    case .permissions: PermissionSettings()
                    case .about: AboutSettings()
                    }
                }
                .navigationTitle(navigation.selection.title)
                .environment(\.settingsHighlight, navigation.highlight)
                .task(id: navigation.target) { await reveal(navigation.target, with: proxy) }
            }
        }
        .id(prefs.language)
        .localized(prefs.language)
    }

    private func pick(_ item: SettingsNavigation.SidebarItem?, in results: [SettingsSearchEntry]) {
        // The list reports back where Settings already is (a selection made in code, rows coming and going): nothing to
        // do, and nothing must change while the list is still updating.
        guard let item, item != navigation.sidebarItem else { return }
        switch item {
        case .section(let section):
            navigation.open(section)
        case .result(let id):
            if let entry = results.first(where: { $0.id == id }) { navigation.open(entry) }
        }
    }

    /// Brings a search result's row into view once its section is laid out, and lights it up for a moment.
    private func reveal(_ target: SettingsNavigation.Target?, with proxy: ScrollViewProxy) async {
        guard let anchor = target?.anchor else { return }
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(anchor, anchor: .center) }
        navigation.highlight = anchor
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        if navigation.highlight == anchor { navigation.highlight = nil }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            RecoveredSettingsNotice()
            PreviousSettingsNotice()
            Section {
                Toggle(L.t("Girişte başlat", "Launch at login"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { LoginItem.set($0); launchAtLogin = LoginItem.isEnabled }))
                    .settingsAnchor(SettingsAnchor.launchAtLogin)
                Toggle(L.t("Menü çubuğunda göster", "Show in menu bar"), isOn: $prefs.showMenuBarIcon)
                    .settingsAnchor(SettingsAnchor.menuBar)
                Picker(L.t("Dil", "Language"), selection: $prefs.language) {
                    ForEach(AppLanguage.pickerOrder) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                .settingsAnchor(SettingsAnchor.language)
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L.t("Görünme gecikmesi", "Appearance delay"))
                        Spacer()
                        Text(L.milliseconds(Double(prefs.showDelayMs))).monospacedDigit().foregroundStyle(.secondary)
                    }
                    let range = SettingsSnapshot.showDelayRange
                    Slider(value: Binding(get: { Double(prefs.showDelayMs) }, set: { prefs.showDelayMs = Int($0.rounded()) }),
                           in: Double(range.lowerBound)...Double(range.upperBound), step: 10)
                    Text(AppearanceDelay.caption(for: prefs.profiles))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .settingsAnchor(SettingsAnchor.delay)
                Picker(L.t("Panelin gösterileceği ekran", "Show the switcher on"), selection: $prefs.screen) {
                    Text(L.t("Farenin olduğu ekran", "Screen with the mouse")).tag(ScreenChoice.mouse)
                    Text(L.t("Aktif pencerenin ekranı", "Screen with the active window")).tag(ScreenChoice.activeWindow)
                    Text(L.t("Ana ekran", "Main screen")).tag(ScreenChoice.main)
                }
                .settingsAnchor(SettingsAnchor.screen)
            } header: {
                Text(L.t("Davranış", "Behavior"))
            }
            Section {
                Toggle(L.t("Fareyle üzerine gelince seç", "Select on mouse hover"), isOn: $prefs.mouseHoverSelects)
                    .settingsAnchor(SettingsAnchor.hover)
                Toggle(L.t("Seçim değişince hafif dokunsal geri bildirim", "Subtle haptic feedback on selection"), isOn: $prefs.hapticFeedback)
                    .settingsAnchor(SettingsAnchor.haptics)
            } header: {
                Text(L.t("Etkileşim", "Interaction"))
            }
            Section {
                HStack {
                    Button(L.t("Paneli Şimdi Göster", "Show Switcher Now")) { SwitcherController.shared.showSticky() }
                    Spacer()
                }
                .settingsAnchor(SettingsAnchor.showNow)
            }
            Section {
                HStack {
                    Button(L.t("Dışa Aktar…", "Export…")) { SettingsTransfer.export(from: SettingsWindow.shared.currentWindow) }
                    Button(L.t("İçe Aktar…", "Import…")) { SettingsTransfer.importSettings(into: SettingsWindow.shared.currentWindow) }
                    Spacer()
                    Button(L.t("Sıfırla…", "Reset…"), role: .destructive) { SettingsTransfer.confirmReset(in: SettingsWindow.shared.currentWindow) }
                }
                .settingsAnchor(SettingsAnchor.allSettings)
                Text(L.t("Ayar dosyası kısayolları, panel tuşlarını, istisnaları, görünümü ve dili taşır: saklamak ya da başka bir Mac'e geçirmek için.",
                         "A settings file holds your shortcuts, switcher keys, exceptions, appearance and language: to keep, or to move to another Mac."))
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text(L.t("Tüm Ayarlar", "All Settings"))
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }
}

/// What General says about the appearance delay.
enum AppearanceDelay {
    /// What it's for, told with the keys of the first shortcut: the one the welcome window and the menu bar name.
    static func caption(for profiles: [ShortcutProfile]) -> String {
        L.f("Hızlı bir %1$@ dokunuşunda panel hiç görünmeden önceki pencereye geçilir. Bu süre, panelin ne zaman belireceğini belirler.",
            "A quick %1$@ tap switches to the previous window without ever showing the switcher. This sets when the switcher appears.",
            (profiles.first ?? ShortcutProfile.defaults[0]).description)
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var status = ShortcutStatus.shared

    var body: some View {
        Form {
            ForEach($prefs.profiles) { $profile in
                ProfileSection(profile: $profile, failure: status.failures[profile.id], isDuplicate: status.duplicates.contains(profile.id),
                               canRemove: prefs.profiles.count > 1) { prefs.removeProfile(id: profile.id) }
            }
            Section {
                HStack {
                    Button {
                        prefs.addProfile()
                    } label: {
                        Label(L.t("Kısayol Ekle", "Add Shortcut"), systemImage: "plus")
                    }
                    .disabled(prefs.profiles.count >= ShortcutProfile.maximum)
                    Spacer()
                    Text(L.f("%1$@ / %2$@", "%1$@ of %2$@", prefs.profiles.count, ShortcutProfile.maximum))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .settingsAnchor(SettingsAnchor.addShortcut)
                Text(L.f("En fazla %1$@ kısayol: her birinin kendi tuşları ve gösterdiği pencereler olur. Yeni kısayol kapalı başlar; tuşlarını seçip aç.",
                         "Up to %1$@ shortcuts, each with its own keys and its own choice of windows. A new shortcut starts off: pick its keys, then turn it on.",
                         ShortcutProfile.maximum))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            PanelKeysSection()
        }
        .formStyle(.grouped)
    }
}

private struct ProfileSection: View {
    @Binding var profile: ShortcutProfile
    let failure: OSStatus?
    let isDuplicate: Bool
    let canRemove: Bool
    let remove: () -> Void

    private var title: String { ShortcutOptionsView.title(for: profile) }

    var body: some View {
        Section {
            HStack(spacing: 10) {
                HoldRecorder(modifiers: $profile.holdModifiers)
                Text("+").foregroundStyle(.secondary)
                KeyRecorder(keyCode: $profile.keyCode)
                Spacer()
            }
            .settingsAnchor(SettingsAnchor.shortcut(profile.id, "keys"))
            if isDuplicate, profile.isEnabled {
                Label(L.t("Bu tuşları başka bir Riffle kısayolu kullanıyor, bu kısayol çalışmıyor. Başka tuşlar seç.",
                          "Another Riffle shortcut already uses these keys, so this one doesn't work. Pick other keys."),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if let failure, profile.isEnabled {
                Label(L.f("Bu kısayolu başka bir uygulama kullanıyor (%1$@).", "Another app already uses this shortcut (%1$@).", failure),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if profile.usesCommandTab && profile.isEnabled {
                Label(L.t("⌘⇥ seçildiğinde macOS'un kendi uygulama değiştiricisi kapatılır; Riffle kapanınca geri açılır.",
                          "With ⌘⇥, macOS's own app switcher is turned off while Riffle runs and restored when it quits."),
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ShortcutOptionsView(profile: $profile)
            // Right under "open straight into search", which makes it moot.
            ReleaseBehaviorPicker(profile: $profile)
        } header: {
            HStack {
                Toggle(isOn: $profile.isEnabled) {
                    Text(title).font(.headline)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Spacer()
                Text(profile.description)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .opacity(profile.isEnabled ? 1 : 0.4)
                if canRemove {
                    Button(role: .destructive, action: remove) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(L.t("Kısayolu Sil", "Delete Shortcut"))
                    .accessibilityLabel(L.t("Kısayolu Sil", "Delete Shortcut"))
                }
            }
        }
    }
}

// MARK: - Appearance (AppearanceSettingsView.swift)

// MARK: - Exceptions (ExceptionSettings.swift)

enum AppLookup {
    static func url(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func name(_ bundleID: String) -> String {
        guard let url = url(bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(_ bundleID: String) -> NSImage {
        guard let url = url(bundleID) else { return NSImage(named: NSImage.applicationIconName) ?? NSImage() }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - Permissions

private struct PermissionSettings: View {
    @StateObject private var state = PermissionState()

    var body: some View {
        Form {
            Section {
                PermissionStatusRow(title: L.t("Erişilebilirlik", "Accessibility"),
                                    detail: L.t("Pencereleri bulmak, öne getirmek ve ⌥'nin bırakılmasını algılamak için gerekli.",
                                                "Required to find and focus windows and to notice when ⌥ is released."),
                                    granted: state.accessibility) {
                    Permissions.requestAccessibility()
                    Permissions.openAccessibilitySettings()
                }
                .settingsAnchor(SettingsAnchor.accessibility)
                PermissionStatusRow(title: L.t("Ekran ve Sistem Sesi Kaydı", "Screen & System Audio Recording"),
                                    detail: L.t("Canlı önizlemeler için. Görüntüler yalnızca bellekte tutulur; hiçbir şey kaydedilmez ya da gönderilmez.",
                                                "For live thumbnails. Images stay in memory only; nothing is saved or sent."),
                                    granted: state.screenRecording) {
                    Permissions.requestScreenRecording()
                    Permissions.openScreenRecordingSettings()
                }
                .settingsAnchor(SettingsAnchor.screenRecording)
                // Riffle is complete without previews: say so, and how to have them.
                if state.needsRestart {
                    Label(PermissionText.restartForPreviews, systemImage: "arrow.clockwise.circle.fill")
                        .foregroundStyle(.secondary)
                } else if !state.screenRecording {
                    Text(L.sentences([PermissionText.previewsNeed, PermissionText.howToTurnOn]))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                HStack {
                    Spacer()
                    if state.needsRestart {
                        Button(L.t("Riffle'ı Yeniden Başlat", "Restart Riffle")) { Relauncher.relaunch() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(L.t("Riffle'ı Yeniden Başlat", "Restart Riffle")) { Relauncher.relaunch() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { state.start() }
        .onDisappear { state.stop() }
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(granted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button(L.t("İzin Ver…", "Grant…"), action: action).buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - About

private struct AboutSettings: View {
    private let store = WindowStore.shared
    @ObservedObject private var updates = Updates.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                Text("Riffle").font(.system(size: 30, weight: .bold, design: .rounded))
                Text(L.f("Sürüm %1$@ (%2$@)", "Version %1$@ (%2$@)", AppInfo.version, AppInfo.build))
                    .foregroundStyle(.secondary)
                    .settingsAnchor(SettingsAnchor.version)
                Text(L.t("macOS için hızlı bir pencere değiştirici. Her pencere, her masaüstü, tek kısayol.",
                         "A fast window switcher for macOS. Every window, every desktop, one shortcut."))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                HStack(spacing: 24) {
                    Stat(value: "\(store.windows.count)", label: L.t("pencere", "windows"))
                    Stat(value: "\(store.apps.count)", label: L.t("uygulama", "apps"))
                    Stat(value: "\(max(store.topology.spaces.filter { $0.desktopNumber != nil }.count, 1))", label: L.t("masaüstü", "desktops"))
                    Stat(value: L.milliseconds(store.lastScanDuration * 1000), label: L.t("son tarama", "last scan"))
                }
                .padding(.vertical, 8)
                .settingsAnchor(SettingsAnchor.stats)
                HStack(spacing: 12) {
                    Button(UpdateText.check, action: updates.check)
                        .disabled(!updates.canCheck)
                        .settingsAnchor(SettingsAnchor.updates)
                    Button(L.t("Günlüğü Finder'da Göster", "Show Log in Finder"), action: showLog)
                        .settingsAnchor(SettingsAnchor.log)
                }
                VStack(spacing: 6) {
                    Toggle(L.t("Güncellemeleri otomatik olarak denetle", "Check for updates automatically"),
                           isOn: Binding(get: { updates.checksAutomatically }, set: updates.setChecksAutomatically))
                        .disabled(!updates.isAvailable)
                    Text(L.t("Riffle günde bir kez appriffle.com'da daha yeni bir sürüm olup olmadığına bakar ve yüklemeden önce sana sorar. Pencerelerinle ilgili hiçbir şey gönderilmez.",
                             "Once a day, Riffle checks appriffle.com for a newer version and asks you before installing it. Nothing about your windows is ever sent."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .settingsAnchor(SettingsAnchor.automaticUpdates)
                Divider().frame(maxWidth: 420)
                Text(supportLine)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .settingsAnchor(SettingsAnchor.support)
                Text(verbatim: "© 2026 Riffle · GPL-3.0")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(30)
            .frame(maxWidth: .infinity)
        }
    }

    /// Where to write, the address a link to a new mail that says which Riffle and macOS it's about.
    private var supportLine: AttributedString {
        var line = AttributedString(L.f("Soru ya da sorun için %1$@ adresine yaz.", "Questions or problems? Write to %1$@.", Support.address))
        if let address = line.range(of: Support.address), let mail = Support.mailURL { line[address].link = mail }
        return line
    }

    /// The log file selected in Finder (its folder when nothing has been written yet).
    private func showLog() {
        Log.flush()
        if FileManager.default.fileExists(atPath: Log.fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
        } else {
            try? FileManager.default.createDirectory(at: Log.folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Log.folder)
        }
    }
}

private struct Stat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
