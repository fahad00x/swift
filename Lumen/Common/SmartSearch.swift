import Foundation

// Search over the on-device libraries (both apps). No server requests: everything here runs on
// the copy of the libraries already kept on the device.
//
// - Typos and word order: «breakin bad», «bad breaking», «brekingbad» → Breaking Bad.
// - One spelling for Arabic: أ/إ/آ → ا, ة → ه, ى → ي, no tashkeel or tatweel.
// - English titles typed in Arabic letters: «بريكنق باد», «سكويد قيم» (a "sound skeleton").
// - Other names: the original title Plex keeps, and anime titles from AniList (`AnimeTitles`).
// - Kinds of things: «مسلسل كوميدي», «انمي فانتازيا», «فيلم رعب كوري», «اكشن 2023».

// MARK: - Text

enum SearchText {
    /// Lowercased, without accents or punctuation, Arabic letter forms unified, single spaces.
    static func normalize(_ raw: String) -> String {
        let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            let v = scalar.value
            // Apostrophes join the word: «Grey's» → «greys».
            if v == 0x27 || v == 0x60 || v == 0x2018 || v == 0x2019 { continue }
            var mapped: Unicode.Scalar? = scalar
            switch v {
            case 0x622, 0x623, 0x625, 0x671: mapped = "ا"
            case 0x629: mapped = "ه"
            case 0x649, 0x626: mapped = "ي"
            case 0x624: mapped = "و"
            case 0x67E: mapped = "ب"
            case 0x6A4: mapped = "ف"
            case 0x6AF: mapped = "ك"
            case 0x621, 0x640, 0x670, 0x64B...0x65F: mapped = nil
            case 0x660...0x669: mapped = Unicode.Scalar(UInt8(v - 0x660 + 0x30))
            case 0x6F0...0x6F9: mapped = Unicode.Scalar(UInt8(v - 0x6F0 + 0x30))
            default: break
            }
            guard let letter = mapped else { continue }
            if CharacterSet.alphanumerics.contains(letter) {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(letter)
            } else {
                pendingSpace = true
            }
        }
        return String(out)
    }

    static func isArabic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x600...0x6FF).contains($0.value) }
    }

    static func scalars(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }

    /// Which letters a text has, one bit each (letters may share a bit).
    static func mask(_ letters: [UInt32]) -> UInt64 {
        letters.reduce(0) { $0 | (1 << UInt64(($1 &* 2654435761) >> 26)) }
    }

    /// Letters of `a` that `b` doesn't have: every one costs an edit, so more of them than the
    /// limit means no match (the edit distance needn't be worked out).
    @inline(__always)
    static func missing(_ a: UInt64, _ b: UInt64) -> Int { (a & ~b).nonzeroBitCount }

    static func contains(_ text: [UInt8], _ part: [UInt8]) -> Bool {
        guard part.count <= text.count else { return false }
        return text.withUnsafeBytes { t in
            part.withUnsafeBytes { p in memmem(t.baseAddress!, t.count, p.baseAddress!, p.count) != nil }
        }
    }

    /// Typos allowed in a word of this length.
    static func tolerance(_ length: Int) -> Int {
        length <= 3 ? 0 : (length <= 6 ? 1 : 2)
    }

    /// Edit distance (insert, delete, replace, swap two neighbours), at most `limit + 1`.
    /// `prefix`: distance to the closest beginning of `b` (a word still being typed).
    static func distance(_ a: [UInt32], _ b: [UInt32], limit: Int, prefix: Bool = false) -> Int {
        let n = a.count, m = b.count
        if n == 0 { return prefix ? 0 : min(m, limit + 1) }
        if m == 0 { return min(n, limit + 1) }
        if !prefix && abs(n - m) > limit { return limit + 1 }
        return withUnsafeTemporaryAllocation(of: Int.self, capacity: 3 * (m + 1)) { buffer in
        var older = UnsafeMutableBufferPointer(rebasing: buffer[0..<(m + 1)])
        var previous = UnsafeMutableBufferPointer(rebasing: buffer[(m + 1)..<(2 * m + 2)])
        var current = UnsafeMutableBufferPointer(rebasing: buffer[(2 * m + 2)...])
        for j in 0...m { older[j] = 0; previous[j] = j; current[j] = 0 }
        for i in 1...n {
            current[0] = i
            var rowMin = i
            for j in 1...m {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = Swift.min(value, older[j - 2] + 1)
                }
                current[j] = value
                rowMin = Swift.min(rowMin, value)
            }
            if rowMin > limit { return limit + 1 }
            (older, previous, current) = (previous, current, older)
        }
        let result = prefix ? (previous.min() ?? n) : previous[m]
        return Swift.min(result, limit + 1)
        }
    }

    // MARK: Sound skeleton

    /// The consonants of a word as they sound, the same for Latin and Arabic spellings:
    /// «Breaking» and «بريكنق» → "brknk", «Squid» and «سكويد» → "skd". Vowels are dropped
    /// (Arabic usually doesn't write them) and letters that sound alike are merged.
    static func skeleton(_ word: String) -> String {
        if word == "x" { return "" }   // «Hunter x Hunter», «Spy x Family»
        return isArabic(word) ? arabicSkeleton(word) : latinSkeleton(word)
    }

    private static let latinVowels: Set<Character> = ["a", "e", "i", "o", "u", "y", "w"]

    private static func latinSkeleton(_ word: String) -> String {
        let c = Array(word)
        func at(_ k: Int) -> Character? { k < c.count ? c[k] : nil }
        var out: [Character] = []
        var i = 0
        while i < c.count {
            let ch = c[i]
            let next = at(i + 1)
            var step = 1
            if latinVowels.contains(ch) {
                // dropped
            } else if ch.isNumber {
                out.append(ch)
            } else {
                switch ch {
                case "p":
                    if next == "h" { out.append("f"); step = 2 } else { out.append("b") }
                case "s":
                    if next == "h" { out.append("x"); step = 2 }
                    else if next == "c", at(i + 2) == "h" { out.append("x"); step = 3 }
                    else { out.append("s") }
                case "c":
                    if next == "h" { out.append("x"); step = 2 }
                    else if next == "k" { out.append("k"); step = 2 }
                    else { out.append(next == "e" || next == "i" || next == "y" ? "s" : "k") }
                case "t":
                    if next == "c", at(i + 2) == "h" { out.append("x"); step = 3 }
                    else if next == "h" { out.append("t"); step = 2 }
                    else if next == "i", at(i + 2) == "o", at(i + 3) == "n" { out += ["x", "n"]; step = 4 }
                    else { out.append("t") }
                case "g":
                    if next == "h" {
                        if i == 0 { out.append("k") }
                        step = 2
                    } else {
                        out.append("k")
                    }
                case "k":
                    if !(i == 0 && next == "n") { out.append("k") }   // «Knives»
                case "q", "j":
                    out.append("k")
                case "x":
                    out += ["k", "s"]
                case "z":
                    out.append("s")
                case "v":
                    out.append("f")
                case "h":
                    // Heard before a vowel («Harry», «Oppenheimer»), silent otherwise («John»).
                    if i == 0 || (next.map { "aeiou".contains($0) } ?? false) { out.append("h") }
                case "b", "d", "f", "l", "m", "n", "r":
                    out.append(ch)
                default:
                    break
                }
            }
            i += step
        }
        return collapsed(out)
    }

    private static let arabicSounds: [Character: Character] = [
        "ب": "b", "ت": "t", "ط": "t", "ث": "t", "ذ": "t", "ج": "k", "خ": "k", "د": "d", "ض": "d",
        "ر": "r", "ز": "s", "ظ": "s", "س": "s", "ص": "s", "ش": "x", "چ": "x", "غ": "k", "ق": "k",
        "ك": "k", "ف": "f", "ل": "l", "م": "m", "ن": "n", "ح": "h",
    ]

    private static func arabicSkeleton(_ word: String) -> String {
        let c = Array(word)
        var out: [Character] = []
        for (i, ch) in c.enumerated() {
            if ch.isNumber { out.append(ch); continue }
            if ch == "ه" {
                // A final ه is usually a vowel.
                if i == 0 || i < c.count - 1 { out.append("h") }
                continue
            }
            guard let sound = arabicSounds[ch] else { continue }   // ا و ي ع: vowels
            if sound == "x", out.last == "t" { out[out.count - 1] = "x"; continue }   // «تش»
            out.append(sound)
        }
        return collapsed(out)
    }

    private static func collapsed(_ letters: [Character]) -> String {
        var out: [Character] = []
        for ch in letters where out.last != ch { out.append(ch) }
        return String(out)
    }
}

