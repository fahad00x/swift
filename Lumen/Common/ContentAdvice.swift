import Foundation

/// What a title's age rating means, in Arabic: «R» → «للكبار (+١٧): قد يحتوي عنف أو مشاهد
/// جنسية أو ألفاظ قوية». General to the rating, not to the title (that's `ContentFlag`).
enum RatingGuide {
    /// `rating` as `ArabicFormat.contentRating` returns it (upper-cased, country prefix removed).
    static func explain(_ rating: String?) -> String? {
        guard let r = rating?.uppercased(), !r.isEmpty else { return nil }
        if let known = named[r] { return known }
        if ["NR", "NOT RATED", "UNRATED", "N/A"].contains(r) { return "غير مصنّف: ما له تصنيف عمري رسمي" }
        // Ages: «15», «+18», «12A», «MA15+», «R18», «FSK 16».
        let digits = r.filter(\.isNumber)
        guard let age = Int(digits), age <= 21 else { return nil }
        return byAge(age)
    }

    private static func byAge(_ age: Int) -> String {
        let plus = "+" + ArabicFormat.digits(age)
        switch age {
        case ..<7: return "لكل الأعمار"
        case 7...11: return "فوق \(ArabicFormat.digits(age)) (\(plus)): قد يحتوي مشاهد مخيفة أو عنف خفيف"
        case 12...15: return "فوق \(ArabicFormat.digits(age)) (\(plus)): قد يحتوي عنف أو ألفاظ أو إيحاءات"
        case 16...17: return "فوق \(ArabicFormat.digits(age)) (\(plus)): قد يحتوي عنف أو مشاهد جنسية أو ألفاظ قوية"
        default: return "للبالغين فقط (\(plus)): محتوى للكبار"
        }
    }

    private static let named: [String: String] = [
        // US films
        "G": "لكل الأعمار",
        "PG": "إرشاد عائلي: بعض المحتوى قد لا يناسب الأطفال",
        "PG-13": "فوق ١٣ (+١٣): قد يحتوي عنف أو ألفاظ أو إيحاءات",
        "R": "للكبار (+١٧): قد يحتوي عنف أو مشاهد جنسية أو ألفاظ قوية أو مخدرات",
        "NC-17": "للبالغين فقط (+١٨): محتوى جنسي أو عنف صريح",
        // US TV
        "TV-Y": "مناسب للأطفال",
        "TV-Y7": "فوق ٧ (+٧): قد يحتوي عنف خيالي خفيف",
        "TV-Y7-FV": "فوق ٧ (+٧): فيه عنف خيالي",
        "TV-G": "لكل الأعمار",
        "TV-PG": "إرشاد عائلي: قد يحتوي ألفاظ أو إيحاءات خفيفة",
        "TV-14": "فوق ١٤ (+١٤): قد يحتوي عنف أو ألفاظ أو إيحاءات",
        "TV-MA": "للكبار (+١٧): قد يحتوي عنف صريح أو مشاهد جنسية أو ألفاظ قوية",
        // UK
        "U": "لكل الأعمار",
        "UC": "مناسب للأطفال",
        "12A": "فوق ١٢ (+١٢): قد يحتوي عنف أو ألفاظ أو إيحاءات",
        "R18": "للبالغين فقط (+١٨): محتوى جنسي صريح",
        // Australia
        "M": "للناضجين (+١٥): قد يحتوي عنف أو ألفاظ",
        "MA15+": "فوق ١٥ (+١٥): قد يحتوي عنف أو مشاهد جنسية أو ألفاظ قوية",
        "R18+": "للبالغين فقط (+١٨): محتوى للكبار",
        "X18+": "للبالغين فقط (+١٨): محتوى جنسي صريح",
    ]
}

/// Something a title contains, from TMDB's keywords and the rating boards' reasons.
enum ContentFlag: String, CaseIterable, Codable, Hashable {
    case nudity, sex, gore, violence, language, drugs, alcohol, smoking, suicide, fear

