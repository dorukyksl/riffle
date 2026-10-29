import XCTest
@testable import Riffle

final class LocalizationHelperTests: XCTestCase {
    func testValuesLandWhereEachLanguagePutsThem() {
        let turkish = L.text("%2$@ içinde %1$@", "%1$@ in %2$@", in: .tr)
        let english = L.text("%2$@ içinde %1$@", "%1$@ in %2$@", in: .en)
        XCTAssertEqual(L.format(turkish, ["Notlar", "Masaüstü 2"]), "Masaüstü 2 içinde Notlar")
        XCTAssertEqual(L.format(english, ["Notes", "Desktop 2"]), "Notes in Desktop 2")
    }

    func testValuesAreWrittenAsTheyAre() {
        // Numbers aren't grouped or localized, and a % in a value is just a character.
        XCTAssertEqual(L.format("%1$@ / %2$@", [12_345, 1.5]), "12345 / 1.5")
        XCTAssertEqual(L.format("%1$@", ["100% %@"]), "100% %@")
    }

    func testFormatFollowsTheChosenLanguage() {
        let filled = L.f("%1$@ / %2$@ pencere", "%1$@ of %2$@ windows", 3, 12)
        XCTAssertEqual(filled, L.format(L.t("%1$@ / %2$@ pencere", "%1$@ of %2$@ windows"), [3, 12]))
        XCTAssertTrue(filled.contains("3") && filled.contains("12"))
    }

    func testEveryTranslatedFormatTakesEachValueOnce() {
        let placeholder = try! NSRegularExpression(pattern: "%(\\d+)\\$@")
        for language in AppLanguage.allCases {
            for (english, translation) in Translations.table(for: language) {
                let range = NSRange(english.startIndex..., in: english)
                let positions = Set(placeholder.matches(in: english, range: range).compactMap { Int((english as NSString).substring(with: $0.range(at: 1))) })
                guard let count = positions.max() else { continue }
                let markers = (1...count).map { "‹\($0)›" }
                let filled = L.format(translation, markers)
                for marker in markers {
                    XCTAssertEqual(filled.components(separatedBy: marker).count, 2, "\(language.rawValue): \(english) → \(translation)")
                }
                XCTAssertFalse(filled.contains("%@"), "\(language.rawValue): \(translation)")
            }
        }
    }

    func testMissingTranslationsFallBackToEnglish() {
        XCTAssertEqual(L.text("Henüz yok", "Not translated yet", in: .de), "Not translated yet")
        XCTAssertEqual(L.text("Henüz yok", "Not translated yet", in: .tr), "Henüz yok")
        XCTAssertEqual(L.text("Henüz yok", "Not translated yet", in: .en), "Not translated yet")
        XCTAssertTrue(Translations.table(for: .en).isEmpty)
        XCTAssertTrue(Translations.table(for: .tr).isEmpty)
    }

    func testMoreLanguageIdentifiers() {
        let cases: [(String, AppLanguage?)] = [
            ("en", .en), ("EN-us", .en), ("en_GB", .en), ("tr", .tr), ("ar-SA", .ar), ("sv-FI", .sv),
            ("zh", .zhCN), ("zh-SG", .zhCN), ("zh-Hant", .zhTW), ("zh-MO", .zhHK), ("zh-Hant-MO", .zhHK),
            ("pt", .ptBR), ("pt-BR", .ptBR), ("in", .id), ("id-ID", .id), ("he", .he),
            ("", nil), ("-", nil), ("nb-NO", nil), ("klingon", nil),
        ]
        for (identifier, language) in cases {
            XCTAssertEqual(AppLanguage.matching(identifier), language, identifier)
        }
    }

    func testThePickerListsEveryLanguageOnceLatinScriptsFirst() {
        let order = AppLanguage.pickerOrder
        XCTAssertEqual(order.count, AppLanguage.allCases.count)
        XCTAssertEqual(Set(order), Set(AppLanguage.allCases))
        let latin: Set<AppLanguage> = [.en, .tr, .de, .es, .fr, .id, .it, .nl, .pl, .ptBR, .sv, .vi]
        XCTAssertEqual(Set(order.prefix(latin.count)), latin)
        XCTAssertEqual(Set(AppLanguage.allCases.map(\.nativeName)).count, AppLanguage.allCases.count)
        XCTAssertEqual(AppLanguage.allCases.filter(\.isRightToLeft), [.ar, .he])
    }

    func testLanguagesSaveAsTheirCodes() throws {
        let data = try JSONEncoder().encode(AppLanguage.allCases)
        XCTAssertEqual(try JSONDecoder().decode([AppLanguage].self, from: data), AppLanguage.allCases)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode([AppLanguage.zhHK, .ptBR]), as: UTF8.self), #"["zh-HK","pt-BR"]"#)
    }

    func testSentencesJoinTheWayEachLanguageDoes() {
        XCTAssertEqual(L.sentences(["One.", "Two."], in: .en), "One. Two.")
        XCTAssertEqual(L.sentences(["Bir.", "", "İki."], in: .tr), "Bir. İki.")
        // Chinese and Japanese sentences end in 。 and follow each other without a space; Korean keeps its spaces.
        XCTAssertEqual(L.sentences(["设置未更改。", "请重试。"], in: .zhCN), "设置未更改。请重试。")
        XCTAssertEqual(L.sentences(["設定は変更されていません。", "もう一度。"], in: .ja), "設定は変更されていません。もう一度。")
        XCTAssertEqual(L.sentences(["설정이 바뀌지 않았습니다.", "다시 시도하세요."], in: .ko), "설정이 바뀌지 않았습니다. 다시 시도하세요.")
    }

    func testListsAreWrittenTheLanguagesWay() {
        XCTAssertEqual(L.list(["Style", "Size", "Theme"], in: .en), "Style, Size, and Theme")
        XCTAssertEqual(L.list(["Stil", "Boyut", "Tema"], in: .tr), "Stil, Boyut ve Tema")
        XCTAssertFalse(L.list(["样式", "大小", "主题"], in: .zhCN).contains(", "))
        XCTAssertEqual(L.list(["Style"], in: .en), "Style")
        XCTAssertEqual(L.list([], in: .en), "")
    }
}