// MARK: - Fields and queries

/// A name prepared for matching (title, original title, alternative title, person).
struct SearchField: Sendable {
    let text: String
    let words: [String]
    let compact: String
    let wordScalars: [[UInt32]]
    let compactScalars: [UInt32]
    let isArabic: Bool
    /// Per word; empty for Arabic names (the sound match is for Latin names typed in Arabic).
    let skeletons: [[UInt32]]
    // Quick rejections (see `SearchText.missing`).
    let wordMasks: [UInt64]
    let mask: UInt64
    let skeletonMasks: [UInt64]
    let textBytes: [UInt8]
    let compactBytes: [UInt8]

    init?(_ raw: String?) {
        guard let raw else { return nil }
        let text = SearchText.normalize(raw)
        guard !text.isEmpty else { return nil }
        let words = text.split(separator: " ").map(String.init)
        let compact = words.joined()
        let arabic = SearchText.isArabic(text)
        self.text = text
        self.words = words
        self.compact = compact
        wordScalars = words.map(SearchText.scalars)
        compactScalars = SearchText.scalars(compact)
        isArabic = arabic
        skeletons = arabic ? [] : words.map { SearchText.scalars(SearchText.skeleton($0)) }
        wordMasks = wordScalars.map(SearchText.mask)
        mask = SearchText.mask(compactScalars)
        skeletonMasks = skeletons.map(SearchText.mask)
        textBytes = Array(text.utf8)
        compactBytes = Array(compact.utf8)
    }
}

