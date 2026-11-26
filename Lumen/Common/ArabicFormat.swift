import Foundation

// MARK: - Arabic formatting
//
// Every number, date, time and composed line shown in the UI goes through here, so both apps
// show Arabic-Indic digits, the same separator, and English titles that don't break the
// right-to-left order of the sentence around them.

enum ArabicFormat {
    private static let arabicDigits: [Character] = ["٠", "١", "٢", "٣", "٤", "٥", "٦", "٧", "٨", "٩"]

    static func digits(_ n: Int) -> String { digits(String(n)) }

    /// A count with thousands separators: "١٦٬٩٢٤". Not for years or episode numbers.
    static func count(_ n: Int) -> String {
        let plain = String(abs(n))
        var grouped = ""
        for (i, c) in plain.enumerated() {
            if i > 0, (plain.count - i) % 3 == 0 { grouped.append("٬") }
            grouped.append(c)
        }
        return (n < 0 ? "-" : "") + digits(grouped)
    }

    static func digits(_ s: String) -> String {
        String(s.map { c in c.wholeNumberValue.map { arabicDigits[$0] } ?? c })
    }

    // MARK: File sizes and bitrates

    /// «5.93 GB», «921 MB»: sizes stay in English (digits and unit, decimal units like the
    /// Files app), isolated so they keep their order inside an Arabic line.
    static func fileSize(_ bytes: Int64) -> String {
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(max(0, bytes)) / 1000
        var unit = 0
        while value >= 1000, unit < units.count - 1 { value /= 1000; unit += 1 }
        return isolated(englishNumber(value) + " " + units[unit])
    }

    /// «8.3 Mbps», «750 Kbps»: in English like sizes.
    static func bitrate(kbps: Int) -> String {
        kbps < 1000 ? isolated("\(kbps) Kbps") : isolated(englishNumber(Double(kbps) / 1000) + " Mbps")
    }

    /// Three significant digits at most, without trailing zeros: 5.93, 61.3, 921, 8.
    private static func englishNumber(_ value: Double) -> String {
        let decimals = value < 10 ? 2 : (value < 100 ? 1 : 0)
        var text = String(format: "%.\(decimals)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    // MARK: Text composition

    /// Separator between parts of a line ("٢٠٢٦  •  ٥٨د"). A bullet with spaces: the middle dot
    /// "·" next to Arabic digits reads as a zero ("م١ · ح٧" ≈ "م١٠ح٧").
    static let separator = "  •  "

    /// Wraps text in First Strong Isolate … Pop Directional Isolate (U+2068 … U+2069), so an
    /// English title inside an Arabic sentence keeps its own order ("Resurrection 'F'" instead
    /// of "'Resurrection 'F") and doesn't reorder the punctuation around it.
    static func isolated(_ text: String) -> String {
        text.isEmpty ? text : "\u{2068}\(text)\u{2069}"
    }

    /// Non-empty parts, each isolated, joined with `separator` (or another separator).
    static func joined(_ parts: [String], separator: String = ArabicFormat.separator) -> String {
        parts.filter { !$0.isEmpty }
            .map(isolated)
            .joined(separator: separator)
    }

    /// Names in a list ("بطولة: …"), each isolated, separated by an Arabic comma.
    static func list(_ names: [String]) -> String {
        joined(names, separator: "، ")
    }

    // MARK: Episodes

    /// "الموسم ١  •  الحلقة ٧" (either part may be missing).
    static func episodeCode(season: Int?, episode: Int?) -> String? {
        let parts = [season.map { "الموسم \(digits($0))" }, episode.map { "الحلقة \(digits($0))" }]
        let code = parts.compactMap { $0 }.joined(separator: separator)
        return code.isEmpty ? nil : code
    }

    /// "م١  •  ح٧" for tight spaces.
    static func shortEpisodeCode(season: Int?, episode: Int?) -> String? {
        let parts = [season.map { "م\(digits($0))" }, episode.map { "ح\(digits($0))" }]
        let code = parts.compactMap { $0 }.joined(separator: separator)
        return code.isEmpty ? nil : code
    }

    /// "الموسم ١  •  الحلقة ٧ — <title>", the title isolated.
    static func episodeLine(season: Int?, episode: Int?, title: String?) -> String {
        let code = episodeCode(season: season, episode: episode)
        let name = title.flatMap { $0.isEmpty ? nil : isolated($0) }
        return [code, name].compactMap { $0 }.joined(separator: " — ")
    }

    // MARK: Durations, clocks, dates

    /// "٥٨د" / "١س ٢٠د"
    static func duration(ms: Int) -> String {
        let minutes = max(1, ms / 60_000)
        let h = minutes / 60, m = minutes % 60
        if h > 0 { return m > 0 ? "\(digits(h))س \(digits(m))د" : "\(digits(h))س" }
        return "\(digits(m))د"
    }

    /// Player position: "٢:١٣" / "١:٠٢:١٣".
    static func clock(seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds)) : 0
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let text = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        return digits(text)
    }

