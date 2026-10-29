import Cocoa

/// `Riffle --diag-languages <folder> [code…]`: lays out Settings (every section), the welcome window and the switcher in
/// each language (all 21 by default) off screen and writes them as PNGs, to check that every translation fits. Uses
/// made-up windows and exceptions, and never touches the user's settings or window positions.
enum LanguageAudit {
    static func run(outputDirectory: String, codes: [String]) {
        let output = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        Prefs.persists = false
        let prefs = Prefs.shared
        prefs.size = .auto
        prefs.appExceptions = MockRender.exceptions
        let languages = codes.isEmpty ? AppLanguage.allCases : codes.compactMap(AppLanguage.matching)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { exit(1) }
        let ui = SwitcherUI()
        var steps = [() -> Void]()
        for language in languages {
            let folder = output.appendingPathComponent(language.rawValue)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            steps.append { prefs.language = language }
            for section in SettingsSection.allCases {
                steps.append { SettingsWindow.shared.show(section: section, offscreen: true) }
                steps.append { capture(SettingsWindow.shared.currentWindow, to: folder.appendingPathComponent("settings-\(section.rawValue).png")) }
            }
            steps += SettingsAudit.steps(into: folder)
            steps.append { OnboardingWindow.shared.show(offscreen: true) }
            steps.append {
                capture(OnboardingWindow.shared.currentWindow, to: folder.appendingPathComponent("onboarding.png"))
                OnboardingWindow.shared.currentWindow?.orderOut(nil)
            }
            for (name, style, query) in [("deck", SwitcherStyle.deck, ""), ("search", .deck, "s"), ("titles", .titles, ""), ("stage", .stage, "")] {
                steps.append {
                    prefs.style = style
                    let (items, badges) = MockRender.items(MockRender.samples, language: language)
                    let shown = query.isEmpty ? items : FuzzySearch.rank(items, query: query)
                    ui.prepareOffscreen(items: shown, selected: 1, searching: !query.isEmpty, query: query, screen: screen,
                                        appearance: NSAppearance(named: .darkAqua)!, badges: badges, total: items.count)
                }
                steps.append {
                    if let image = ui.captureOffscreen() { MockRender.write(image, folder.appendingPathComponent("switcher-\(name).png")) }
                }
            }
        }
        func next() {
            guard !steps.isEmpty else {
                SettingsWindow.shared.currentWindow?.orderOut(nil)
                print("language audit → \(output.path)")
                exit(0)
            }
            steps.removeFirst()()
            // A beat for SwiftUI and AppKit to lay the new content out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: next)
        }
        next()
    }

    /// The window as the WindowServer has it (SwiftUI content doesn't draw into a cached bitmap). Only Riffle's own
    /// windows are ever captured.
    private static func capture(_ window: NSWindow?, to url: URL) {
        guard let window, let image = PrivateAPI.captureWindow(CGWindowID(window.windowNumber)) else {
            Log.warn("language audit: no picture for \(url.lastPathComponent)")
            return
        }
        MockRender.write(image, url)
    }
}

/// `Riffle --diag-shortcut-editing <folder>`: edits shortcuts in a live (invisible) Settings window the way a person would:
/// adds up to nine, turns the last one on with another's keys, then deletes from the middle, the front and down to one,
/// writing a picture after each step. A crash in the list's updates shows up as a missing "done" line. Nothing is saved.
enum ShortcutEditingTest {
    static func run(outputDirectory: String) {
        let output = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        Prefs.persists = false
        let prefs = Prefs.shared
        prefs.profiles = Array(ShortcutProfile.defaults)
        var steps: [(String, () -> Void)] = [("start", { SettingsWindow.shared.show(section: .shortcuts, offscreen: true) })]
        for index in 0..<7 { steps.append(("add \(index + 1)", { prefs.addProfile() })) }
        steps.append(("ninth on, same keys as the first", {
            var profiles = prefs.profiles
            profiles[profiles.count - 1].holdModifiers = profiles[0].holdModifiers
            profiles[profiles.count - 1].keyCode = profiles[0].keyCode
            profiles[profiles.count - 1].isEnabled = true
            prefs.profiles = profiles
            ShortcutStatus.shared.duplicates = [profiles[profiles.count - 1].id]
        }))
        steps.append(("remove a middle one", { prefs.removeProfile(id: prefs.profiles[4].id) }))
        steps.append(("remove the first", { prefs.removeProfile(id: prefs.profiles[0].id) }))
        steps.append(("remove down to one", { while prefs.profiles.count > 1 { prefs.removeProfile(id: prefs.profiles[prefs.profiles.count - 1].id) } }))
        steps.append(("remove the last (refused)", { prefs.removeProfile(id: prefs.profiles[0].id) }))
        var number = 0
        func next() {
            guard !steps.isEmpty else {
                SettingsWindow.shared.currentWindow?.orderOut(nil)
                print("done: \(prefs.profiles.count) shortcut(s) left")
                exit(0)
            }
            let (name, step) = steps.removeFirst()
            step()
            number += 1
            let count = prefs.profiles.count
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let window = SettingsWindow.shared.currentWindow, let image = PrivateAPI.captureWindow(CGWindowID(window.windowNumber)) {
                    MockRender.write(image, output.appendingPathComponent(String(format: "%02d-%@.png", number, name.replacingOccurrences(of: " ", with: "-"))))
                }
                print("\(name): \(count) shortcut(s)")
                next()
            }
        }
        next()
    }
}
