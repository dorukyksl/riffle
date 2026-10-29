import XCTest
@testable import Riffle

final class SettingsSearchTests: XCTestCase {
    private var language = AppLanguage.en
    private var persisted = true

    override func setUp() {
        persisted = Prefs.persists
        Prefs.persists = false
        language = Prefs.shared.language
    }

    override func tearDown() {
        Prefs.shared.language = language
        Prefs.persists = persisted
    }

    /// Shortcuts whose sections between them show every heading there is.
    private let profiles: [ShortcutProfile] = {
        func profile(_ id: Int, _ apps: AppScope, _ place: PlaceScope, search: Bool = false) -> ShortcutProfile {
            var profile = ShortcutProfile(id: id, isEnabled: true, holdModifiers: .option, keyCode: UInt32(18 + id))
            profile.apps = apps
            profile.place = place
            profile.startInSearch = search
            return profile
        }
        return [profile(0, .allApps, .allDesktops), profile(1, .allApps, .thisDesktop), profile(2, .allApps, .thisScreen),
                profile(3, .activeApp, .allDesktops), profile(4, .otherApps, .allDesktops), profile(5, .appUnderPointer, .allDesktops),
                profile(6, .activeApp, .thisDesktop, search: true), profile(7, .otherApps, .thisScreen)]
    }()

    /// An exception for an app, and a new one with no identifier yet.
    private let exceptions = [AppException(bundleID: "com.example.notes", name: "Notes"), AppException(bundleID: "")]

    private func index(in language: AppLanguage, profiles: [ShortcutProfile]? = nil) -> [SettingsSearchEntry] {
        Prefs.shared.language = language
        return SettingsSearch.index(profiles: profiles ?? self.profiles, exceptions: exceptions)
    }

    // MARK: - Every label can be found

    /// Words in Settings that aren't a row to find: the window and its search field, keys being recorded and what
    /// VoiceOver says for their buttons, warnings and notes that come and go, the shortcut count, and pieces of a
    /// shortcut's heading.
    private let notLabels: Set<String> = [
        "Riffle Settings", "Search Settings", "No Results",
        "Press a key…", "Press the keys…", "Press a key: ⌫ removes it, ⎋ cancels", "No key",
        "Shortcut key: %1$@", "Keys to hold: %1$@", "Key for “%1$@”: %2$@",
        "%1$@ of %2$@", " · this desktop", " · this screen", " · search",
        "Another Riffle shortcut already uses these keys, so this one doesn't work. Pick other keys.",
        "Another app already uses this shortcut (%1$@).",
        "%1$@ no longer does “%2$@”; you can give that command another key.",
        "Can't turn on Vim keys: %1$@ is used for “%2$@”. Give it another key first.",
        "%1$@ already has a fixed job in the switcher. Pick another key.", "%1$@ is the key of a Riffle shortcut. Pick another key.",
        "%1$@ is one of the Vim keys. Pick another key.", "%1$@ is already used for “%2$@”. Pick another key.",
    ]

    /// Files with no Settings rows in them: the dialogs and notices of export, import and reset, and the audit's pictures.
    private let filesWithoutRows: Set<String> = ["SettingsTransfer.swift", "SettingsAudit.swift"]

