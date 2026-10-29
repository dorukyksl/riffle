import Cocoa
import SwiftUI

/// Live permission state for the welcome window and Settings → Permissions; looks once a second while one is open (and
/// tells `PermissionMonitor`, so Riffle acts on a change at once).
final class PermissionState: ObservableObject {
    @Published private(set) var accessibility = PermissionState.simulated?.accessibility ?? Permissions.accessibility
    @Published private(set) var screenRecording = PermissionState.simulated?.screenRecording ?? Permissions.screenRecording
    /// Screen Recording was given while Riffle ran: previews come after a restart.
    @Published private(set) var needsRestart = PermissionState.simulated?.needsRestart ?? PermissionMonitor.shared.tracker.needsRestart
    /// For the language audit's pictures: shown instead of the real permissions, everywhere.
    static var simulated: (accessibility: Bool, screenRecording: Bool, needsRestart: Bool)?
    private var timer: Timer?

    func start() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let now = PermissionState.simulated ?? {
            let tracker = PermissionMonitor.shared.check()
            return (Permissions.accessibility, Permissions.screenRecording, tracker.needsRestart)
        }()
        if now.accessibility != accessibility { accessibility = now.accessibility }
        if now.screenRecording != screenRecording { screenRecording = now.screenRecording }
        if now.needsRestart != needsRestart { needsRestart = now.needsRestart }
    }
}

/// What the welcome window, Settings → Permissions and the menu bar say about previews.
enum PermissionText {
    /// What previews need, and that Riffle is complete without them.
    static var previewsNeed: String {
        L.t("Önizlemeler için Ekran ve Sistem Sesi Kaydı izni gerekir. Riffle onsuz da eksiksiz çalışır; kartlarda önizlemelerin yerine uygulama simgeleri görünür.",
            "Previews need Screen & System Audio Recording. Riffle works fully without it, showing app icons in place of previews.")
    }

    static var turnOnLater: String {
        L.t("Önizlemeleri sonra Ayarlar → İzinler'den açabilirsin.", "You can turn previews on later in Settings → Permissions.")
    }

    static var howToTurnOn: String {
        L.t("Açmak için İzin Ver…'e tıkla, Sistem Ayarları'nda Riffle'ı aç, sonra Riffle'ı yeniden başlat.",
            "To turn them on, click Grant…, switch Riffle on in System Settings, then restart Riffle.")
    }

    static var restartForPreviews: String {
        L.t("Önizlemeler, Riffle yeniden başlayınca açılır.", "Previews turn on once Riffle restarts.")
    }
}

