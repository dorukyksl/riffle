import AppKit
import XCTest
@testable import Riffle

final class SearchRankingTests: XCTestCase {
    private func item(_ app: String, _ title: String, wid: CGWindowID) -> SwitcherItem {
        SwitcherItem(kind: .window(wid), pid: 1, appName: app, title: title, icon: NSImage(), isMinimized: false, isHidden: false,
                     isFullscreen: false, otherSpaceIndex: nil, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), bundleID: nil)
    }

    private func ranked(_ items: [SwitcherItem], _ query: String) -> [CGWindowID] {
        FuzzySearch.rank(items, query: query).compactMap(\.wid)
    }

    private func tier(_ word: String, _ text: String) -> FuzzySearch.Tier? {
        FuzzySearch.match(word, in: text)?.tier
    }

    private func positions(_ word: String, _ text: String) -> [Int]? {
        FuzzySearch.match(word, in: text)?.positions
    }

    // MARK: - Tiers

    func testTiersRankBestFirst() {
        let titles = ["Mial", "Mapping Tools", "Mozilla Add-In Launcher", "Gmail", "Apple Mail Settings", "Mailbox", "Mail"]
        let tiers: [FuzzySearch.Tier] = [.typo, .subsequence, .initials, .substring, .wordStart, .prefix, .exact]
        for (title, expected) in zip(titles, tiers) {
            XCTAssertEqual(tier("mail", title), expected, title)
        }
        // Worst first in, best first out.
        let items = titles.enumerated().map { item("Notes", $1, wid: CGWindowID($0 + 1)) }
        XCTAssertEqual(ranked(items, "mail"), [7, 6, 5, 4, 3, 2, 1])
    }

    func testEachTier() {
        XCTAssertEqual(tier("safari", "Safari"), .exact)
        XCTAssertEqual(tier("saf", "Safari"), .prefix)
        XCTAssertEqual(tier("studio", "Visual Studio Code"), .wordStart)
        XCTAssertEqual(tier("hub", "GitHub Desktop"), .wordStart)
        XCTAssertEqual(tier("udi", "Visual Studio Code"), .substring)
        XCTAssertEqual(tier("vsc", "Visual Studio Code"), .initials)
        XCTAssertEqual(tier("vscode", "Visual Studio Code"), .initials)
        XCTAssertEqual(tier("ghd", "GitHub Desktop"), .initials)
        XCTAssertEqual(tier("fsm", "file_system-monitor.swift"), .initials)
        XCTAssertEqual(tier("hp", "HTMLParser"), .initials)
        XCTAssertEqual(tier("trml", "Terminal"), .subsequence)
        XCTAssertEqual(tier("chorme", "Google Chrome"), .typo)
        XCTAssertNil(tier("zebra", "Google Chrome"))
    }

    func testInitialsPreferConsecutiveWords() {
        // "gc" fits "Google … Chrome" and "Google Chrome"; the adjacent pair wins and is what lights up.
        XCTAssertEqual(positions("gc", "Google Search — Google Chrome"), [16, 23])
        let items = [item("Notes", "Grocery list and Cake", wid: 1), item("Notes", "Grocery Cake", wid: 2)]
        XCTAssertEqual(ranked(items, "gc"), [2, 1])
    }

    func testAppNameWinsATieWithTheTitle() {
        let result = FuzzySearch.rank([item("Calculator", "Calculator", wid: 1)], query: "calc")
        XCTAssertEqual(result.first?.appNameMatches, [0, 1, 2, 3])
        XCTAssertEqual(result.first?.titleMatches, [])
    }

    func testWholeWordsBeatPartialWords() {
        let items = [item("Notes", "Mailspring setup", wid: 1), item("Notes", "Mail setup", wid: 2)]
        XCTAssertEqual(ranked(items, "mail"), [2, 1])
    }

    // MARK: - Typos

    func testTypos() {
        XCTAssertEqual(tier("chorme", "Google Chrome"), .typo)      // swapped neighbours
        XCTAssertEqual(tier("safiri", "Safari"), .typo)             // a wrong letter
        XCTAssertEqual(tier("safarri", "Safari"), .typo)            // an extra letter
        XCTAssertEqual(tier("xafari", "Safari"), .typo)             // even the first one
        XCTAssertEqual(tier("mial", "Mail"), .typo)                 // four letters are enough
        XCTAssertEqual(tier("githbu", "GitHub — riffle"), .typo)    // camelCase words stay whole
        XCTAssertNotNil(FuzzySearch.match("safri", in: "Safari"))   // a missing letter is still in order
        // Two edits from eight letters, one below.
        XCTAssertEqual(tier("fotoshop", "Adobe Photoshop"), .typo)
        XCTAssertNil(tier("fotoshp", "Adobe Photoshop"))
        XCTAssertNil(tier("chrmoee", "Google Chrome"))
        // No typos for short words or numbers.
        XCTAssertNil(tier("teh", "The Verge"))
        XCTAssertNil(tier("2025", "Report 2024"))
    }

    func testTyposWhileStillTyping() {
        // From five letters a typo also matches the start of a longer word…
        XCTAssertEqual(tier("chorm", "Google Chrome"), .typo)
        XCTAssertEqual(tier("gihtu", "GitHub"), .typo)
        // …but not at four, where too many words are one letter away from any start.
        XCTAssertNil(tier("chor", "Google Chrome"))
        XCTAssertNil(tier("term", "Microsoft Teams"))
    }

    func testTyposRankLast() {
        let items = [item("Google Chrome", "New Tab", wid: 1), item("Notes", "chorme extension ideas", wid: 2)]
        XCTAssertEqual(ranked(items, "chorme"), [2, 1])
        let close = [item("Notes", "Safiri trip", wid: 1), item("Notes", "Safari trip", wid: 2)]
        XCTAssertEqual(ranked(close, "safari"), [2, 1])
    }

    // MARK: - Multi-word

    func testWordsMatchEitherField() {
        let items = [item("Google Chrome", "GitHub — riffle", wid: 1), item("Google Chrome", "YouTube", wid: 2),
                     item("Safari", "GitHub — riffle", wid: 3)]
        let result = FuzzySearch.rank(items, query: "chrome github")
        XCTAssertEqual(result.compactMap(\.wid), [1])
        XCTAssertEqual(result.first?.appNameMatches, Array(7..<13))
        XCTAssertEqual(result.first?.titleMatches, Array(0..<6))
        XCTAssertEqual(ranked(items, "github chrome"), [1])
        XCTAssertEqual(ranked(items, "chorme github"), [1])
        // An input method's ideographic space separates words too.
        XCTAssertEqual(ranked(items, "chrome\u{3000}github"), [1])
    }

    func testTurkishWordsAcrossFields() {
        let items = [item("Notlar", "İSTANBUL gezisi", wid: 1), item("Notlar", "Ankara", wid: 2), item("Mail", "İstanbul", wid: 3)]
        let result = FuzzySearch.rank(items, query: "notlar istanbul")
        XCTAssertEqual(result.compactMap(\.wid), [1])
        XCTAssertEqual(result.first?.appNameMatches, Array(0..<6))
        XCTAssertEqual(result.first?.titleMatches, Array(0..<8))
    }

    func testWholePhraseWins() {
        // Word by word "Tabby / New window" scores higher; read together, "New Tab" is the window meant.
        let items = [item("Tabby", "New window", wid: 1), item("Safari", "New Tab", wid: 2), item("Safari", "Tab New", wid: 3)]
        XCTAssertEqual(ranked(items, "new tab").first, 2)
        XCTAssertEqual(ranked([item("Google Chrome Canary", "", wid: 1), item("Google Chrome", "", wid: 2)], "google chrome"), [2, 1])
    }

    // MARK: - Turkish

    func testTurkishFolding() {
        XCTAssertEqual(tier("istanbul", "İSTANBUL"), .exact)
        XCTAssertEqual(tier("İSTANBUL", "istanbul"), .exact)
        XCTAssertEqual(tier("ılık", "Ilık"), .exact)
        XCTAssertEqual(tier("ILIK", "ılık"), .exact)
        XCTAssertEqual(tier("goruntu", "Görüntü ayarları"), .prefix)
        XCTAssertEqual(tier("ayarlari", "Görüntü ayarları"), .wordStart)
        XCTAssertEqual(tier("seker", "ŞEKER"), .exact)
        XCTAssertEqual(tier("cagri", "Çağrı Merkezi"), .prefix)
        XCTAssertEqual(positions("istanbul", "İSTANBUL"), Array(0..<8))
        XCTAssertEqual(positions("goruntu", "Görüntü"), Array(0..<7))
        // macOS file names are often decomposed; highlights still count characters.
        XCTAssertEqual(positions("goruntu", "Görüntü.png".decomposedStringWithCanonicalMapping), Array(0..<7))
    }

    func testFoldingKeepsOtherAlphabets() {
        XCTAssertEqual(String(FuzzySearch.fold("Straße ﬁle Ærø Łódź")), "strasse file aero lodz")
        XCTAssertEqual(String(FuzzySearch.fold("ＣＨＲＯＭＥ １２")), "chrome 12")
        XCTAssertEqual(String(FuzzySearch.fold("Привет Ёлка Мой Київ")), "привет елка мой київ")
        XCTAssertEqual(String(FuzzySearch.fold("ΚΑΛΗΜΈΡΑ κόσμος")), "καλημερα κοσμοσ")
        XCTAssertEqual(String(FuzzySearch.fold("สวัสดีชาวโลก")), "สวัสดีชาวโลก")
        XCTAssertEqual(String(FuzzySearch.fold("क्षमा करें")), "क्षमा करें")
        XCTAssertEqual(String(FuzzySearch.fold("ダウンロード 東京")), "ダウンロード 東京")
        XCTAssertEqual(String(FuzzySearch.fold("ﾀﾞｳﾝﾛｰﾄﾞ")), "ダウンロード")
        XCTAssertEqual(String(FuzzySearch.fold("한글".decomposedStringWithCanonicalMapping)), "한글")
        XCTAssertEqual(String(FuzzySearch.fold("مَرْحَبًا أحمد")), "مرحبا احمد")
        XCTAssertEqual(String(FuzzySearch.fold("שָׁלוֹם")), "שלום")
    }

    // MARK: - Other scripts

    func testChineseAndJapanese() {
        XCTAssertEqual(positions("文件传输", "微信 - 文件传输助手"), [5, 6, 7, 8])
        // Written without spaces, so a word can begin anywhere — even for two characters.
        XCTAssertEqual(tier("東京", "明日の東京の天気 - Google 検索"), .wordStart)
        XCTAssertEqual(positions("天気", "明日の東京の天気"), [6, 7])
        XCTAssertEqual(tier("京", "東京"), .wordStart)
        XCTAssertNil(tier("京東", "東京の天気"))
        XCTAssertNil(tier("東天", "東京の天気"))
        XCTAssertEqual(tier("ダウン", "ダウンロード"), .prefix)
        XCTAssertNil(tier("タウン", "ダウンロード"))
        XCTAssertEqual(positions("ダウン", "ﾀﾞｳﾝﾛｰﾄﾞ"), [0, 1, 2])
        XCTAssertEqual(positions("ｄｏｃｓ", "Google Docs"), [7, 8, 9, 10])
    }

    func testKorean() {
        XCTAssertEqual(positions("문서", "한글 문서 - 메모장"), [3, 4])
        XCTAssertEqual(tier("한글", "한글".decomposedStringWithCanonicalMapping), .exact)
        XCTAssertEqual(tier("시청", "서울시청"), .wordStart)
        XCTAssertNil(tier("문자", "한글 문서"))
    }

    func testThaiAndDevanagari() {
        let thai = "สวัสดีชาวโลก"
        XCTAssertEqual(positions("ชาวโลก", thai), [4, 5, 6, 7, 8, 9])
        // A cluster still being typed — a consonant waiting for its vowel sign — already matches.
        XCTAssertEqual(positions("สวั", thai), [0, 1])
        XCTAssertEqual(positions("ก", "กินข้าว"), [0])
        XCTAssertNil(tier("ดีใจ", thai))
        XCTAssertEqual(tier("क्", "क्षमा करें"), .prefix)
        XCTAssertEqual(positions("करें", "क्षमा करें"), [3, 4])
        XCTAssertNil(tier("नमस्ते", "क्षमा करें"))
    }

    func testArabicAndHebrew() {
        XCTAssertEqual(tier("بالعالم", "مرحبا بالعالم"), .wordStart)
        XCTAssertEqual(tier("العالم", "مرحبا بالعالم"), .substring)
        XCTAssertEqual(tier("مرحبا", "مَرْحَبًا"), .exact)
        XCTAssertEqual(tier("احمد", "أحمد"), .exact)
        XCTAssertNil(tier("سلام", "مرحبا بالعالم"))
        XCTAssertEqual(positions("עולם", "שלום עולם"), [5, 6, 7, 8])
        XCTAssertEqual(positions("שלום", "שָׁלוֹם"), [0, 1, 2, 3])
        XCTAssertNil(tier("תודה", "שלום עולם"))
    }

    func testCyrillicAndGreek() {
        XCTAssertEqual(tier("яндекс", "Привет, мир — Яндекс"), .wordStart)
        XCTAssertEqual(positions("ПРИВЕТ", "Привет, мир — Яндекс"), Array(0..<6))
        XCTAssertEqual(tier("елка", "Ёлка"), .exact)
        XCTAssertNil(tier("мои", "Мой компьютер"))
        XCTAssertEqual(tier("мой", "Мой компьютер"), .prefix)
        XCTAssertEqual(tier("кмопьютер", "Мой компьютер"), .typo)
        XCTAssertEqual(tier("καλημερα", "Καλημέρα κόσμε"), .prefix)
        XCTAssertEqual(tier("κοσμος", "ΚΟΣΜΟΣ"), .exact)
    }

    func testInvisibleCharactersAreIgnored() {
        // Direction marks around a chat name, a soft hyphen, Arabic tatweel: still exact, and highlights skip them.
        XCTAssertEqual(tier("robin", "\u{200E}Robin\u{200F}"), .exact)
        XCTAssertEqual(positions("robin", "\u{200E}Robin\u{200F}"), [1, 2, 3, 4, 5])
        XCTAssertEqual(tier("cooperate", "co\u{00AD}operate"), .exact)
        XCTAssertEqual(tier("مرحبا", "مـرحبا"), .exact)
    }

    // MARK: - Short queries

    func testShortQueriesOnlyMatchWordStarts() {
        XCTAssertNil(tier("s", "Mesajlar"))
        XCTAssertNil(tier("ar", "Calendar"))
        XCTAssertNil(tier("tl", "Terminal"))
        XCTAssertNil(tier("ai", "Mail"))
        XCTAssertEqual(tier("ar", "Archive Utility"), .prefix)
        XCTAssertEqual(tier("ut", "Archive Utility"), .wordStart)
        XCTAssertEqual(tier("au", "Archive Utility"), .initials)
        XCTAssertEqual(tier("gh", "GitHub"), .initials)
        XCTAssertEqual(tier("x", "X"), .exact)
        XCTAssertEqual(tier("b", "Plan B"), .wordStart)
        let items = [item("Terminal", "", wid: 1), item("Mail", "", wid: 2), item("Finder", "Recents", wid: 3),
                     item("Microsoft Excel", "Budget", wid: 4), item("Notes", "Shopping — e-mail drafts", wid: 5)]
        XCTAssertEqual(Set(ranked(items, "e")), [4, 5])
        XCTAssertEqual(ranked(items, "re"), [3])
    }

    func testShortWordsInLongerQueriesStayQuiet() {
        let items = [item("Safari", "Settings", wid: 1), item("Safari", "GitHub", wid: 2)]
        XCTAssertEqual(ranked(items, "safari g"), [2])
        XCTAssertEqual(ranked(items, "safari gs"), [])
    }

    // MARK: - Stability

    func testEqualScoresKeepMostRecentFirst() {
        let items = [item("Terminal", "robin — zsh", wid: 1), item("Terminal", "robin — swift build", wid: 2),
                     item("Terminal", "robin — vim", wid: 3)]
        XCTAssertEqual(ranked(items, "robin"), [1, 2, 3])
        XCTAssertEqual(ranked(items.reversed(), "robin"), [3, 2, 1])
        XCTAssertEqual(ranked(items, "term"), [1, 2, 3])
        // A longer title is not a worse match.
        let projects = [item("Xcode", "Project Alpha Beta Gamma", wid: 1), item("Xcode", "Project Alpha", wid: 2)]
        XCTAssertEqual(ranked(projects, "proj"), [1, 2])
        XCTAssertEqual(ranked(projects.reversed(), "proj"), [2, 1])
        let same = (1...5).map { item("Safari", "Start Page", wid: CGWindowID($0)) }
        XCTAssertEqual(ranked(same, "start"), [1, 2, 3, 4, 5])
    }

    // MARK: - Highlights

    func testHighlightsForEveryTier() {
        XCTAssertEqual(positions("mail", "Mail"), [0, 1, 2, 3])
        XCTAssertEqual(positions("mai", "Mailbox"), [0, 1, 2])
        XCTAssertEqual(positions("mail", "Apple Mail Settings"), [6, 7, 8, 9])
        XCTAssertEqual(positions("mail", "Gmail"), [1, 2, 3, 4])
        XCTAssertEqual(positions("mail", "Mozilla Add-In Launcher"), [0, 8, 12, 15])
        XCTAssertEqual(positions("vscode", "Visual Studio Code"), [0, 7, 14, 15, 16, 17])
        XCTAssertEqual(positions("mail", "Mapping Tools"), [0, 1, 4, 11])
        XCTAssertEqual(positions("trml", "Terminal"), [0, 2, 3, 7])
    }

    func testTypoHighlightsOnlyWhatLinesUp() {
        XCTAssertEqual(positions("chorme", "Google Chrome"), Array(7..<13))   // a swap: every letter is there
        XCTAssertEqual(positions("mail", "Mial"), [0, 1, 2, 3])
        XCTAssertEqual(positions("safiri", "Safari"), [0, 1, 2, 4, 5])        // not the wrong letter
        XCTAssertEqual(positions("xafari", "Safari"), [1, 2, 3, 4, 5])
        XCTAssertEqual(positions("safarri", "Safari"), [0, 1, 2, 3, 4, 5])    // the extra letter has nothing to light
        XCTAssertEqual(positions("chorm", "Google Chrome"), Array(7..<12))    // only the part typed so far
    }

    func testHighlightsCountCharacters() {
        XCTAssertEqual(positions("strasse", "Straße"), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(positions("straße", "Strasse"), [0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(positions("hot", "🔥 Hot deals"), [2, 3, 4])
        XCTAssertEqual(positions("deals", "👨‍👩‍👧 Family deals"), [9, 10, 11, 12, 13])
        let result = FuzzySearch.rank([item("Terminal", "robin — zsh", wid: 1)], query: "robin zsh")
        XCTAssertEqual(result.first?.titleMatches, [0, 1, 2, 3, 4, 8, 9, 10])
        XCTAssertEqual(result.first?.appNameMatches, [])
    }

    func testEmptyAndBlankQueries() {
        let items = [item("Safari", "Start Page", wid: 1), item("Mail", "Inbox", wid: 2)]
        XCTAssertEqual(ranked(items, ""), [1, 2])
        XCTAssertEqual(ranked(items, " \u{3000}\t"), [1, 2])
        XCTAssertTrue(FuzzySearch.rank(items, query: "zzzz").isEmpty)
        XCTAssertNil(FuzzySearch.match("mail", in: ""))
        XCTAssertNil(FuzzySearch.match("mail", in: "   "))
    }

    // MARK: - Performance

    func testRankingThreeHundredWindowsIsFast() {
        let apps = ["Google Chrome", "Safari", "Terminal", "Visual Studio Code", "Xcode", "Mail", "Notlar", "Finder", "Slack",
                    "Microsoft Teams", "Spotify", "Preview", "Adobe Photoshop", "Figma", "Notion", "WhatsApp", "Telegram",
                    "System Settings", "Calendar", "Messages", "TextEdit", "Pages", "Keynote", "Numbers", "Activity Monitor"]
        let words = ["GitHub", "pull", "request", "riffle", "release", "notes", "İstanbul", "görüntü", "ayarları", "robin", "zsh",
                     "swift", "build", "inbox", "draft", "meeting", "agenda", "design", "review", "Привет", "東京の天気", "สวัสดี",
                     "budget", "2026", "invoice", "README.md", "FuzzySearch.swift", "localhost:3000", "dashboard", "issue",
                     "#1234", "—", "-", "|", "Project", "Alpha", "photo", "export", "settings", "window", "switcher"]
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let items = (0..<300).map { index -> SwitcherItem in
            let title = (0..<(3 + next(9))).map { _ in words[next(words.count)] }.joined(separator: " ")
            return item(apps[next(apps.count)], title, wid: CGWindowID(index + 1))
        }
        // One to twelve characters: prefixes, several words, typos, initials and a query that matches nothing.
        let queries = ["s", "gi", "doc", "chor", "githb", "termnl", "visual s", "chorme gi", "istanbul a", "vscodeswift",
                       "notlar görün", "qzxwvkjyqpfh"]
        _ = queries.map { FuzzySearch.rank(items, query: $0) }
        let clock = ContinuousClock()
        var worst = Duration.zero
        var report = [String]()
        for query in queries {
            let fastest = (0..<5).map { _ in clock.measure { _ = FuzzySearch.rank(items, query: query) } }.min()!
            worst = max(worst, fastest)
            report.append("\(query.count):\(fastest.components.attoseconds / 1_000_000_000_000)µs")
        }
        print("Search timing, 300 windows: " + report.joined(separator: " "))
        // A frame is 8–16 ms; this bound is generous for an unoptimized debug build.
        XCTAssertLessThan(worst, .milliseconds(50))
    }

    func testLongTitlesStayFast() {
        // Pathological titles: thousands of characters, a word start every other one.
        let long = String(repeating: "a ", count: 2000) + "GitHub"
        let items = (0..<30).map { item("Safari", long + " \($0)", wid: CGWindowID($0 + 1)) }
        let clock = ContinuousClock()
        for query in ["a", "aa", "aaaa", "ghb", "githbu", "a a a a a a"] {
            let elapsed = clock.measure { _ = FuzzySearch.rank(items, query: query) }
            XCTAssertLessThan(elapsed, .milliseconds(100), query)
        }
    }
}