struct SearchQuery: Sendable {
    let field: SearchField
    /// All words' skeletons joined (only for a query typed in Arabic).
    let skeleton: [UInt32]
    let skeletonMask: UInt64

    init?(_ raw: String) {
        guard let field = SearchField(raw) else { return nil }
        self.field = field
        skeleton = field.isArabic
            ? SearchText.scalars(field.words.map(SearchText.skeleton).joined())
            : []
        skeletonMask = SearchText.mask(skeleton)
    }
}

// MARK: - Matching

enum SearchMatch {
    /// 0 = no match; higher is better (1000 exact … ~360 sounds alike).
    static func score(_ query: SearchQuery, _ f: SearchField) -> Int {
        let q = query.field
        let missing = SearchText.missing(q.mask, f.mask)
        if missing == 0 {
            if q.compactBytes == f.compactBytes { return 1000 }
            if f.textBytes.starts(with: q.textBytes) { return 900 }
            if everyWordStartsAWord(q.wordScalars, f.wordScalars) { return 800 }
            if q.compactScalars.count >= 3 && SearchText.contains(f.compactBytes, q.compactBytes) { return 700 }
            if SearchText.contains(f.textBytes, q.textBytes) { return 650 }
        }
        if let typos = fuzzyWords(q, f), typos > 0 { return 500 - 30 * typos }
        if q.compactScalars.count >= 5 {
            let limit = SearchText.tolerance(q.compactScalars.count)
            if missing <= limit {
                let d = SearchText.distance(q.compactScalars, f.compactScalars, limit: limit, prefix: true)
                if d <= limit { return 450 - 30 * d }
            }
        }
        if q.isArabic && !f.isArabic { return soundScore(query, f) }
        return 0
    }

    /// Each query word begins a different word of the name (any order).
    private static func everyWordStartsAWord(_ query: [[UInt32]], _ words: [[UInt32]]) -> Bool {
        var used = Set<Int>()
        for w in query {
            guard let k = words.indices.first(where: { !used.contains($0) && words[$0].starts(with: w) }) else { return false }
            used.insert(k)
        }
        return true
    }

    /// Total typos when every query word matches a different word of the name (the last one
    /// may be a beginning: still being typed); nil when some word doesn't match.
    private static func fuzzyWords(_ q: SearchField, _ f: SearchField) -> Int? {
        var used = Set<Int>()
        var total = 0
        for (index, word) in q.wordScalars.enumerated() {
            let limit = SearchText.tolerance(word.count)
            let isLast = index == q.wordScalars.count - 1
            var best: (distance: Int, at: Int)?
            for (k, candidate) in f.wordScalars.enumerated() where !used.contains(k)
                && SearchText.missing(q.wordMasks[index], f.wordMasks[k]) <= limit {
                let d = SearchText.distance(word, candidate, limit: limit, prefix: isLast)
                if d <= limit, best.map({ d < $0.distance }) ?? true { best = (d, k) }
            }
            guard let match = best else { return nil }
            used.insert(match.at)
            total += match.distance
        }
        return total
    }

