import XCTest
@testable import Riffle

/// Riffle reads its translations from the Swift tables `Scripts/l10n.py generate` writes, not from the JSON they're made
/// from: a translation fixed in the JSON only reaches anyone once the tables are generated again.
final class TranslationTableTests: XCTestCase {
    func testTheCompiledTablesSayWhatTheirJSONSays() throws {
        let strings = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Localization", isDirectory: true)
        var compared = 0
        for language in AppLanguage.allCases where language != .tr && language != .en {
            let data = try Data(contentsOf: strings.appendingPathComponent(language.rawValue + ".json"))
            let json = try JSONDecoder().decode([String: String].self, from: data)
            let table = Translations.table(for: language)
            let differing = Set(json.keys).union(table.keys).filter { json[$0] != table[$0] }.sorted()
            XCTAssertTrue(differing.isEmpty, "\(language.rawValue): \(differing.count) strings differ from the JSON, "
                          + "\(differing.prefix(3)): run `python3 Scripts/l10n.py generate`")
            compared += json.count
        }
        XCTAssertGreaterThan(compared, 19 * 100)
    }
}
