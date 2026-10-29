import Carbon
import Cocoa
import SwiftUI

// MARK: - A shortcut's keys

/// Records one key (no modifiers), through `KeyRecording`: one recorder at a time, with Riffle's global shortcuts let go
/// meanwhile so they can't swallow it. A key the switcher itself listens for is refused, and it says why next to it.
struct KeyRecorder: View {
    @Binding var keyCode: UInt32
    @ObservedObject private var session = KeyRecording.shared
    @State private var id = UUID()
    @State private var problem: String?

    private var isRecording: Bool { session.recorder == id }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                isRecording ? session.stop(id) : start()
            } label: {
                Text(isRecording ? L.t("Bir tuşa bas…", "Press a key…") : KeyCodes.name(for: keyCode))
                    .frame(minWidth: 70)
                    .font(.system(.body, design: .rounded).weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)
            .accessibilityLabel(KeyRecorder.spokenLabel(for: keyCode))
            .accessibilityValue(isRecording ? L.t("Bir tuşa bas…", "Press a key…") : "")
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: keyCode) { problem = nil }
        .onDisappear { session.stop(id) }
    }

    /// What VoiceOver says for it: what it records, and the key it has.
    static func spokenLabel(for keyCode: UInt32) -> String {
        L.f("Kısayol tuşu: %1$@", "Shortcut key: %1$@", KeyCodes.spokenName(for: keyCode))
    }

    private func start() {
        problem = nil
        let id = self.id
        session.start(id, events: .keyDown) { event in
            if Int(event.keyCode) != kVK_Escape { record(UInt32(event.keyCode)) }
            session.stop(id)
            return nil
        }
    }

    private func record(_ key: UInt32) {
        let layout = KeyboardLayout.current
        if let conflict = Prefs.shared.panelKeys.conflict(shortcutKey: key, on: layout) {
            problem = conflict.refusal(of: KeyCodes.name(for: key, on: layout))
        } else {
            keyCode = key
        }
    }
}

/// The keys held while pressing a shortcut's key: click, then press any of ⌃ ⌥ ⌘ together (⇧ is for going backwards)
/// and let go; or pick a combination from the menu. Shows the keys as printed on the keyboard, whatever the Mac's
/// Modifier Keys settings make them send. Records through `KeyRecording`, as `KeyRecorder` does.
struct HoldRecorder: View {
    @Binding var modifiers: CarbonModifiers
    @ObservedObject private var session = KeyRecording.shared
    @State private var id = UUID()
    /// Held right now (keys as printed), shown while recording.
    @State private var pressed = CarbonModifiers()

    private var isRecording: Bool { session.recorder == id }

    private var label: String {
        guard isRecording else { return modifiers.symbols }
        return pressed.isEmpty ? L.t("Tuşlara bas…", "Press the keys…") : pressed.symbols
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(L.t("Basılı tut", "Hold"))
            Menu {
                ForEach(CarbonModifiers.holdChoices, id: \.rawValue) { choice in
                    Button(choice.symbols) {
                        session.stop(id)
                        modifiers = choice
                    }
                    .accessibilityLabel(choice.spokenNames.joined(separator: " "))
                }
            } label: {
                Text(label)
                    .frame(minWidth: 44)
                    .font(.system(.body, design: .rounded).weight(.semibold))
            } primaryAction: {
                isRecording ? session.stop(id) : start()
            }
            .tint(isRecording ? .accentColor : nil)
            .fixedSize()
            .accessibilityLabel(HoldRecorder.spokenLabel(for: modifiers))
            .accessibilityValue(isRecording ? label : "")
        }
        .onDisappear { session.stop(id) }
    }

    /// What VoiceOver says for it: what it records, and the keys it has.
    static func spokenLabel(for modifiers: CarbonModifiers) -> String {
        L.f("Basılı tutulacak tuşlar: %1$@", "Keys to hold: %1$@", modifiers.spokenNames.joined(separator: " "))
    }

    private func start() {
        pressed = []
        var capture = HoldCapture()
        let id = self.id
        session.start(id, events: [.flagsChanged, .keyDown]) { event in
            if event.type == .keyDown {
                if Int(event.keyCode) == kVK_Escape { session.stop(id) }
                return nil
            }
            let hold = capture.update(sent: CarbonModifiers(eventFlags: event.modifierFlags))
            pressed = capture.held
            if let hold {
                modifiers = hold
                session.stop(id)
            }
            return event
        }
    }
}

