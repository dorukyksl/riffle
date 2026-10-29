import Cocoa
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Exceptions: per-app rules (see `AppException`), one section each.
struct ExceptionSettings: View {
    @ObservedObject private var prefs = Prefs.shared
    /// The presets whose app is on this Mac, looked up once (a LaunchServices query each).
    @State private var presetsHere: [String] = []

    private var candidates: [NSRunningApplication] {
        let taken = prefs.appExceptions.filter { !$0.matchesPrefix }.map { AppException.normalized($0.bundleID) }
        return NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return false }
                return !taken.contains(AppException.normalized(id))
            }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    var body: some View {
        Form {
            if prefs.appExceptions.isEmpty {
                Section {
                    Text(L.t("Henüz istisna yok. Bir istisna, bir uygulamanın pencerelerini panelde gizleyebilir ya da sanal makine gibi bir uygulama öndeyken Riffle'ın kısayollarını ona bırakabilir.",
                             "No exceptions yet. An exception can hide an app's windows from the switcher, or leave Riffle's shortcuts to an app such as a virtual machine while it's in front."))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(prefs.appExceptions) { exception in
                ExceptionSection(exception: binding(exception.id)) {
                    prefs.appExceptions.removeAll { $0.id == exception.id }
                }
            }
            Section {
                HStack {
                    Menu(L.t("Çalışan Uygulamalardan Ekle", "Add a Running App")) {
                        ForEach(candidates, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                                if let id = app.bundleIdentifier { add([AppException(bundleID: id)]) }
                            }
                        }
                    }
                    .fixedSize()
                    Button(L.t("Diğer…", "Other…")) { chooseApp() }
                    Menu(L.t("Hazır Ayar Ekle", "Add Preset")) {
                        Section(L.t("Sanal makineler ve uzak masaüstleri", "Virtual machines and remote desktops")) {
                            Button(L.t("Bu Mac'te Olanların Hepsi", "All Installed on This Mac")) {
                                add(AppException.presets.filter { presetsHere.contains($0.bundleID) }.map(\.exception))
                            }
                            .disabled(presetsHere.isEmpty)
                            ForEach(AppException.presets, id: \.bundleID) { preset in
                                Button(preset.name) { add([preset.exception]) }
                                    .disabled(prefs.appExceptions.contains { $0.coversSameApps(as: preset.exception) })
                            }
                        }
                    }
                    .fixedSize()
                    Spacer()
                }
                .settingsAnchor(SettingsAnchor.addException)
                Text(L.t("Önek, altındaki uygulamaları da kapsar: “com.microsoft”, “com.microsoft.Word” ile de eşleşir. Kısayollar bir uygulamaya bırakıldığında ⌘⇥ dahil hepsi doğrudan ona gider.",
                         "A prefix also covers the apps under it: “com.microsoft” matches “com.microsoft.Word” too. While an app has Riffle's shortcuts, all of them go straight to it, ⌘⇥ included."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            presetsHere = AppException.presets.filter { preset in
                preset.appIDs.contains { AppLookup.url($0) != nil }
                    || NSWorkspace.shared.runningApplications.contains { preset.exception.matches($0.bundleIdentifier) }
            }.map(\.bundleID)
        }
    }

    /// Finds its rule by id on every read and write: a section still on screen while its rule is deleted can't reach
    /// past the end of the list.
    private func binding(_ id: UUID) -> Binding<AppException> {
        Binding(get: { prefs.appExceptions.first { $0.id == id } ?? AppException(id: id, bundleID: "") },
                set: { exception in
                    guard let index = prefs.appExceptions.firstIndex(where: { $0.id == id }) else { return }
                    prefs.appExceptions[index] = exception
                })
    }

    private func add(_ exceptions: [AppException]) {
        prefs.appExceptions = AppException.adding(exceptions, to: prefs.appExceptions)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        add(panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }.map { AppException(bundleID: $0) })
    }
}

private struct ExceptionSection: View {
    @Binding var exception: AppException
    let remove: () -> Void

    var body: some View {
        Section {
            LabeledContent(L.t("Paket kimliği", "Bundle ID")) {
                HStack(spacing: 8) {
                    TextField("", text: $exception.bundleID, prompt: Text(verbatim: "com.example.app"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: 260)
                    Picker("", selection: $exception.matchesPrefix) {
                        Text(L.t("Tam", "Exact")).tag(false)
                        Text(L.t("Önek", "Prefix")).tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            .settingsAnchor(SettingsAnchor.exception(exception.id, "bundleID"))
            Picker(L.t("Panelde gizle", "Hide from the switcher"), selection: $exception.hiding) {
                Text(L.t("Hiçbir şeyi", "Nothing")).tag(AppException.Hiding.nothing)
                Text(L.t("Tüm pencerelerini", "All its windows")).tag(AppException.Hiding.allWindows)
                Text(L.t("Penceresi yokken uygulamayı", "The app while it has no windows")).tag(AppException.Hiding.whenWindowless)
                Text(L.t("Başlığında şu geçen pencereleri…", "Windows whose title contains…")).tag(AppException.Hiding.titleContains)
            }
            .settingsAnchor(SettingsAnchor.exception(exception.id, "hiding"))
            if exception.hiding == .titleContains {
                TextField(L.t("Başlıkta geçen metin", "Text in the title"), text: $exception.titleText)
            }
            Picker(L.t("Öndeyken Riffle'ın kısayollarını yok say", "Ignore Riffle's shortcuts while this app is in front"),
                   selection: $exception.ignoresShortcuts) {
                Text(L.t("Hiçbir zaman", "Never")).tag(AppException.ShortcutRule.never)
                Text(L.t("Her zaman", "Always")).tag(AppException.ShortcutRule.always)
                Text(L.t("Yalnızca tam ekrandayken", "Only in full screen")).tag(AppException.ShortcutRule.whileFullscreen)
            }
            .settingsAnchor(SettingsAnchor.exception(exception.id, "shortcuts"))
        } header: {
            HStack(spacing: 8) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                Text(name).font(.headline)
                Spacer()
                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(L.t("İstisnayı Sil", "Delete Exception"))
                .accessibilityLabel(L.t("İstisnayı Sil", "Delete Exception"))
            }
        }
    }

    private var preset: AppException.Preset? {
        AppException.presets.first { $0.exception.coversSameApps(as: exception) }
    }

    /// The app it's about: the identifier itself, a preset's app, or a running member of the family.
    private var appURL: URL? {
        let ids = (exception.matchesPrefix ? [] : [exception.bundleID]) + (preset?.appIDs ?? [])
        if let url = ids.lazy.compactMap(AppLookup.url).first { return url }
        guard exception.matchesPrefix else { return nil }
        return NSWorkspace.shared.runningApplications.first { exception.matches($0.bundleIdentifier) }?.bundleURL
    }

    private var name: String {
        if !exception.matchesPrefix, AppLookup.url(exception.bundleID) != nil { return AppLookup.name(exception.bundleID) }
        if !exception.name.isEmpty { return exception.name }
        let id = exception.bundleID.trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? L.t("Yeni istisna", "New exception") : id
    }

    private var icon: NSImage {
        appURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