    /// A Latin name typed in Arabic letters: the query's sounds against runs of the name's words.
    private static func soundScore(_ query: SearchQuery, _ f: SearchField) -> Int {
        let qs = query.skeleton
        let words = f.skeletons
        guard !words.isEmpty else { return 0 }
        // A short word («اوفيس» → "fs", «دون» → "dn") only as a whole word.
        if qs.count == 2 {
            return query.field.compact.count >= 3 && words.contains(qs) ? 360 : 0
        }
        guard qs.count >= 3 else { return 0 }
        let limit = qs.count <= 4 ? 0 : (qs.count <= 7 ? 1 : 2)
        var best = 0
        for start in words.indices {
            var run: [UInt32] = []
            var runMask: UInt64 = 0
            for end in start..<words.count {
                run += words[end]
                runMask |= f.skeletonMasks[end]
                guard run.count <= qs.count + limit + 6 else { break }
                guard SearchText.missing(query.skeletonMask, runMask) <= limit else { continue }
                var d = SearchText.distance(qs, run, limit: limit)
                if d > limit, qs.count >= 4 { d = SearchText.distance(qs, run, limit: limit, prefix: true) }
                guard d <= limit else { continue }
                let whole = start == 0 && end == words.count - 1
                // The very sounds, from the name's beginning («هنتر», Hunter): before another
                // name a letter away («عنتر», 470).
                best = max(best, d == 0 && start == 0 && run.count == qs.count ? (whole ? 485 : 475)
                                                       : 400 - 25 * d + (whole ? 40 : 0) - 5 * start)
            }
        }
        return best
    }
}

// MARK: - Library entries

/// One movie or show of a library, with its names prepared once (when the library loads).
struct SearchEntry: @unchecked Sendable {
    let item: PlexItem
    let section: String
    /// Title first, then Plex's original title.
    let titles: [SearchField]
    /// Anime: its other titles (`AnimeNames`).
    let names: [SearchField]
    let people: [SearchField]
    let genres: [String]
    let countries: [String]
    let isAnime: Bool
    /// Key of AniList titles (`AnimeTitles`).
    let titleKey: String

    /// `people`: fields already made, by name (the same actors come back in many titles).
    init(item: PlexItem, section: String, people known: inout [String: SearchField]) {
        self.item = item
        self.section = section
        var titles = [SearchField(item.title)].compactMap { $0 }
        if let original = SearchField(item.originalTitle), original.text != titles.first?.text { titles.append(original) }
        self.titles = titles
        let own = Set(titles.map(\.compact))
        names = AnimeNames.shared.names(of: item).compactMap { SearchField($0) }.filter { !own.contains($0.compact) }
        people = (item.roles + item.directors).prefix(8).compactMap { person in
            if let field = known[person.tag] { return field }
            let field = SearchField(person.tag)
            known[person.tag] = field
            return field
        }
        genres = item.genres.map { SearchText.normalize($0.tag) }
        countries = item.countries.map { SearchText.normalize($0.tag) }
        isAnime = AnimeClassifier.isAnime(item)
        titleKey = AnimeTitles.key(for: item)
    }

    /// A library's entries.
    static func make(_ items: [PlexItem], section: String) -> [SearchEntry] {
        var people: [String: SearchField] = [:]
        return items.map { SearchEntry(item: $0, section: section, people: &people) }
    }

    func textScore(_ query: SearchQuery, aliases: [String: [SearchField]]) -> Int {
        var best = 0
        for (i, title) in titles.enumerated() {
            best = max(best, SearchMatch.score(query, title) - (i == 0 ? 0 : 5))
            if best >= 1000 { return best }
        }
        for name in names {
            best = max(best, SearchMatch.score(query, name) - 10)
        }
        for alias in aliases[titleKey] ?? [] {
            best = max(best, SearchMatch.score(query, alias) - 10)
        }
        // Cast and director: a name typed fully enough, ranked after titles.
        if best < 400, query.field.compact.count >= 4 {
            for person in people {
                let s = SearchMatch.score(query, person)
                let ranked = s >= 800 ? 320 : (s >= 600 ? 300 : (s >= 450 ? 260 : (s >= 400 ? 240 : 0)))
                best = max(best, ranked)
            }
        }
        return best
    }
}

