import Cocoa

/// The language audit's pictures of what Settings search, export, import and reset add: the sidebar while searching, a
/// result brought into view, General's notices and the new dialogs. Runs offscreen, and saves nothing (the audit doesn't
/// persist settings).
enum SettingsAudit {
    private static var alert: NSAlert?

    static func steps(into folder: URL) -> [() -> Void] {
        let prefs = Prefs.shared
        let navigation = SettingsWindow.shared.navigationState
        var steps = [() -> Void]()
        func capture(_ window: NSWindow?, _ name: String) {
            guard let window, let image = PrivateAPI.captureWindow(CGWindowID(window.windowNumber)) else {
                Log.warn("language audit: no picture for \(name)")
                return
            }
            MockRender.write(image, folder.appendingPathComponent(name))
        }
        func searchStep(_ query: @escaping () -> String, _ name: String) {
            steps.append {
                SettingsWindow.shared.show(section: .general, offscreen: true)
                navigation.query = query()
            }
            steps.append { capture(SettingsWindow.shared.currentWindow, name) }
        }

        // The sidebar while searching, for a word of this language.
        searchStep({ L.t("Tema", "Theme").lowercased() }, "settings-search.png")
        // A result far down its section: it's brought into view and lit up.
        steps.append {
            navigation.query = "vim"
            let index = SettingsSearch.index(profiles: prefs.profiles, exceptions: prefs.appExceptions)
            if let entry = SettingsSearch.results(for: navigation.query, in: index).first { navigation.open(entry) }
        }
        // Time for the section to lay out and the scroll to finish.
        steps.append {}
        steps.append {}
        steps.append {}
        steps.append { capture(SettingsWindow.shared.currentWindow, "settings-search-result.png") }
        steps.append {
            navigation.query = ""
            navigation.open(.general)
        }

        // General with both notices.
        steps.append {
            let stamp = SettingsFiles.stamp(Date())
            prefs.recoveredSettings = [RecoveredSetting(key: "profiles", file: "profiles-\(stamp).json"),
                                       RecoveredSetting(key: "theme", file: "theme-\(stamp).json")]
            prefs.previousSettings = PreviousSettings(file: "settings-\(stamp).json", reason: .reset)
            SettingsWindow.shared.show(section: .general, offscreen: true)
        }
        steps.append {
            capture(SettingsWindow.shared.currentWindow, "settings-general-notices.png")
            prefs.recoveredSettings = []
            prefs.previousSettings = nil
        }

        // The welcome window and Settings → Permissions with Accessibility but no Screen Recording, and once Screen
        // Recording was given meanwhile (whatever this Mac has).
        let states: [(String, (accessibility: Bool, screenRecording: Bool, needsRestart: Bool))] = [
            ("without-previews", (true, false, false)), ("restart", (true, true, true)),
        ]
        for (name, permissions) in states {
            steps.append {
                PermissionState.simulated = permissions
                OnboardingWindow.shared.show(offscreen: true)
                SettingsWindow.shared.show(section: .about, offscreen: true)
            }
            steps.append {
                capture(OnboardingWindow.shared.currentWindow, "onboarding-\(name).png")
                OnboardingWindow.shared.currentWindow?.orderOut(nil)
                SettingsWindow.shared.show(section: .permissions, offscreen: true)
            }
            steps.append {
                capture(SettingsWindow.shared.currentWindow, "settings-permissions-\(name).png")
                PermissionState.simulated = nil
            }
        }

        // The dialogs.
        var sample = prefs.snapshot
        sample.profiles = Array(sample.profiles.prefix(2))
        let archive = SettingsArchive(settings: sample, appVersion: SettingsArchive.thisAppVersion)
        let dialogs: [(String, () -> NSAlert)] = [
            ("dialog-reset.png", SettingsTransfer.resetConfirmation),
            ("dialog-import.png", {
                SettingsTransfer.preview(archive, changes: [.language(from: .tr, to: .en), .general, .shortcuts(from: 3, to: 2), .panelKeys,
                                                            .appearance, .exceptions(from: 0, to: 4)],
                                         file: L.t("Riffle Ayarları", "Riffle Settings") + ".json")
            }),
            ("dialog-import-damaged.png", { SettingsTransfer.refusal(.damaged(.panelKeys)) }),
            ("dialog-import-newer.png", { SettingsTransfer.refusal(.newerFormat(appVersion: "2.0 (200)")) }),
            ("dialog-import-incomplete.png", { SettingsTransfer.refusal(.incomplete([.language, .panelKeys])) }),
        ]
        for (name, make) in dialogs {
            steps.append {
                let shown = make()
                shown.layout()
                // Out of sight: under the desktop picture, where the WindowServer still draws it.
                shown.window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
                shown.window.orderBack(nil)
                alert = shown
            }
            steps.append {
                capture(alert?.window, name)
                alert?.window.orderOut(nil)
                alert = nil
            }
        }
        return steps
    }
}
