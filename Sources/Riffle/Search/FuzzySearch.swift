import Foundation

/// Search inside the switcher. Every query word has to match the app name or the window title, and the way it matches
/// ranks the result, best first: the whole field, a prefix, a word start, a substring, initials ("vsc" for "Visual
/// Studio Code"), a scattered subsequence, and last a word with a typo ("chorme"). Words of one or two letters only
/// match at word starts, so a short query doesn't light up letters deep inside every title.
///
/// Folding is Turkish-aware: "goruntu" finds "Görüntü", "istanbul" finds "İSTANBUL" and "ılık" finds "Ilık" — case,
/// width, dotted/dotless i and Latin diacritics are all ignored. Marks that are part of a letter stay: Thai and Indic
/// vowel signs, kana voicing marks, Cyrillic й.
enum FuzzySearch {
    /// How a query word matched, worst first.
    enum Tier: Int, Comparable {
        case typo, subsequence, initials, substring, wordStart, prefix, exact

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Tiers are 1000 points apart; everything that orders matches within a tier stays well inside that.
        fileprivate var base: Int { (rawValue + 1) * 1000 }
    }

    struct Match: Equatable {
        let tier: Tier
        let score: Int
        /// Character offsets of the matched characters in the searched text.
        let positions: [Int]
    }

    /// App names are short and intentional, so a hit there is worth a little more than the same hit in a title.
    private static let appBonus = 60

    // MARK: - Ranking

    /// Ranks switcher items for a query. Every whitespace-separated word must match the app name or the title; each
    /// word picks whichever matches it better. Returns the matching items, best first, with highlight positions filled
    /// in; equal scores keep the incoming (most-recently-used) order.
    static func rank(_ items: [SwitcherItem], query: String) -> [SwitcherItem] {
        var matcher = Matcher()
        let tokens = matcher.tokens(of: query)
        guard !tokens.isEmpty else { return items }
        // The query as one phrase: "google chrome" should prefer the field that reads exactly that.
        let phrase = tokens.count > 1 ? Token(Array(tokens.map(\.codes).joined(separator: [0x20])), length: .max, hasDigit: true) : nil
        let title = Field()
        var scored = [(item: SwitcherItem, score: Int, order: Int)]()
        for (order, item) in items.enumerated() {
            let app = matcher.appField(item.appName)
            matcher.prepare(item.title, into: title)
            var total = 0
            var appCodes = [Int]()
            var titleCodes = [Int]()
            var matchedAll = true
            for token in tokens {
                guard let best = matcher.best(token, app: app, title: title) else { matchedAll = false; break }
                total += best.hit.score
                if best.inApp { appCodes += best.hit.codes } else { titleCodes += best.hit.codes }
            }
            guard matchedAll else { continue }
            if let phrase { total += max(matcher.phraseBonus(phrase, in: app), matcher.phraseBonus(phrase, in: title)) }
            var ranked = item
            ranked.appNameMatches = app.offsets(appCodes)
            ranked.titleMatches = title.offsets(titleCodes)
            scored.append((ranked, total, order))
        }
        // Ties keep most-recently-used order.
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        return scored.map(\.item)
    }

    /// How well one query word matches a text, or nil when it doesn't.
    static func match(_ word: String, in text: String) -> Match? {
        var matcher = Matcher()
        guard let token = matcher.tokens(of: word).first else { return nil }
        let field = Field()
        matcher.prepare(text, into: field)
        guard let hit = matcher.match(token, in: field) ?? matcher.typo(token, in: field) else { return nil }
        return Match(tier: hit.tier, score: hit.score, positions: field.offsets(hit.codes))
    }

    // MARK: - Folding

    static func fold(_ character: Character) -> Character {
        folded(character).first ?? character
    }

    static func fold(_ text: String) -> [Character] {
        Array(text.map(folded).joined())
    }