    /// Arabic locale with Arabic-Indic digits (plain "ar" may use Latin digits).
    static let locale = Locale(identifier: "ar@numbers=arab")

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "d MMMM y"
        return f
    }()

    /// Same as `dateFormatter`, for Plex dates (calendar days, parsed as UTC).
    private static let plexDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d MMMM y"
        return f
    }()

    private static let plexDateParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "١:١١ م"
    static func time(_ date: Date) -> String {
        digits(timeFormatter.string(from: date))
    }

    /// "٢٢ نوفمبر ٢٠٢٦"
    static func date(_ date: Date) -> String {
        digits(dateFormatter.string(from: date))
    }

    /// Plex "yyyy-MM-dd" (originallyAvailableAt) → "٢٢ نوفمبر ٢٠٢٦"; the digits only if it doesn't parse.
    static func date(plex value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let prefix = String(value.prefix(10))
        guard let parsed = plexDateParser.date(from: prefix) else { return digits(value) }
        return digits(plexDateFormatter.string(from: parsed))
    }

    /// "★ ٨٫١"
    static func score(_ value: Double) -> String {
        let text = String(format: "%.1f", value).replacingOccurrences(of: ".", with: "٫")
        return "★ " + digits(text)
    }

    // MARK: Metadata clean-up

    /// Plex summaries (anime agents especially) often end with "---" and a source note, or
    /// with stray dashes. Cuts at the first "---" that starts a line or a passage and trims
    /// trailing spaces and dashes.
    static func summary(_ text: String?) -> String? {
        guard var s = text else { return nil }
        var searchStart = s.startIndex
        while let range = s.range(of: "---", range: searchStart..<s.endIndex) {
            let atBoundary = range.lowerBound == s.startIndex || s[s.index(before: range.lowerBound)].isWhitespace
            if atBoundary {
                s = String(s[..<range.lowerBound])
                break
            }
            searchStart = range.upperBound
        }
        let trailing = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—_"))
        while let last = s.unicodeScalars.last, trailing.contains(last) {
            s.unicodeScalars.removeLast()
        }
        return s.isEmpty ? nil : s
    }

    /// Content rating as a short code: "PG-13 - Teens 13 or older" → "PG-13", "us/tv-14" → "TV-14".
    static func contentRating(_ raw: String?) -> String? {
        guard var r = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { return nil }
        if let dash = r.range(of: " - ") { r = String(r[..<dash.lowerBound]) }
        if let slash = r.lastIndex(of: "/") { r = String(r[r.index(after: slash)...]) }
        r = r.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return r.isEmpty ? nil : r
    }

    private static let genres: [String: String] = [
        "action": "أكشن", "adventure": "مغامرة", "action & adventure": "أكشن ومغامرة",
        "animation": "رسوم متحركة", "anime": "أنمي", "biography": "سيرة ذاتية", "comedy": "كوميديا",
        "crime": "جريمة", "documentary": "وثائقي", "drama": "دراما", "family": "عائلي",
        "fantasy": "فانتازيا", "history": "تاريخي", "horror": "رعب", "kids": "أطفال",
        "music": "موسيقى", "musical": "موسيقي", "mystery": "غموض", "news": "أخبار",
        "reality": "واقع", "romance": "رومانسي", "science fiction": "خيال علمي", "sci-fi": "خيال علمي",
        "sci-fi & fantasy": "خيال علمي وفانتازيا", "short": "قصير", "sport": "رياضة", "sports": "رياضة",
        "suspense": "تشويق", "talk": "حواري", "thriller": "إثارة", "war": "حرب",
        "war & politics": "حرب وسياسة", "western": "غربي", "game show": "مسابقات",
        "mini-series": "مسلسل قصير", "tv movie": "فيلم تلفزيوني", "children": "أطفال",
        "action/adventure": "أكشن ومغامرة", "martial arts": "فنون قتالية",
        "动画": "رسوم متحركة", "喜剧": "كوميديا",
        "soap": "دراما يومية", "food": "طبخ", "travel": "سفر", "home and garden": "منزل وحديقة",
    ]

    /// Arabic name for a Plex genre (Plex metadata is usually in English).
    static func genre(_ tag: String) -> String {
        genres[tag.lowercased()] ?? tag
    }

    /// Arabic genre names for display, in order, without repeats: "Sci-Fi & Fantasy" + "Fantasy"
    /// shows only «خيال علمي وفانتازيا», since «فانتازيا» is already a word of it.
    static func genres(_ tags: [String], limit: Int = .max) -> [String] {
        var names: [String] = []
        for name in tags.map(genre) where !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            names.append(name)
        }
        let kept = names.filter { name in
            !names.contains { other in other != name && containsWord(other, name) }
        }
        return Array(kept.prefix(limit))
    }

    /// Whether `phrase` appears in `text` as whole words (an attached «و» counts as a boundary).
    private static func containsWord(_ text: String, _ phrase: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "&" || $0 == "،" || $0 == "," })
            .map(String.init)
        let target = phrase.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !target.isEmpty, words.count > target.count else { return false }
        for start in 0...(words.count - target.count) {
            let match = target.indices.allSatisfy { i in
                let w = words[start + i]
                return w == target[i] || (i == 0 && w.hasPrefix("و") && String(w.dropFirst()) == target[i])
            }
            if match { return true }
        }
        return false
    }
}