final class OnboardingWindow: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindow()
    private var window: NSWindow?
    private let state = PermissionState()

    /// The holds its shortcut picker offers, in this order: ⌥ first, as a new setup has it.
    static let holdChoices: [CarbonModifiers] = [.option, .command]

    /// `offscreen`: for the language audit, invisible and never activated.
    func show(offscreen: Bool = false) {
        if window == nil {
            let hosting = NSHostingController(rootView: OnboardingView(state: state, close: { [weak self] in self?.close() },
                                                                       continueWithoutPreviews: { [weak self] in self?.continueWithoutPreviews() }))
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = L.t("Riffle'a hoş geldin", "Welcome to Riffle")
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        state.start()
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

    /// The title follows the language setting.
    func updateTitle() {
        window?.title = L.t("Riffle'a hoş geldin", "Welcome to Riffle")
    }

    func close() {
        Prefs.shared.hasCompletedOnboarding = true
        window?.close()
    }

    /// Riffle without Screen Recording: done here, and not asked for previews again at every launch.
    func continueWithoutPreviews() {
        Prefs.shared.continuesWithoutPreviews = true
        close()
    }

    func windowWillClose(_ notification: Notification) {
        state.stop()
        // Closing it counts as done once everything it asks for is in place; otherwise it comes back next launch.
        if OnboardingWindow.isDone(accessibility: Permissions.accessibility, screenRecording: Permissions.screenRecording,
                                   withoutPreviews: Prefs.shared.continuesWithoutPreviews) {
            Prefs.shared.hasCompletedOnboarding = true
        }
    }

    /// Whether it opens at launch: until it's been done, while Accessibility is missing, and while previews are neither
    /// on nor declined.
    static func isNeeded(accessibility: Bool, screenRecording: Bool, completed: Bool, withoutPreviews: Bool) -> Bool {
        !completed || !isDone(accessibility: accessibility, screenRecording: screenRecording, withoutPreviews: withoutPreviews)
    }

    /// Everything it asks for is in place: Accessibility, and previews on or declined.
    static func isDone(accessibility: Bool, screenRecording: Bool, withoutPreviews: Bool) -> Bool {
        accessibility && (screenRecording || withoutPreviews)
    }
}

private struct OnboardingView: View {
    @ObservedObject var state: PermissionState
    @ObservedObject private var prefs = Prefs.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    let close: () -> Void
    let continueWithoutPreviews: () -> Void

    private var shortcut: String { prefs.profiles.first?.description ?? "⌥⇥" }

    private var hold: CarbonModifiers { prefs.profiles.first?.holdModifiers ?? .option }

    private var shortcutNote: String {
        prefs.profiles.first?.usesCommandTab == true
            ? L.t("Riffle, macOS'un kendi ⌘⇥ değiştiricisinin yerini alır ve kapanınca onu geri açar.",
                  "Riffle takes over macOS's own ⌘⇥ switcher and gives it back when it quits.")
            : L.t("macOS'un kendi ⌘⇥ değiştiricisi olduğu gibi kalır.", "macOS keeps its own ⌘⇥ switcher.")
    }

    /// The two everyday shortcuts (all windows, this app's windows) share one hold key.
    private func setHold(_ modifiers: CarbonModifiers) {
        var profiles = prefs.profiles
        for index in profiles.indices.prefix(2) { profiles[index].holdModifiers = modifiers }
        prefs.profiles = profiles
    }
    private var needsRestart: Bool { state.needsRestart }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.t("Riffle'a hoş geldin", "Welcome to Riffle"))
                        .font(.system(size: 24, weight: .bold))
                    Text(L.f("Pencereler arasında %1$@ ile ışık hızında geçiş. Riffle'ın çalışması için Erişilebilirlik izni gerekir, önizlemeler için bir izin daha. Riffle'ın gördüğü hiçbir şey bu Mac'ten dışarı çıkmaz.",
                             "Lightning-fast window switching with %1$@. Riffle needs Accessibility to work, and one more permission for previews. What Riffle sees never leaves this Mac.", shortcut))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 10) {
                PermissionRow(symbol: "hand.raised.fill", tint: .blue,
                              title: L.t("Erişilebilirlik", "Accessibility"),
                              detail: L.t("Pencereleri bulmak, öne getirmek ve kısayol tuşunun bırakıldığını anlamak için.",
                                          "To find windows, bring them forward and notice when you let go of the shortcut."),
                              granted: state.accessibility) {
                    Permissions.requestAccessibility()
                    Permissions.openAccessibilitySettings()
                }
                PermissionRow(symbol: "rectangle.inset.filled.on.rectangle", tint: .purple,
                              title: L.t("Ekran ve Sistem Sesi Kaydı", "Screen & System Audio Recording"),
                              detail: L.t("Canlı pencere önizlemeleri için. Ses kaydedilmez, hiçbir görüntü saklanmaz ya da gönderilmez.",
                                          "For live window thumbnails. No audio is recorded; nothing is saved or sent."),
                              granted: state.screenRecording) {
                    Permissions.requestScreenRecording()
                    Permissions.openScreenRecordingSettings()
                }
                if !state.screenRecording {
                    Text(L.sentences([PermissionText.previewsNeed, PermissionText.turnOnLater]))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(L.t("Kısayol", "Shortcut")).font(.headline)
                    Spacer()
                    // Whichever one you're used to: ⌥⇥ leaves macOS's ⌘⇥ alone, ⌘⇥ takes its place. Other keys are in Settings.
                    // Written the way macOS writes shortcuts, which reads the same in every language.
                    Picker(L.t("Kısayol", "Shortcut"), selection: Binding(get: { hold.rawValue },
                                                                        set: { setHold(CarbonModifiers(rawValue: $0)) })) {
                        ForEach(OnboardingWindow.holdChoices, id: \.rawValue) { choice in
                            Text(KeyCodes.shortcutDescription(modifiers: choice, keyCode: KeyCodes.tab))
                                .accessibilityLabel(KeyCodes.spokenDescription(modifiers: choice, keyCode: KeyCodes.tab))
                                .tag(choice.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Text(shortcutNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(L.t("Mac açılınca Riffle'ı başlat", "Start Riffle when you log in"), isOn: Binding(
                get: { launchAtLogin },
                set: { LoginItem.set($0); launchAtLogin = LoginItem.isEnabled }))
                .toggleStyle(.checkbox)

            HStack {
                if state.accessibility && state.screenRecording {
                    Label(L.f("Hazırsın! %1$@ ile dene.", "You're set! Try %1$@.", shortcut), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.callout.weight(.semibold))
                }
                Spacer()
                if needsRestart || (!state.screenRecording && state.accessibility) {
                    Button(L.t("Riffle'ı Yeniden Başlat", "Restart Riffle")) { Relauncher.relaunch() }
                        .help(L.t("Ekran kaydı izni yeniden başlattıktan sonra etkinleşir.", "Screen recording takes effect after a restart."))
                }
                // Previews are optional: with Accessibility, the way on is right here.
                if state.accessibility && !state.screenRecording {
                    Button(L.t("Önizlemeler Olmadan Devam Et", "Continue Without Previews"), action: continueWithoutPreviews)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L.t("Bitti", "Done"), action: close)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .padding(.top, 8)
        .frame(width: 560)
        .localized(prefs.language)
    }
}

private struct PermissionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                // Some languages name these panes at length: wrap rather than cut them off.
                Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Label(L.t("Verildi", "Granted"), systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .font(.callout.weight(.semibold))
                    .fixedSize()
            } else {
                Button(L.t("İzin Ver…", "Grant…"), action: action)
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
