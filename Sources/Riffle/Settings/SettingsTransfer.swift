import Cocoa
import SwiftUI
import UniformTypeIdentifiers

/// Settings → General → All Settings: export to a file, import one (after showing what it would change), reset all, and
/// the way back from an import or a reset. The current settings go to Backups before they're replaced. Main thread.
enum SettingsTransfer {
    // MARK: - Actions

    static func export(from window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = L.t("Riffle Ayarları", "Riffle Settings") + ".json"
        present(panel, in: window) { url in
            do {
                try SettingsArchive(settings: Prefs.shared.snapshot).encoded().write(to: url, options: .atomic)
                Log.info("settings exported")
            } catch {
                show(failure(L.t("Ayarlar dışa aktarılamadı", "The settings couldn't be exported"), detail: error.localizedDescription), in: window)
            }
        }
    }

    /// Reads the file, refuses it as a whole if anything is wrong with it, shows what it would change, then replaces
    /// every setting at once.
    static func importSettings(into window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        present(panel, in: window) { url in
            switch SettingsArchive.read(contentsOf: url) {
            case .failure(let problem):
                Log.warn("settings import refused: \(problem)")
                show(refusal(problem), in: window)
            case .success(let archive):
                let changes = Prefs.shared.snapshot.changes(to: archive.settings)
                guard !changes.isEmpty else { return show(sameSettings(), in: window) }
                show(preview(archive, changes: changes, file: url.lastPathComponent), in: window) { response in
                    guard response == .alertFirstButtonReturn else { return }
                    if !replaceAll(with: archive.settings, because: .imported) { show(backupFailure(), in: window) }
                }
            }
        }
    }

    static func confirmReset(in window: NSWindow?) {
        show(resetConfirmation(), in: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            if !replaceAll(with: .defaults(), because: .reset) { show(backupFailure(), in: window) }
        }
    }

    static func restorePrevious(in window: NSWindow?) {
        guard let problem = restorePrevious() else { return }
        show(refusal(problem, title: L.t("Önceki ayarlar geri yüklenemedi", "The previous settings couldn't be restored")), in: window)
    }

    /// Keeps the current settings in `backups`, then puts `settings` in place all at once and offers the backup back.
    /// False, and nothing changed, when the backup can't be written.
    @discardableResult
    static func replaceAll(with settings: SettingsSnapshot, because reason: PreviousSettings.Reason,
                           backups: URL = SettingsFiles.backups) -> Bool {
        let prefs = Prefs.shared
        guard let data = try? SettingsArchive(settings: prefs.snapshot).encoded(),
              let backup = SettingsFiles.write(data, name: SettingsArchive.backupName, in: backups) else { return false }
        SettingsFiles.pruneBackups(in: backups)
        prefs.apply(settings)
        prefs.previousSettings = PreviousSettings(file: backup.lastPathComponent, reason: reason)
        Log.info("settings \(reason == .reset ? "reset" : "imported"); the previous ones are in \(backup.lastPathComponent)")
        return true
    }

    /// Puts back the settings from before the last reset or import, and forgets that backup. What's wrong with the backup
    /// if it can't be (then nothing changes).
    static func restorePrevious(from backups: URL = SettingsFiles.backups) -> SettingsArchive.Problem? {
        let prefs = Prefs.shared
        guard let previous = prefs.previousSettings else { return nil }
        switch SettingsArchive.read(contentsOf: backups.appendingPathComponent(previous.file)) {
        case .success(let archive):
            prefs.apply(archive.settings)
            prefs.previousSettings = nil
            Log.info("settings restored from \(previous.file)")
            return nil
        case .failure(let problem):
            return problem
        }
    }

    // MARK: - Dialogs