    /// One character folded for matching: lowercase, regular width, without the marks that only accent a letter, and
    /// composed. Usually one character, but "ß" becomes "ss", "ﬁ" becomes "fi" and Arabic tatweel disappears.
    static func folded(_ character: Character) -> String {
        if let ascii = character.asciiValue { return String(UnicodeScalar(foldASCII(ascii))) }
        if character.isWhitespace { return " " }
        // Invisible format characters — direction marks some apps put around names, zero-width spaces, soft
        // hyphens — take no part in matching.
        if character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .format }) { return "" }
        switch character {
        case "İ", "ı": return "i"
        case "Ş", "ş": return "s"
        case "Ğ", "ğ": return "g"
        case "Ü", "ü": return "u"
        case "Ö", "ö": return "o"
        case "Ç", "ç": return "c"
        // Letters with a stroke and ligatures don't decompose, so diacritic folding alone would keep them apart.
        case "Ø", "ø": return "o"
        case "Ł", "ł": return "l"
        case "Đ", "đ": return "d"
        case "Æ", "æ": return "ae"
        case "Œ", "œ": return "oe"
        // Titles use every kind of dash ("robin — zsh"); people type "-".
        case "‐", "‑", "‒", "–", "—", "―", "−": return "-"
        default: break
        }
        let text = String(character)
        switch character.unicodeScalars.first!.value {
        case 0xFF00...0xFFEF:
            // Full-width Latin and half-width kana: regular width first, then whatever that script does.
            let regular = text.folding(options: .widthInsensitive, locale: nil).precomposedStringWithCanonicalMapping
            return regular == text ? regular : regular.map(folded).joined()
        case 0x0400...0x052F, 0x1C80...0x1C8F, 0xA640...0xA69F:
            return foldCyrillic(text)
        case 0x0590...0x05FF, 0xFB1D...0xFB4F:
            return foldHebrew(text)
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF:
            return foldArabic(text)
        case ..<0x0590, 0x10A0...0x10FF, 0x1C90...0x1CBF, 0x1D00...0x1FFF, 0x2000...0x2BFF, 0x2C60...0x2C7F,
             0x2D00...0x2D2F, 0xA720...0xA7FF, 0xAB30...0xAB6F, 0xFB00...0xFB06:
            // Latin, Greek, Armenian, Georgian and symbols: accents only decorate a letter, so they go.
            return text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .precomposedStringWithCanonicalMapping
        default:
            // Other scripts keep their marks: Thai and Indic vowel signs and kana voicing marks make different letters.
            return text.lowercased().precomposedStringWithCanonicalMapping
        }
    }

    /// Cyrillic: ё is е and stress accents go, but й, ї and ў are letters of their own, not an accented и, і and у.
    private static func foldCyrillic(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var previous: UInt32 = 0
        for scalar in text.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars {
            let value = scalar.value
            if value == 0x0300 || value == 0x0301 || (value == 0x0308 && previous == 0x0435) { continue }
            scalars.append(scalar)
            previous = value
        }
        return String(scalars).precomposedStringWithCanonicalMapping
    }

    /// Hebrew: points and cantillation are optional, and mostly left out when typing.
    private static func foldHebrew(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars
        where !((0x0591...0x05C7).contains(scalar.value) && scalar.properties.generalCategory == .nonspacingMark) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Arabic: vowel marks and tatweel go, and alef with hamza or madda is a plain alef, the way most people type it.
    private static func foldArabic(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0610...0x061A, 0x0640, 0x064B...0x065F, 0x0670, 0x06D6...0x06DC, 0x06DF...0x06E4, 0x06E7, 0x06E8, 0x06EA...0x06ED:
                continue
            case 0x0622, 0x0623, 0x0625, 0x0671:
                scalars.append("\u{0627}")
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    // Plain comparisons rather than range patterns: these run for every character of every title.
    private static func foldASCII(_ byte: UInt8) -> UInt8 {
        if byte >= 0x41 && byte <= 0x5A { return byte + 0x20 }
        return byte >= 0x09 && byte <= 0x0D ? 0x20 : byte
    }

    // MARK: - Characters

    /// What a character is for finding words: its kind and case.
    private enum Kind {
        static let space: UInt8 = 0
        static let punctuation: UInt8 = 1
        static let letter: UInt8 = 2
        static let digit: UInt8 = 3
        /// A letter of a script written without spaces between words.
        static let spaceless: UInt8 = 4
        static let mask: UInt8 = 7
        static let upper: UInt8 = 8
        static let lower: UInt8 = 16
    }

    private static func asciiKind(_ byte: UInt8) -> UInt8 {
        if byte >= 0x61 && byte <= 0x7A { return Kind.letter | Kind.lower }
        if byte >= 0x41 && byte <= 0x5A { return Kind.letter | Kind.upper }
        if byte >= 0x30 && byte <= 0x39 { return Kind.digit }
        return byte == 0x20 || (byte >= 0x09 && byte <= 0x0D) ? Kind.space : Kind.punctuation
    }

    private static func kind(_ character: Character) -> UInt8 {
        if character.isWhitespace { return Kind.space }
        let first = character.unicodeScalars.first!
        var kind: UInt8
        switch first.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber:
            kind = Kind.digit
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark:
            kind = isSpaceless(first.value) ? Kind.spaceless : Kind.letter
        default:
            kind = Kind.punctuation
        }
        if character.isUppercase { kind |= Kind.upper }
        if character.isLowercase { kind |= Kind.lower }
        return kind
    }

    /// Scripts written without spaces between words (Han, kana, Hangul, Thai, Lao, Khmer, Myanmar): any character
    /// may begin a word, so a match there counts as a word start.
    private static func isSpaceless(_ value: UInt32) -> Bool {
        switch value {
        case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1100...0x11FF, 0x1780...0x17FF, 0x2E80...0x2FDF,
             0x3005...0x3007, 0x3021...0x3029, 0x3031...0x3035, 0x303B, 0x303C, 0x3040...0x31FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7FF, 0xF900...0xFAFF,
             0xFF66...0xFFDC, 0x20000...0x3FFFF:
            return true
        default:
            return false
        }
    }

    // MARK: - Fields and tokens

    /// Per-code flags of a field.
    private enum Flag {
        /// Begins a word: start of the text, after a space or punctuation, a camelCase hump, letter/digit changes.
        static let start: UInt8 = 1
        /// Begins a character of a spaceless script.
        static let anywhere: UInt8 = 2
        /// Part of a word: a letter, digit or ideograph rather than a space or punctuation.
        static let word: UInt8 = 4
        /// The word start is a camelCase hump, which typo matching doesn't split words at ("GitHub").
        static let hump: UInt8 = 8
    }

    /// A searchable text folded to Unicode scalars ("codes"): matching works on these, so a Thai or Devanagari
    /// cluster matches while it is still being typed, and every code remembers the character it came from.
    private final class Field {
        var codes: [UInt32] = []
        /// Character offset of each code in the original text, for highlighting.
        var owners: [Int32] = []
        var flags: [UInt8] = []
        /// The codes without leading and trailing spaces.
        var lower = 0
        var upper = 0
        /// Words for typo matching, built the first time a typo is looked for.
        var words: [Word]?

        /// Character offsets of matched codes, sorted and without duplicates.
        func offsets(_ indices: [Int]) -> [Int] {
            guard !indices.isEmpty else { return [] }
            var result = [Int]()
            for index in indices.sorted() {
                let offset = Int(owners[index])
                if result.last != offset { result.append(offset) }
            }
            return result
        }

        /// How many words begin before a code, to prefer matches near the front.
        func wordIndex(before index: Int) -> Int {
            let flags = flags
            var count = 0
            var scan = lower
            while scan < index {
                if flags[scan] & Flag.word != 0 && flags[scan] & (Flag.start | Flag.anywhere) != 0 { count += 1 }
                scan += 1
            }
            return count
        }

        /// Words split at spaces, punctuation and script or letter/digit changes — not at camelCase humps, since
        /// "githbu" is a typo of "GitHub".
        func typoWords() -> [Word] {
            if let words { return words }
            var result = [Word]()
            var index = lower
            while index < upper {
                guard flags[index] & Flag.word != 0 else { index += 1; continue }
                let start = index
                var mask: UInt64 = 0
                repeat {
                    mask |= 1 << UInt64(codes[index] & 63)
                    index += 1
                } while index < upper && flags[index] & Flag.word != 0
                    && (flags[index] & Flag.start == 0 || flags[index] & Flag.hump != 0)
                result.append(Word(start: start, end: index, mask: mask))
            }
            words = result
            return result
        }
    }

    private struct Word {
        let start: Int
        let end: Int
        /// Which codes occur, folded into 64 bits: a cheap lower bound on the edits a typo needs.
        let mask: UInt64
    }

    private struct Token {
        let codes: [UInt32]
        /// Characters as typed, which the short-query rule and the typo budget count.
        let length: Int
        let allowsTypos: Bool
        let edits: Int
        let mask: UInt64

        init(_ codes: [UInt32], length: Int, hasDigit: Bool) {
            self.codes = codes
            self.length = length
            // A different digit is a different number, not a typo; short words have too many one-letter neighbours.
            allowsTypos = length >= 4 && !hasDigit
            edits = length >= 8 ? 2 : 1
            mask = codes.reduce(0) { $0 | 1 << UInt64($1 & 63) }
        }
    }

    private struct Hit {
        let tier: Tier
        var score: Int
        /// Matched code indices in the field.
        let codes: [Int]
    }

    // MARK: - Matching

    /// One ranking pass. Folded characters are remembered for the pass and app names are prepared once, since most
    /// windows share their app's name.
    private struct Matcher {
        private var memo: [Character: (start: Int, count: Int, kind: UInt8)] = [:]
        private var pool: [UInt32] = []
        private var apps: [String: Field] = [:]
        private var table: [Int] = []

        mutating func tokens(of query: String) -> [Token] {
            var tokens = [Token]()
            for word in query.split(whereSeparator: \.isWhitespace) {
                var codes = [UInt32]()
                var hasDigit = false
                for character in word {
                    let kind = fold(character, into: &codes)
                    if kind & Kind.mask == Kind.digit { hasDigit = true }
                }
                if !codes.isEmpty { tokens.append(Token(codes, length: word.count, hasDigit: hasDigit)) }
            }
            return tokens
        }

        /// Appends the folded codes of a character and returns its kind.
        private mutating func fold(_ character: Character, into codes: inout [UInt32]) -> UInt8 {
            if let ascii = character.asciiValue {
                codes.append(UInt32(FuzzySearch.foldASCII(ascii)))
                return FuzzySearch.asciiKind(ascii)
            }
            let entry: (start: Int, count: Int, kind: UInt8)
            if let known = memo[character] {
                entry = known
            } else {
                let start = pool.count
                for scalar in FuzzySearch.folded(character).unicodeScalars { pool.append(scalar.value) }
                entry = (start, pool.count - start, FuzzySearch.kind(character))
                memo[character] = entry
            }
            codes.append(contentsOf: pool[entry.start..<entry.start + entry.count])
            return entry.kind
        }

        mutating func appField(_ name: String) -> Field {
            if let field = apps[name] { return field }
            let field = Field()
            prepare(name, into: field)
            apps[name] = field
            return field
        }

        mutating func prepare(_ text: String, into field: Field) {
            // Work on local arrays (keeping the field's capacity) rather than through the class on every character.
            var codes = field.codes, owners = field.owners, flags = field.flags
            field.codes = []
            field.owners = []
            field.flags = []
            field.words = nil
            codes.removeAll(keepingCapacity: true)
            owners.removeAll(keepingCapacity: true)
            flags.removeAll(keepingCapacity: true)
            var lower = -1, upper = 0
            var previous = Kind.space, beforePrevious = Kind.space
            var previousFirst = -1
            var offset: Int32 = -1
            for character in text {
                offset += 1
                let first = codes.count
                let kind = fold(character, into: &codes)
                let end = codes.count
                // What folds to nothing (a direction mark, tatweel) doesn't separate words either.
                guard first < end else { continue }
                let base = kind & Kind.mask
                let isWord = base != Kind.space && base != Kind.punctuation
                var code = first
                while code < end {
                    owners.append(offset)
                    flags.append(isWord ? Flag.word : 0)
                    code += 1
                }
                if base != Kind.space {
                    var head = base == Kind.spaceless ? Flag.anywhere : 0
                    let previousBase = previous & Kind.mask
                    if lower < 0 || previousBase == Kind.space || previousBase != base {
                        head |= Flag.start
                    } else if base == Kind.letter {
                        if previous & Kind.lower != 0 && kind & Kind.upper != 0 {
                            head |= Flag.start | Flag.hump    // "gitHub"
                        } else if kind & Kind.lower != 0 && previous & Kind.upper != 0 && beforePrevious & Kind.upper != 0
                                    && beforePrevious & Kind.mask == Kind.letter && previousFirst >= 0 {
                            flags[previousFirst] |= Flag.start | Flag.hump    // the "P" of "HTMLParser"
                        }
                    }
                    flags[first] |= head
                    if lower < 0 { lower = first }
                    upper = end
                }
                beforePrevious = previous
                previous = kind
                previousFirst = first
            }
            field.codes = codes
            field.owners = owners
            field.flags = flags
            field.lower = max(lower, 0)
            field.upper = upper
        }

        /// The better of a word's matches in the app name and the title, falling back to typos only when neither
        /// matches otherwise. Ties go to the app name.
        mutating func best(_ token: Token, app: Field, title: Field) -> (hit: Hit, inApp: Bool)? {
            var inApp = match(token, in: app)
            var inTitle = match(token, in: title)
            if inApp == nil && inTitle == nil {
                inApp = typo(token, in: app)
                inTitle = typo(token, in: title)
            }
            inApp?.score += FuzzySearch.appBonus
            switch (inApp, inTitle) {
            case let (appHit?, titleHit?): return appHit.score >= titleHit.score ? (appHit, true) : (titleHit, false)
            case let (appHit?, nil): return (appHit, true)
            case let (nil, titleHit?): return (titleHit, false)
            case (nil, nil): return nil
            }
        }

        /// Every tier but typos, best first.
        func match(_ token: Token, in field: Field) -> Hit? {
            guard field.lower < field.upper else { return nil }
            if let hit = contiguous(token, in: field) { return hit }
            guard token.length >= 2, reachable(token.codes, in: field) else { return nil }
            if let hit = initials(token, in: field) { return hit }
            return token.length >= 3 ? subsequence(token, in: field) : nil
        }

        /// The best place the token occurs as is: the whole field, its start, a word start, or — for words of three
        /// letters or more — anywhere.
        func contiguous(_ token: Token, in field: Field) -> Hit? {
            let t = token.codes, m = t.count, head = t[0]
            let codes = field.codes, flags = field.flags, lower = field.lower, upper = field.upper
            guard upper - lower >= m else { return nil }
            var bestStart = -1
            var bestTier = Tier.typo
            var bestScore = Int.min
            var start = lower - 1
            var wordsBefore = 0
            while start < upper - m {
                if start >= lower && flags[start] & Flag.word != 0 && flags[start] & (Flag.start | Flag.anywhere) != 0 { wordsBefore += 1 }
                start += 1
                guard codes[start] == head else { continue }
                var length = 1
                while length < m && codes[start + length] == t[length] { length += 1 }
                guard length == m else { continue }
                let tier: Tier
                if start == lower {
                    tier = upper - lower == m ? .exact : .prefix
                } else if flags[start] & (Flag.start | Flag.anywhere) != 0 {
                    tier = .wordStart
                } else if token.length > 2 {
                    tier = .substring
                } else {
                    continue
                }
                var score = tier.base - 15 * min(wordsBefore, 20)
                if tier >= .wordStart && endsWord(field, at: start + m) { score += 120 }
                if score > bestScore { bestStart = start; bestTier = tier; bestScore = score }
                if tier >= .prefix { break }
            }
            guard bestStart >= 0 else { return nil }
            return Hit(tier: bestTier, score: bestScore, codes: Array(bestStart..<bestStart + m))
        }

        private func endsWord(_ field: Field, at end: Int) -> Bool {
            end >= field.upper || field.flags[end] & Flag.word == 0 || field.flags[end] & (Flag.start | Flag.anywhere) != 0
        }

        /// Initials and abbreviations need the first letter on a word start and the rest in order after it.
        private func reachable(_ t: [UInt32], in field: Field) -> Bool {
            let codes = field.codes, flags = field.flags
            var index = field.lower
            while index < field.upper && !(codes[index] == t[0] && flags[index] & (Flag.start | Flag.anywhere) != 0) {
                index += 1
            }
            guard index < field.upper else { return false }
            var next = 1
            index += 1
            while index < field.upper && next < t.count {
                if codes[index] == t[next] { next += 1 }
                index += 1
            }
            return next == t.count
        }

        /// The token as pieces that each begin a word, in order: "vsc" or "vscode" for "Visual Studio Code", "gh" for
        /// "GitHub". Prefers consecutive words near the front.
        func initials(_ token: Token, in field: Field) -> Hit? {
            let t = token.codes, m = t.count
            // Longer runs are pasted text, not abbreviations; they would only make the table big.
            guard m >= 2, m <= 32 else { return nil }
            let codes = field.codes, flags = field.flags
            var starts = [Int]()
            for index in field.lower..<field.upper where flags[index] & (Flag.start | Flag.word) == Flag.start | Flag.word {
                starts.append(index)
                if starts.count == 64 { break }
            }
            let w = starts.count
            guard w >= 2 else { return nil }
            let none = Int.max
            // For the rest of the token from j with a piece beginning at word x: fewest words skipped after it, the
            // piece's length and the next piece's word.
            var skipped = [Int](repeating: none, count: m * w)
            var piece = [Int](repeating: 0, count: m * w)
            var following = [Int](repeating: -1, count: m * w)
            for j in stride(from: m - 1, through: 0, by: -1) {
                for x in 0..<w where codes[starts[x]] == t[j] {
                    let position = starts[x], cell = j * w + x
                    var run = 1
                    while j + run < m && position + run < field.upper && codes[position + run] == t[j + run] { run += 1 }
                    for length in stride(from: run, through: 1, by: -1) {
                        if j + length == m {
                            if skipped[cell] > 0 { skipped[cell] = 0; piece[cell] = length; following[cell] = -1 }
                            continue
                        }
                        var y = x + 1
                        while y < w && starts[y] < position + length { y += 1 }
                        while y < w {
                            let rest = skipped[(j + length) * w + y]
                            if rest != none && rest + y - x - 1 < skipped[cell] {
                                skipped[cell] = rest + y - x - 1
                                piece[cell] = length
                                following[cell] = y
                            }
                            y += 1
                        }
                    }
                }
            }
            var first = -1
            var cost = Int.max
            for x in 0..<w where skipped[x] != none && skipped[x] * 40 + min(x, 20) * 15 < cost {
                first = x
                cost = skipped[x] * 40 + min(x, 20) * 15
            }
            guard first >= 0 else { return nil }
            var matched = [Int]()
            var pieces = 0
            var j = 0, x = first
            while x >= 0 {
                let cell = j * w + x
                matched += starts[x]..<starts[x] + piece[cell]
                pieces += 1
                j += piece[cell]
                x = following[cell]
            }
            // One piece would be a word-start match, which the contiguous search has already ruled out.
            guard pieces >= 2 else { return nil }
            let score = Tier.initials.base + (skipped[first] == 0 ? 150 : 0) - 40 * min(skipped[first], 5) - 15 * min(first, 20)
            return Hit(tier: .initials, score: score, codes: matched)
        }

        /// The token's letters in order, starting on a word start; the alignment keeps runs together and favours
        /// word starts, so the highlight reads naturally.
        func subsequence(_ token: Token, in field: Field) -> Hit? {
            let t = token.codes, codes = field.codes, flags = field.flags
            var best: Hit?
            var tried = 0
            var start = field.lower - 1
            while start + 1 < field.upper {
                start += 1
                guard codes[start] == t[0] && flags[start] & (Flag.start | Flag.anywhere) != 0 else { continue }
                tried += 1
                // Preferring word starts can skip past the only later letter; the leftmost alignment never does, and
                // if even that fails, later starts will too.
                guard tried <= 16, let matched = align(t, in: field, from: start, preferStarts: true)
                    ?? align(t, in: field, from: start, preferStarts: false) else { break }
                var score = 0
                var previous = start
                for position in matched.dropFirst() {
                    score += position == previous + 1 ? 30 : -4 * min(position - previous - 1, 12)
                    if flags[position] & Flag.start != 0 { score += 25 }
                    previous = position
                }
                score -= 15 * min(field.wordIndex(before: start), 20)
                score = Tier.subsequence.base + max(-450, min(450, score))
                if best == nil || score > best!.score { best = Hit(tier: .subsequence, score: score, codes: matched) }
            }
            return best
        }

        private func align(_ t: [UInt32], in field: Field, from start: Int, preferStarts: Bool) -> [Int]? {
            let codes = field.codes, flags = field.flags, upper = field.upper
            var matched = [start]
            var cursor = start + 1
            for wanted in t.dropFirst() {
                if cursor < upper && codes[cursor] == wanted {
                    matched.append(cursor)
                    cursor += 1
                    continue
                }
                var found = -1
                var scan = cursor
                while scan < upper {
                    if codes[scan] == wanted {
                        if found < 0 { found = scan }
                        if !preferStarts || flags[scan] & Flag.start != 0 { found = scan; break }
                    }
                    scan += 1
                }
                guard found >= 0 else { return nil }
                matched.append(found)
                cursor = found + 1
            }
            return matched
        }

        /// A word typed with a typo: the whole word, or for words of five letters or more the start of a longer one
        /// (still being typed), within one edit, two from eight letters. Edits are optimal string alignment distance,
        /// the restricted Damerau–Levenshtein: a wrong, missing or extra letter, or two neighbours swapped.
        mutating func typo(_ token: Token, in field: Field) -> Hit? {
            guard token.allowsTypos, field.lower < field.upper else { return nil }
            let t = token.codes, m = t.count, limit = token.edits
            let words = field.typoWords()
            var best: (score: Int, word: Int, length: Int)?
            for (ordinal, word) in words.enumerated() {
                let length = word.end - word.start
                let whole = abs(length - m) <= limit
                let prefix = token.length >= 5 && length > m
                guard whole || prefix, (token.mask & ~word.mask).nonzeroBitCount <= limit else { continue }
                let columns = min(length, m + limit)
                guard distances(t, field.codes, from: word.start, columns: columns, limit: limit) else { continue }
                let last = m * (columns + 1)
                var choice: (distance: Int, length: Int, whole: Bool)?
                if whole && table[last + length] <= limit { choice = (table[last + length], length, true) }
                if choice == nil && prefix && m <= min(columns, length - 1) {
                    for end in m...min(columns, length - 1) where table[last + end] <= limit && table[last + end] < (choice?.distance ?? .max) {
                        choice = (table[last + end], end, false)
                    }
                }
                guard let choice else { continue }
                let score = Tier.typo.base + (choice.distance == 1 ? 300 : 0) + (choice.whole ? 150 : 0) - 15 * min(ordinal, 20)
                if best == nil || score > best!.score { best = (score, ordinal, choice.length) }
            }
            guard let best else { return nil }
            // Highlight what lines up: equal letters and swapped neighbours, not the substituted or missing ones.
            let start = words[best.word].start
            let columns = min(words[best.word].end - start, m + limit), width = columns + 1
            _ = distances(t, field.codes, from: start, columns: columns, limit: limit)
            var codes = [Int]()
            var i = m, j = best.length
            while i > 0 && j > 0 {
                let here = table[i * width + j]
                if t[i - 1] == field.codes[start + j - 1] && here == table[(i - 1) * width + j - 1] {
                    codes.append(start + j - 1)
                    i -= 1; j -= 1
                } else if i > 1 && j > 1 && t[i - 1] == field.codes[start + j - 2] && t[i - 2] == field.codes[start + j - 1]
                            && here == table[(i - 2) * width + j - 2] + 1 {
                    codes += [start + j - 1, start + j - 2]
                    i -= 2; j -= 2
                } else if here == table[(i - 1) * width + j - 1] + 1 {
                    i -= 1; j -= 1
                } else if here == table[(i - 1) * width + j] + 1 {
                    i -= 1
                } else {
                    j -= 1
                }
            }
            return Hit(tier: .typo, score: best.score, codes: codes.reversed())
        }

        /// Fills `table` with the edit distances between `t` and the first `columns` codes from `start`; false as soon
        /// as every alignment needs more than `limit` edits.
        private mutating func distances(_ t: [UInt32], _ codes: [UInt32], from start: Int, columns: Int, limit: Int) -> Bool {
            let m = t.count, width = columns + 1
            if table.count < (m + 1) * width { table = [Int](repeating: 0, count: (m + 1) * width) }
            var j = 0
            while j <= columns {
                table[j] = j
                j += 1
            }
            var i = 1
            while i <= m {
                let row = i * width, above = row - width
                table[row] = i
                var smallest = i
                j = 1
                while j <= columns {
                    let code = codes[start + j - 1]
                    var value = min(table[above + j] + 1, table[row + j - 1] + 1, table[above + j - 1] + (t[i - 1] == code ? 0 : 1))
                    if i > 1 && j > 1 && t[i - 1] == codes[start + j - 2] && t[i - 2] == code {
                        value = min(value, table[above - width + j - 2] + 1)
                    }
                    table[row + j] = value
                    smallest = min(smallest, value)
                    j += 1
                }
                if smallest > limit { return false }
                i += 1
            }
            return true
        }

        /// Extra points when a field contains the whole multi-word query as typed.
        func phraseBonus(_ phrase: Token, in field: Field) -> Int {
            guard field.lower < field.upper, let hit = contiguous(phrase, in: field) else { return 0 }
            switch hit.tier {
            case .exact: return 3000
            case .prefix: return 2000
            case .wordStart: return 1000
            default: return 500
            }
        }
    }
}