// MARK: - Kinds (genre, country, year, movie / show, anime)

struct SearchIntent {
    var type: String?
    var anime = false
    /// Every group must match (any term of a group, inside a normalized tag).
    var genres: [[String]] = []
    var countries: [[String]] = []
    var years: ClosedRange<Int>?
    /// Words that aren't a kind: matched against titles.
    var rest: [String] = []

    var hasFilters: Bool { type != nil || anime || !genres.isEmpty || !countries.isEmpty || years != nil }

    func matches(_ e: SearchEntry) -> Bool {
        if let type {
            let fits = type == "show" ? e.item.isShow : e.item.type == "movie"
            if !fits { return false }
        }
        if anime && !e.isAnime { return false }
        for group in genres where !e.genres.contains(where: { tag in group.contains { tag.contains($0) } }) {
            return false
        }
        for group in countries where !e.countries.contains(where: { tag in group.contains { tag.contains($0) } }) {
            return false
        }
        if let years {
            guard let year = e.item.year, years.contains(year) else { return false }
        }
        return true
    }

    static func parse(_ words: [String]) -> SearchIntent {
        var intent = SearchIntent()
        var i = 0
        while i < words.count {
            var matched = false
            for length in stride(from: min(3, words.count - i), through: 1, by: -1) {
                let phrase = words[i..<(i + length)].joined(separator: " ")
                guard let term = lookup(phrase) else { continue }
                switch term {
                case .kind(let t): intent.type = t
                case .anime: intent.anime = true
                case .genre(let tags): intent.genres.append(tags)
                case .country(let tags): intent.countries.append(tags)
                case .years(let range): intent.years = range
                case .filler: break
                }
                i += length
                matched = true
                break
            }
            if !matched {
                intent.rest.append(words[i])
                i += 1
            }
        }
        // Filler words («ابي», «عن») count only next to a kind; alone they're a title.
        if !intent.hasFilters { intent.rest = words }
        return intent
    }

    private enum Term {
        case kind(String), anime, genre([String]), country([String]), years(ClosedRange<Int>), filler
    }

    /// A word or phrase, also with a leading «و» («وانمي») or «ال» («الكوميدي»).
    private static func lookup(_ phrase: String) -> Term? {
        if let term = vocabulary[phrase] ?? year(phrase) { return term }
        for prefix in ["و", "ال", "وال"] where phrase.hasPrefix(prefix) && phrase.count > prefix.count + 2 {
            if let term = vocabulary[String(phrase.dropFirst(prefix.count))] { return term }
        }
        return nil
    }

    private static func year(_ word: String) -> Term? {
        if word.count == 4, let y = Int(word), (1920...2100).contains(y) { return .years(y...y) }
        // «90s», «1990s».
        if word.hasSuffix("s"), let n = Int(word.dropLast()) {
            if n % 10 == 0, (20...90).contains(n) { return .years((1900 + n)...(1909 + n)) }
            if n % 10 == 0, (1920...2090).contains(n) { return .years(n...(n + 9)) }
        }
        return nil
    }