    static func resetConfirmation() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L.t("Tüm ayarlar sıfırlansın mı?", "Reset all settings?")
        alert.informativeText = L.t("Kısayollar, panel tuşları, istisnalar, görünüm ve genel ayarlar ile dil varsayılanlarına döner. Önce şimdiki ayarların yedeklenir; istersen geri yükleyebilirsin. İzinler ve girişte başlatma olduğu gibi kalır.",
                                    "Your shortcuts, switcher keys, exceptions, appearance and general settings, and the language, go back to their defaults. Your current settings are backed up first, so you can restore them. Permissions and launch at login stay as they are.")
        let reset = alert.addButton(withTitle: L.t("Sıfırla", "Reset"))
        reset.hasDestructiveAction = true
        // Return keeps everything: resetting takes a click.
        reset.keyEquivalent = ""
        alert.addButton(withTitle: L.t("Vazgeç", "Cancel")).keyEquivalent = "\r"
        return alert
    }

    static func preview(_ archive: SettingsArchive, changes: [SettingsChange], file: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L.f("“%1$@” içe aktarılsın mı?", "Import “%1$@”?", file)
        let lines = changes.map { "•  " + describe($0) } + ["", L.sentences([origin(of: archive), L.t("Şimdiki ayarların önce yedeklenir.", "Your current settings are backed up first.")])]
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: L.t("İçe Aktar", "Import"))
        alert.addButton(withTitle: L.t("Vazgeç", "Cancel"))
        return alert
    }

    static func refusal(_ problem: SettingsArchive.Problem, title: String? = nil) -> NSAlert {
        failure(title ?? L.t("Bu dosya içe aktarılamıyor", "This file can't be imported"),
                detail: L.sentences([explanation(of: problem), L.t("Ayarların değişmedi.", "Your settings weren't changed.")]))
    }

    private static func backupFailure() -> NSAlert {
        failure(L.t("Yedek kaydedilemedi", "The backup couldn't be saved"), detail: L.t("Ayarların değişmedi.", "Your settings weren't changed."))
    }

    private static func sameSettings() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L.t("Bu dosyadaki ayarlar şimdikilerle aynı", "The settings in this file are the same as yours")
        alert.addButton(withTitle: L.t("Tamam", "OK"))
        return alert
    }

    private static func failure(_ title: String, detail: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: L.t("Tamam", "OK"))
        return alert
    }

    static func describe(_ change: SettingsChange) -> String {
        switch change {
        case let .shortcuts(from, to):
            return from == to ? L.f("Kısayollar: %1$@, ayarları değişiyor", "Shortcuts: %1$@, with new settings", to)
                : L.f("Kısayollar: %1$@ → %2$@", "Shortcuts: %1$@ → %2$@", from, to)
        case let .exceptions(from, to):
            return from == to ? L.f("İstisnalar: %1$@, ayarları değişiyor", "Exceptions: %1$@, with new settings", to)
                : L.f("İstisnalar: %1$@ → %2$@", "Exceptions: %1$@ → %2$@", from, to)
        case .panelKeys:
            return L.t("Panel tuşları değişiyor", "Switcher keys change")
        case .appearance:
            return L.t("Görünüm ayarları değişiyor", "Appearance settings change")
        case .general:
            return L.t("Genel ayarlar değişiyor", "General settings change")
        case let .language(from, to):
            return L.f("Dil: %1$@ → %2$@", "Language: %1$@ → %2$@", from.nativeName, to.nativeName)
        }
    }

    /// Where the file came from: "Exported from Riffle 1.4 (52) on 12 Oct 2026 at 14:30."
    static func origin(of archive: SettingsArchive) -> String {
        guard let date = archive.exportedAt else {
            return L.f("Riffle %1$@ ile dışa aktarıldı.", "Exported from Riffle %1$@.", archive.appVersion)
        }
        let formatter = DateFormatter()
        formatter.locale = Prefs.shared.language.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return L.f("Riffle %1$@ ile %2$@ tarihinde dışa aktarıldı.", "Exported from Riffle %1$@ on %2$@.", archive.appVersion,
                   formatter.string(from: date))
    }

    static func explanation(of problem: SettingsArchive.Problem) -> String {
        switch problem {
        case .unreadableFile:
            return L.t("Dosya okunamadı.", "The file couldn't be read.")
        case .notJSON:
            return L.t("Dosya bozuk ya da bir Riffle ayar dosyası değil.", "The file is damaged, or isn't a Riffle settings file.")
        case .notSettings:
            return L.t("Bu bir Riffle ayar dosyası değil.", "This isn't a Riffle settings file.")
        case .newerFormat(let version):
            return L.f("Dosya, Riffle'ın daha yeni bir sürümüyle kaydedilmiş: %1$@. İçe aktarmak için Riffle'ı güncelle.",
                       "The file was saved by a newer version of Riffle: %1$@. Update Riffle to import it.", version ?? "?")
        case .incomplete(let keys):
            return L.f("Dosya eksik; içinde şunlar yok: %1$@.", "The file is incomplete; it's missing: %1$@.",
                       L.list(keys.map { name(of: $0.rawValue) }))
        case .damaged(let key?):
            return L.f("Dosya bozuk: “%1$@” okunamıyor.", "The file is damaged: “%1$@” can't be read.", name(of: key.rawValue))
        case .damaged(nil):
            return L.t("Dosya bozuk.", "The file is damaged.")
        case .shortcutWithoutHold:
            return L.t("Dosyadaki bir kısayolda basılı tutulacak ⌃, ⌥ ya da ⌘ yok: tuşu her uygulamada yazı yazmak yerine pencere değiştirirdi.",
                       "A shortcut in the file has no ⌃, ⌥ or ⌘ to hold: its key would switch windows in every app instead of typing.")
        }
    }

    /// What Settings calls a stored setting.
    static func name(of key: String) -> String {
        switch key {
        case "profiles": return L.t("Kısayollar", "Shortcuts")
        case "style": return L.t("Stil", "Style")
        case "size": return L.t("Boyut", "Size")
        case "theme": return L.t("Tema", "Theme")
        case "glass": return L.t("Cam", "Glass")
        case "screen": return L.t("Panelin gösterileceği ekran", "Show the switcher on")
        case "language": return L.t("Dil", "Language")
        case "showDelayMs": return L.t("Görünme gecikmesi", "Appearance delay")
        case "showBadges": return L.t("Durum rozetlerini göster (küçültülmüş, gizli, tam ekran)", "Show status badges (minimized, hidden, full screen)")
        case "showSpaceNumbers": return L.t("Başka masaüstündeki pencerelerde masaüstü numarasını göster", "Show the desktop number for windows on other desktops")
        case "previewSelectedWindow": return L.t("Seçili pencereyi yerinde önizle", "Preview the selected window in place")
        case "titleContent": return L.t("Başlık", "Title")
        case "titleTruncation": return L.t("Uzun başlıkları kısalt", "Truncate long titles")
        case "pointerFollowsSwitch": return L.t("İmleci, geçtiğin pencerenin ortasına taşı", "Move the pointer to the middle of the window you switch to")
        case "panelAnimations": return L.t("Panel animasyonları", "Switcher animations")
        case "mouseHoverSelects": return L.t("Fareyle üzerine gelince seç", "Select on mouse hover")
        case "hapticFeedback": return L.t("Seçim değişince hafif dokunsal geri bildirim", "Subtle haptic feedback on selection")
        case "showMenuBarIcon": return L.t("Menü çubuğunda göster", "Show in menu bar")
        case "appExceptions", "excludedBundleIDs": return L.t("İstisnalar", "Exceptions")
        case "panelKeys": return L.t("Panel tuşları", "Switcher keys")
        case "shortcutsPaused": return L.t("Kısayolları Duraklat", "Pause Shortcuts")
        default: return key
        }
    }

    // MARK: - Presenting

    private static func present(_ panel: NSSavePanel, in window: NSWindow?, then use: @escaping (URL) -> Void) {
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            // The panel's sheet is still closing: the next dialog waits a turn.
            DispatchQueue.main.async { use(url) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    private static func show(_ alert: NSAlert, in window: NSWindow?, then handle: ((NSApplication.ModalResponse) -> Void)? = nil) {
        if let window {
            alert.beginSheetModal(for: window) { response in handle?(response) }
        } else {
            let response = alert.runModal()
            handle?(response)
        }
    }
}

// MARK: - Notices in General

/// Settings → General, at the top: stored settings that couldn't be read at launch, until dismissed.
struct RecoveredSettingsNotice: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        if !prefs.recoveredSettings.isEmpty {
            Section {
                NoticeRow(symbol: "exclamationmark.triangle.fill", tint: .orange,
                          title: L.t("Bazı ayarlar okunamadı", "Some settings couldn't be read"),
                          detail: L.f("Varsayılana dönen ayarlar: %1$@. Okunamayan değerler, Recovered klasöründe saklandı.",
                                      "Back to their defaults: %1$@. The values that couldn't be read were kept in the Recovered folder.",
                                      names))
                HStack {
                    Spacer()
                    Button(L.t("Finder'da Göster", "Show in Finder")) {
                        reveal(prefs.recoveredSettings.map { SettingsFiles.recovered.appendingPathComponent($0.file) }, in: SettingsFiles.recovered)
                    }
                    Button(L.t("Tamam", "OK")) { prefs.recoveredSettings = [] }
                }
            }
        }
    }

    private var names: String {
        var seen = Set<String>()
        return L.list(prefs.recoveredSettings.map { SettingsTransfer.name(of: $0.key) }.filter { seen.insert($0).inserted })
    }
}