    /// Every Turkish and English pair written in a Settings source file.
    private func settingsStrings() throws -> [(file: String, turkish: String, english: String, isFormat: Bool)] {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Riffle/Settings", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !filesWithoutRows.contains($0.lastPathComponent) }
        XCTAssertGreaterThan(files.count, 5)
        let call = try NSRegularExpression(pattern: #"\bL\.(t|f)\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)""#)
        func unescaped(_ text: String) -> String {
            text.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: "\\")
        }
        var strings = [(file: String, turkish: String, english: String, isFormat: Bool)]()
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in call.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let part = { (index: Int) in String(source[Range(match.range(at: index), in: source)!]) }
                strings.append((file.lastPathComponent, unescaped(part(2)), unescaped(part(3)), part(1) == "f"))
            }
        }
        XCTAssertGreaterThan(strings.count, 150)
        return strings
    }

    /// Whether `text` is one of the words of the index (a label, a keyword or a context), or the name of a section.
    private func isIndexed(_ text: String, isFormat: Bool, in entries: [SettingsSearchEntry]) -> Bool {
        if SettingsSection.allCases.contains(where: { $0.title == text }) { return true }
        let words = Set(entries.flatMap { [$0.label] + $0.keywords + ($0.context.map { [$0] } ?? []) })
        guard isFormat else { return words.contains(text) }
        // A text with values in it: any of them, filled in.
        let marked = text.replacingOccurrences(of: #"%\d\$@"#, with: "\u{1}", options: .regularExpression)
        let pattern = "^" + NSRegularExpression.escapedPattern(for: marked).replacingOccurrences(of: "\u{1}", with: ".+") + "$"
        return words.contains { $0.range(of: pattern, options: .regularExpression) != nil }
    }

    func testEveryLabelInSettingsCanBeFound() throws {
        let strings = try settingsStrings()
        for language in [AppLanguage.en, .tr] {
            let entries = index(in: language)
            for string in strings where !notLabels.contains(string.english) {
                let text = language == .tr ? string.turkish : string.english
                XCTAssertTrue(isIndexed(text, isFormat: string.isFormat, in: entries),
                              "\(string.file): “\(text)” isn't in the Settings search index (add it there, or to notLabels if it isn't a label)")
                // And typing it finds it.
                if !string.isFormat, !SettingsSection.allCases.contains(where: { $0.title == text }) {
                    XCTAssertFalse(SettingsSearch.results(for: text, in: entries).isEmpty, "\(language.rawValue): searching “\(text)” finds nothing")
                }
            }
        }
    }

    func testTheAllowListHasNoLabelsLeftOver() throws {
        let english = Set(try settingsStrings().map(\.english))
        for text in notLabels { XCTAssertTrue(english.contains(text), "“\(text)” isn't in Settings anymore: take it off notLabels") }
    }

    func testEverySectionHasRowsAndEveryRowItsOwnPlace() {
        let entries = index(in: .en)
        for section in SettingsSection.allCases { XCTAssertTrue(entries.contains { $0.section == section }, section.rawValue) }
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count, "two entries are the same")
        // Every row of the views Riffle owns says where it is; Appearance's rows get theirs from its own file.
        for entry in entries where entry.section != .appearance { XCTAssertNotNil(entry.anchor, entry.label) }
    }

    // MARK: - Matching

    private func labels(_ query: String, in entries: [SettingsSearchEntry]) -> [String] {
        SettingsSearch.results(for: query, in: entries).map { $0.path.joined(separator: " › ") }
    }

    func testCaseAccentsAndTheTurkishIDontMatter() {
        let entries = index(in: .tr)
        XCTAssertEqual(labels("kisayol ekle", in: entries).first, "Kısayollar › Kısayol Ekle")
        XCTAssertEqual(labels("GORUNME", in: entries).first, "Genel › Görünme gecikmesi")
        XCTAssertEqual(labels("dokunsal", in: entries), ["Genel › Seçim değişince hafif dokunsal geri bildirim"])
        XCTAssertEqual(labels("İZİNLER", in: entries), [])
        XCTAssertEqual(SettingsSearch.sections(for: "izinler", results: []), [.permissions])
        XCTAssertEqual(SettingsSearch.sections(for: "ISTISNA", results: []), [.exclusions])
    }

    func testAShortcutsRowsAreFoundOncePerShortcut() {
        let entries = index(in: .en, profiles: ShortcutProfile.defaults)
        let order = labels("order", in: entries)
        XCTAssertEqual(order, ShortcutProfile.defaults.map { "Shortcuts › \($0.description) › Order" })
        // The section narrows a search down, but doesn't find rows on its own.
        XCTAssertEqual(labels("shortcuts order", in: entries), order)
        XCTAssertFalse(labels("shortcuts", in: entries).contains { $0.hasSuffix("› Order") })
        XCTAssertEqual(SettingsSearch.sections(for: "shortcuts", results: SettingsSearch.results(for: "shortcuts", in: entries)).first, .shortcuts)
    }

    func testLabelsComeBeforeKeywords() {
        let entries = index(in: .en)
        let theme = labels("theme", in: entries)
        XCTAssertEqual(theme.first, "Appearance › Theme")
        XCTAssertEqual(labels("dark", in: entries), ["Appearance › Theme"])
        // Word starts before words that merely contain it.
        let show = labels("show", in: entries)
        XCTAssertEqual(show.first, "General › Show in menu bar")
        XCTAssertTrue(labels("glass", in: entries).starts(with: ["Appearance › Glass"]))
        XCTAssertEqual(labels("", in: entries), [])
        XCTAssertEqual(labels("   ", in: entries), [])
        XCTAssertEqual(labels("no such setting", in: entries), [])
    }

    func testExceptionsAreToldApartByTheirApp() {
        let entries = index(in: .en)
        XCTAssertTrue(labels("bundle id", in: entries).contains("Exceptions › Notes › Bundle ID"))
        XCTAssertTrue(labels("com.example.notes", in: entries).contains("Exceptions › Notes"))
        XCTAssertTrue(labels("parallels", in: entries).contains("Exceptions › Add Preset"))
        // With no exceptions yet, their rows lead to where one is added.
        Prefs.shared.language = .en
        let none = SettingsSearch.index(profiles: profiles, exceptions: [])
        let bundle = SettingsSearch.results(for: "bundle id", in: none)
        XCTAssertEqual(bundle.map(\.anchor), [SettingsAnchor.addException])
    }

    func testEveryLanguageFindsItsOwnLabels() {
        for language in AppLanguage.allCases {
            let entries = index(in: language, profiles: [ShortcutProfile.defaults[0]])
            XCTAssertGreaterThan(entries.count, 60)
            for entry in entries {
                let found = SettingsSearch.results(for: entry.label, in: entries)
                XCTAssertTrue(found.contains(entry), "\(language.rawValue): “\(entry.label)” doesn't find itself")
            }
        }
    }
}