    private static let vocabulary: [String: Term] = {
        var table: [String: Term] = [:]
        func add(_ words: [String], _ term: Term) {
            for w in words { table[SearchText.normalize(w)] = term }
        }
        func tags(_ list: [String]) -> [String] { list.map(SearchText.normalize) }

        add(["مسلسل", "مسلسلات", "سيريس", "series", "show", "shows", "tv show", "tv shows", "tv"], .kind("show"))
        add(["فيلم", "فلم", "افلام", "أفلام", "movie", "movies", "film", "films"], .kind("movie"))
        add(["انمي", "أنمي", "انيمي", "انمى", "anime"], .anime)

        let genres: [([String], [String])] = [
            (["كوميدي", "كوميديا", "كوميديه", "كوميدية", "مضحك", "مضحكه", "مضحكة", "comedy", "comedies", "funny"],
             ["comedy", "كوميدي", "كوميديا"]),
            (["اكشن", "أكشن", "آكشن", "اكشين", "action"], ["action", "اكشن"]),
            (["مغامره", "مغامرة", "مغامرات", "adventure"], ["adventure", "مغامر"]),
            (["دراما", "درامي", "دراميه", "درامية", "drama"], ["drama", "دراما"]),
            (["رعب", "مرعب", "مرعبه", "مرعبة", "horror", "scary"], ["horror", "رعب"]),
            (["اثاره", "إثارة", "تشويق", "thriller", "suspense"], ["thriller", "suspense", "اثاره", "تشويق"]),
            (["جريمه", "جريمة", "جرائم", "اجرامي", "إجرامي", "crime"], ["crime", "جريمه"]),
            (["غموض", "غامض", "mystery"], ["mystery", "غموض"]),
            (["رومانسي", "رومانسيه", "رومانسية", "رومانس", "romance", "romantic"], ["romance", "رومانس"]),
            (["فانتازيا", "فنتازيا", "فانتزي", "خيالي", "خياليه", "خيالية", "fantasy"], ["fantasy", "فانتازيا"]),
            (["خيال علمي", "sci fi", "scifi", "science fiction"], ["sci fi", "science fiction", "خيال علمي"]),
            (["كرتون", "رسوم متحركه", "رسوم متحركة", "انميشن", "أنميشن", "animation", "cartoon", "cartoons"],
             ["animation", "رسوم متحركه"]),
            (["وثائقي", "وثائقيه", "وثائقية", "وثائقيات", "documentary", "documentaries"], ["documentary", "وثائقي"]),
            (["عائلي", "عائليه", "عائلية", "family"], ["family", "عائلي"]),
            (["اطفال", "أطفال", "kids", "children"], ["kids", "children", "اطفال"]),
            (["تاريخي", "تاريخيه", "تاريخية", "history", "historical"], ["history", "تاريخ"]),
            (["حرب", "حروب", "حربي", "war"], ["war", "حرب"]),
            (["موسيقي", "موسيقى", "musical", "music"], ["music", "موسيقي"]),
            (["رياضه", "رياضة", "رياضي", "رياضيه", "رياضية", "sport", "sports"], ["sport", "رياضه"]),
            (["ويسترن", "كاوبوي", "western"], ["western", "ويسترن"]),
            (["سيره ذاتيه", "سيرة ذاتية", "biography"], ["biography", "سيره"]),
            (["تلفزيون الواقع", "برامج الواقع", "reality"], ["reality", "واقع"]),
            (["فنون قتاليه", "فنون قتالية", "قتال", "martial arts"], ["martial arts", "فنون قتاليه"]),
        ]
        for (words, list) in genres { add(words, .genre(tags(list))) }

        let countries: [([String], [String])] = [
            (["كوري", "كوريه", "كورية", "korean", "kdrama"], ["korea", "كوريا"]),
            (["ياباني", "يابانيه", "يابانية", "japanese"], ["japan", "اليابان"]),
            (["تركي", "تركيه", "تركية", "turkish"], ["turkey", "turkiye", "تركيا"]),
            (["هندي", "هنديه", "هندية", "بوليوود", "indian", "bollywood"], ["india", "الهند"]),
            (["صيني", "صينيه", "صينية", "chinese"], ["china", "hong kong", "taiwan", "الصين"]),
            (["امريكي", "أمريكي", "امريكيه", "أمريكية", "american"], ["united states", "usa", "امريك"]),
            (["بريطاني", "بريطانيه", "بريطانية", "british"], ["united kingdom", "uk", "britain", "بريطان"]),
            (["فرنسي", "فرنسيه", "فرنسية", "french"], ["france", "فرنسا"]),
            (["اسباني", "إسباني", "اسبانيه", "إسبانية", "spanish"], ["spain", "اسبانيا"]),
            (["مصري", "مصريه", "مصرية", "egyptian"], ["egypt", "مصر"]),
            (["سعودي", "سعوديه", "سعودية", "saudi"], ["saudi", "السعوديه"]),
            (["خليجي", "خليجيه", "خليجية"],
             ["saudi", "kuwait", "united arab emirates", "qatar", "bahrain", "oman", "السعوديه", "الكويت", "الامارات"]),
            (["عربي", "عربيه", "عربية", "arabic", "arab"],
             ["saudi", "egypt", "kuwait", "united arab emirates", "qatar", "bahrain", "oman", "syria", "lebanon",
              "jordan", "iraq", "morocco", "tunisia", "algeria", "السعوديه", "مصر", "الكويت", "الامارات", "سوريا",
              "لبنان", "الاردن", "العراق"]),
        ]
        for (words, list) in countries { add(words, .country(tags(list))) }

        let decades: [(String, ClosedRange<Int>)] = [
            ("الستينات", 1960...1969), ("السبعينات", 1970...1979), ("الثمانينات", 1980...1989),
            ("التسعينات", 1990...1999), ("الالفينات", 2000...2009),
        ]
        for (word, range) in decades {
            add([word, String(word.dropFirst(2))], .years(range))
        }

        add(["ابي", "ابغى", "ابغا", "اريد", "أريد", "ودي", "عطني", "ابحث", "شي", "شيء", "عن", "من", "في",
             "حلو", "حلوه", "زين", "نوع", "about", "with", "some"], .filler)
        return table
    }()
}