/// Settings → General, at the top: the way back from the last reset or import, until dismissed.
struct PreviousSettingsNotice: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        if let previous = prefs.previousSettings {
            Section {
                NoticeRow(symbol: "arrow.uturn.backward.circle.fill", tint: .accentColor,
                          title: previous.reason == .reset ? L.t("Tüm ayarlar sıfırlandı", "All settings were reset")
                              : L.t("Ayarlar içe aktarıldı", "Settings were imported"),
                          detail: L.t("Önceki ayarların bir yedeğe kaydedildi; istersen geri yükleyebilirsin.",
                                      "Your previous settings were saved in a backup, so you can restore them."))
                HStack {
                    Spacer()
                    Button(L.t("Finder'da Göster", "Show in Finder")) { reveal([SettingsFiles.backups.appendingPathComponent(previous.file)], in: SettingsFiles.backups) }
                    Button(L.t("Önceki Ayarları Geri Yükle", "Restore Previous Settings")) {
                        SettingsTransfer.restorePrevious(in: SettingsWindow.shared.currentWindow)
                    }
                    Button(L.t("Tamam", "OK")) { prefs.previousSettings = nil }
                }
            }
        }
    }
}

private struct NoticeRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// Shows the files that are still there, or else their folder.
private func reveal(_ files: [URL], in folder: URL) {
    let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
    if existing.isEmpty {
        NSWorkspace.shared.open(folder)
    } else {
        NSWorkspace.shared.activateFileViewerSelecting(existing)
    }
}