extension PanelKeyConflict {
    /// Why a key was refused, for Settings to show: `key` is its name.
    func refusal(of key: String) -> String {
        switch self {
        case .fixed:
            return L.f("%1$@ panelde sabit bir iş görüyor. Başka bir tuş seç.", "%1$@ already has a fixed job in the switcher. Pick another key.", key)
        case .shortcut:
            return L.f("%1$@ bir Riffle kısayolunun tuşu. Başka bir tuş seç.", "%1$@ is the key of a Riffle shortcut. Pick another key.", key)
        case .vimKeys:
            return L.f("%1$@ Vim tuşlarından biri. Başka bir tuş seç.", "%1$@ is one of the Vim keys. Pick another key.", key)
        case .taken(let owner):
            return L.f("%1$@ zaten “%2$@” için kullanılıyor. Başka bir tuş seç.", "%1$@ is already used for “%2$@”. Pick another key.",
                       key, owner.name)
        }
    }
}

/// What letting go of the hold key does, for one shortcut. A search-first shortcut stays open anyway: nothing to pick.
struct ReleaseBehaviorPicker: View {
    @Binding var profile: ShortcutProfile

    var body: some View {
        if !profile.startInSearch {
            Picker(L.t("Tuşları bırakınca", "When you let go"), selection: $profile.releaseBehavior) {
                Text(L.t("Seçili pencereye geç", "Switch to the selected window")).tag(ReleaseBehavior.switchToSelected)
                Text(L.t("Paneli açık tut", "Keep the switcher open")).tag(ReleaseBehavior.keepOpen)
                Text(L.t("Paneli açık tut ve ara", "Keep it open and search")).tag(ReleaseBehavior.keepOpenAndSearch)
            }
            .settingsAnchor(SettingsAnchor.shortcut(profile.id, "release"))
        }
    }
}

// MARK: - While the switcher is open

struct KeyReferenceRow: View {
    let keys: String
    let text: String