// MARK: - Running a search

enum SmartSearch {
    /// Movies and shows for `raw`, best first.
    static func run(_ raw: String, entries: [SearchEntry], aliases: [String: [SearchField]], limit: Int) -> [PlexItem] {
        guard let query = SearchQuery(raw) else { return [] }
        let byTitle = scored(entries) { $0.textScore(query, aliases: aliases) }
        let intent = SearchIntent.parse(query.field.words)
        guard intent.hasFilters else { return unique(ranked(byTitle), limit) }

        // A title matching the whole query still comes first («Comedy Bang! Bang!», «1917»).
        let titles = ranked(byTitle.filter { $0.1 >= 650 })
        let rest = intent.rest.isEmpty ? nil : SearchQuery(intent.rest.joined(separator: " "))
        let fitting = entries.filter(intent.matches)
        let kinds = rest.map { rest in scored(fitting) { $0.textScore(rest, aliases: aliases) } } ?? fitting.map { ($0, 0) }
        return unique(titles + ranked(kinds), limit)
    }

    /// Entries with a score, in order, worked out on every core. Empty once the task is
    /// cancelled (another letter was typed).
    private static func scored(_ entries: [SearchEntry], _ score: @Sendable (SearchEntry) -> Int) -> [(SearchEntry, Int)] {
        let size = 1024
        let count = (entries.count + size - 1) / size
        guard count > 0 else { return [] }
        // A thread of `concurrentPerform` isn't the task's: the flag is read here.
        let cancelled = withUnsafeCurrentTask { $0 }
        var parts = [[(SearchEntry, Int)]](repeating: [], count: count)
        parts.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer
            DispatchQueue.concurrentPerform(iterations: count) { k in
                if cancelled?.isCancelled == true { return }
                var found: [(SearchEntry, Int)] = []
                for entry in entries[(k * size)..<min((k + 1) * size, entries.count)] {
                    let s = score(entry)
                    if s > 0 { found.append((entry, s)) }
                }
                out[k] = found
            }
        }
        return cancelled?.isCancelled == true ? [] : parts.flatMap { $0 }
    }

    /// Best match, then best rated, then newest.
    private static func ranked(_ list: [(SearchEntry, Int)]) -> [PlexItem] {
        list.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            let ra = a.0.item.audienceRating ?? a.0.item.rating ?? 0
            let rb = b.0.item.audienceRating ?? b.0.item.rating ?? 0
            if ra != rb { return ra > rb }
            return (a.0.item.year ?? 0) > (b.0.item.year ?? 0)
        }.map { $0.0.item }
    }

    private static func unique(_ items: [PlexItem], _ limit: Int) -> [PlexItem] {
        Array(items.uniqued().prefix(limit))
    }
}

// MARK: - Suggestions

/// Kinds to search by with one press on the empty search screen (typing them works the same).
enum SearchSuggestions {
    static let kinds = [
        "أكشن", "كوميدي", "دراما", "رعب", "إثارة", "جريمة", "خيال علمي", "فانتازيا", "رومانسي",
        "غموض", "أنمي", "رسوم متحركة", "وثائقي", "عائلي", "مسلسل كوري",
    ]
}