    var title: String {
        switch self {
        case .nudity: return "عري"
        case .sex: return "مشاهد جنسية"
        case .gore: return "مشاهد دموية"
        case .violence: return "عنف"
        case .language: return "ألفاظ"
        case .drugs: return "مخدرات"
        case .alcohol: return "كحول"
        case .smoking: return "تدخين"
        case .suicide: return "انتحار"
        case .fear: return "مشاهد مخيفة"
        }
    }

    /// SF Symbol for the chip.
    var symbol: String {
        switch self {
        case .nudity: return "eye.slash.fill"
        case .sex: return "heart.slash.fill"
        case .gore: return "drop.fill"
        case .violence: return "bolt.fill"
        case .language: return "text.bubble.fill"
        case .drugs: return "pills.fill"
        case .alcohol: return "wineglass.fill"
        case .smoking: return "smoke.fill"
        case .suicide: return "exclamationmark.triangle.fill"
        case .fear: return "theatermasks.fill"
        }
    }

    /// Words / phrases (lower-case, matched as whole words) that point to this flag.
    private var patterns: [String] {
        switch self {
        case .nudity: return ["nudity", "nude", "naked", "topless", "full frontal", "skinny dipping"]
        case .sex: return ["sex", "sex scene", "sexual", "sexuality", "sexual content", "erotic", "erotica",
                           "softcore", "rape", "sexual violence", "sexual assault", "prostitution", "prostitute", "orgy"]
        case .gore: return ["gore", "gory", "bloody", "blood splatter", "splatter", "dismemberment", "decapitation",
                            "mutilation", "graphic violence", "body horror", "cannibalism", "injury detail"]
        case .violence: return ["violence", "violent", "murder", "massacre", "shootout", "torture", "brutality",
                                "serial killer", "execution", "fight", "fighting", "assault", "threat", "war"]
        case .language: return ["profanity", "swearing", "strong language", "foul language", "vulgarity",
                                "language", "crude humor", "crude language", "obscenity"]
        case .drugs: return ["drug", "drugs", "drug use", "drug abuse", "drug addiction", "cocaine", "heroin",
                             "marijuana", "methamphetamine", "overdose", "drug dealer", "drug trafficking"]
        case .alcohol: return ["alcohol", "alcoholism", "alcoholic", "drunk", "drunkenness", "drinking"]
        case .smoking: return ["smoking", "cigarette", "cigarettes", "tobacco"]
        case .suicide: return ["suicide", "suicide attempt", "self-harm", "self harm"]
        case .fear: return ["fear", "frightening", "frightening scenes", "jump scare", "demon", "demonic possession",
                            "possession", "exorcism", "haunting", "haunted house", "supernatural horror"]
        }
    }

    /// Flags found in TMDB keywords and rating descriptors, in the order above (most
    /// sensitive first); «عنف» is dropped when «مشاهد دموية» already says more.
    static func detect(in terms: [String]) -> [ContentFlag] {
        let lowered = terms.map { $0.lowercased() }
        var found = allCases.filter { flag in
            lowered.contains { term in flag.patterns.contains { matches(term, $0) } }
        }
        if found.contains(.gore) { found.removeAll { $0 == .violence } }
        return found
    }

    private static let exactOnly: Set<String> = ["language", "fear", "threat"]

    /// `phrase` is the term itself or a whole-word part of it («female nudity» ∋ «nudity»,
    /// but «sexism» ∌ «sex»).
    private static func matches(_ term: String, _ phrase: String) -> Bool {
        if term == phrase { return true }
        // Too broad inside longer keywords («sign language», «fear of heights», «threat assessment»).
        if exactOnly.contains(phrase) { return false }
        guard let range = term.range(of: phrase) else { return false }
        let before = range.lowerBound == term.startIndex ? nil : term[term.index(before: range.lowerBound)]
        let after = range.upperBound == term.endIndex ? nil : term[range.upperBound]
        func isBoundary(_ c: Character?) -> Bool { c == nil || !(c!.isLetter || c!.isNumber) }
        return isBoundary(before) && isBoundary(after)
    }
}