    var body: some View {
        HStack {
            Text(keys)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .frame(width: 110, alignment: .leading)
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

/// The keys that work inside the switcher: the fixed ones for reference, and the one-key commands, each with the key
/// it has on the current layout, to be changed by clicking it and pressing another.
struct PanelKeysSection: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var session = KeyRecording.shared
    @State private var id = UUID()
    /// The command whose key is being recorded, while `session` says this section records.
    @State private var recording: PanelKey?
    @State private var problem: String?
    /// Bumped when the input source changes: the keys' names (and the defaults) follow the layout.
    @State private var layoutChanges = 0

    private var shortcutKeys: Set<UInt32> { Set(prefs.profiles.filter(\.isEnabled).map(\.keyCode)) }

    var body: some View {
        let _ = layoutChanges
        let layout = KeyboardLayout.current
        let keys = prefs.panelKeys.resolved(on: layout)
        Section {
            KeyReferenceRow(keys: "⇧", text: L.t("Basılı tutarken geri git", "Hold to go backwards"))
                .settingsAnchor(SettingsAnchor.panelKey("backwards"))
            KeyReferenceRow(keys: "← → ↑ ↓", text: L.t("Seçimi taşı", "Move the selection"))
                .settingsAnchor(SettingsAnchor.panelKey("move"))
            KeyReferenceRow(keys: "↩  /  " + L.t("tık", "click"), text: L.t("Seçili pencereye geç", "Switch to the selected window"))
                .settingsAnchor(SettingsAnchor.panelKey("switch"))
            KeyReferenceRow(keys: "1 … 9", text: L.t("O sıradaki pencereye anında geç", "Jump straight to that window"))
                .settingsAnchor(SettingsAnchor.panelKey("jump"))
            commandRow([.search, .searchAlternate], keys)
            commandRow([.close], keys)
            commandRow([.minimize], keys)
            commandRow([.fullscreen], keys)
            commandRow([.hide], keys)
            commandRow([.quit], keys)
            KeyReferenceRow(keys: "⎋", text: L.t("Vazgeç (aramadayken önce aramayı temizler)", "Cancel (clears the search first)"))
                .settingsAnchor(SettingsAnchor.panelKey("cancel"))
            Toggle(isOn: Binding(get: { prefs.panelKeys.vimKeys }, set: { setVimKeys($0, on: layout) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t("Vim tuşları", "Vim keys"))
                    Text(vimCaption(on: layout))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .settingsAnchor(SettingsAnchor.panelKey("vim"))
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(L.t("Panel açıkken", "While the switcher is open"))
        } footer: {
            if !prefs.panelKeys.custom.isEmpty {
                HStack {
                    Spacer()
                    Button(L.t("Varsayılan Tuşlara Dön", "Restore Default Keys")) {
                        stopRecording()
                        problem = nil
                        prefs.panelKeys.custom = [:]
                    }
                }
            }
        }
        .onDisappear { stopRecording() }
        .onReceive(DistributedNotificationCenter.default().publisher(
            for: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String))) { _ in
            layoutChanges += 1
        }
    }

    private func isRecording(_ slot: PanelKey) -> Bool {
        session.recorder == id && recording == slot
    }

    private func commandRow(_ slots: [PanelKey], _ keys: PanelKeyMap) -> some View {
        let isRecording = slots.contains(where: isRecording)
        return HStack {
            HStack(spacing: 4) {
                ForEach(slots, id: \.self) { slot in
                    recorderButton(slot, label: keys.slots[slot]?.label)
                }
            }
            .frame(width: 110, alignment: .leading)
            Text(isRecording ? L.t("Bir tuşa bas: ⌫ tuşu kaldırır, ⎋ vazgeçer", "Press a key: ⌫ removes it, ⎋ cancels") : slots[0].title)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .settingsAnchor(SettingsAnchor.panelKey(slots[0].rawValue))
    }

    private func recorderButton(_ slot: PanelKey, label: String?) -> some View {
        let isRecording = isRecording(slot)
        return Button {
            isRecording ? stopRecording() : startRecording(slot)
        } label: {
            Text(isRecording ? "…" : label ?? "—")
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .foregroundStyle(label == nil && !isRecording ? .secondary : .primary)
                .frame(minWidth: 16)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isRecording ? .accentColor : nil)
        .accessibilityLabel(PanelKeysSection.spokenLabel(for: slot, key: label))
        .accessibilityValue(isRecording ? L.t("Bir tuşa bas: ⌫ tuşu kaldırır, ⎋ vazgeçer", "Press a key: ⌫ removes it, ⎋ cancels") : "")
    }

    /// What VoiceOver says for a command's key button: the command, and its key as Settings shows it (nil: none).
    static func spokenLabel(for slot: PanelKey, key: String?) -> String {
        L.f("“%1$@” tuşu: %2$@", "Key for “%1$@”: %2$@", slot.name, key ?? L.t("Tuş yok", "No key"))
    }

    private func vimCaption(on layout: KeyboardLayout?) -> String {
        let caption = L.t("H J K L de seçimi taşır.", "H J K L move the selection too.")
        var without = prefs.panelKeys
        without.vimKeys = false
        let before = without.resolved(on: layout)
        let notes = prefs.panelKeys.displacedByVimKeys(on: layout).map { slot in
            L.f("%1$@ artık “%2$@” için kullanılmıyor; ona başka bir tuş verebilirsin.",
                "%1$@ no longer does “%2$@”; you can give that command another key.", before.slots[slot]?.label ?? "?", slot.name)
        }
        return L.sentences([caption] + notes)
    }

    private func setVimKeys(_ on: Bool, on layout: KeyboardLayout?) {
        stopRecording()
        problem = nil
        if on, let slot = prefs.panelKeys.vimConflicts(on: layout).first, case .key(let keyCode)? = prefs.panelKeys.custom[slot] {
            // A key picked by hand is never taken away silently.
            problem = L.f("Vim tuşları açılamadı: %1$@, “%2$@” için kullanılıyor. Önce ona başka bir tuş ver.",
                          "Can't turn on Vim keys: %1$@ is used for “%2$@”. Give it another key first.",
                          KeyCodes.name(for: keyCode, on: layout), slot.name)
            return
        }
        prefs.panelKeys.vimKeys = on
    }

    private func startRecording(_ slot: PanelKey) {
        problem = nil
        recording = slot
        let id = self.id
        session.start(id, events: .keyDown) { event in
            record(event, for: slot)
            session.stop(id)
            return nil
        }
    }

    private func record(_ event: NSEvent, for slot: PanelKey) {
        let keyCode = UInt32(event.keyCode)
        let layout = KeyboardLayout.current
        switch Int(event.keyCode) {
        case kVK_Escape:
            return
        case kVK_Delete:
            prefs.panelKeys.assign(nil, to: slot, on: layout)
            return
        default:
            break
        }
        guard let conflict = prefs.panelKeys.conflict(assigning: keyCode, to: slot, on: layout, shortcutKeys: shortcutKeys) else {
            prefs.panelKeys.assign(keyCode, to: slot, on: layout)
            return
        }
        problem = conflict.refusal(of: KeyCodes.name(for: keyCode, on: layout))
    }

    private func stopRecording() {
        session.stop(id)
    }
}
