import Foundation

// MARK: - Arabic formatting

enum ArabicFormat {
    private static let arabicDigits: [Character] = ["٠", "١", "٢", "٣", "٤", "٥", "٦", "٧", "٨", "٩"]

    static func digits(_ n: Int) -> String { digits(String(n)) }

    static func digits(_ s: String) -> String {
        String(s.map { c in c.wholeNumberValue.map { arabicDigits[$0] } ?? c })
    }

    /// "٥٨د" / "١س ٢٠د"
    static func duration(ms: Int) -> String {
        let minutes = max(1, ms / 60_000)
        let h = minutes / 60, m = minutes % 60
        if h > 0 { return m > 0 ? "\(digits(h))س \(digits(m))د" : "\(digits(h))س" }
        return "\(digits(m))د"
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
        "soap": "دراما يومية", "food": "طبخ", "travel": "سفر", "home and garden": "منزل وحديقة",
    ]

    /// Arabic name for a Plex genre (Plex metadata is usually in English).
    static func genre(_ tag: String) -> String {
        genres[tag.lowercased()] ?? tag
    }
}
