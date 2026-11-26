import Foundation

/// «#، A–Z، ا–ي» beside a library sorted by name: where each letter starts in the listing.
struct LetterIndex: Equatable {
    struct Entry: Equatable, Identifiable {
        let letter: String
        /// Position of its first title in the server's (or the device copy's) listing.
        let offset: Int
        var id: String { letter }
    }

    /// In listing order, one entry per letter.
    let entries: [Entry]

    /// Letter a title is filed under: A–Z, an Arabic letter (أ إ آ ء → ا, ؤ → و, ى ئ → ي), else «#».
    static func letter(of title: String) -> String {
        guard let first = title.trimmingCharacters(in: .whitespacesAndNewlines).first else { return "#" }
        let upper = String(first).uppercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en"))
        if let scalar = upper.unicodeScalars.first, upper.count == 1, ("A"..."Z").contains(String(scalar)) { return upper }
        switch first {
        case "أ", "إ", "آ", "ٱ", "ء": return "ا"
        case "ة": return "ه"
        case "ؤ": return "و"
        case "ى", "ئ": return "ي"
        default: break
        }
        if let scalar = String(first).unicodeScalars.first, (0x0621...0x064A).contains(scalar.value) { return String(first) }
        return "#"
    }

    /// From (letter-ish key, count) pairs in listing order, e.g. Plex's `firstCharacter`.
    init(counts: [(key: String, size: Int)]) {
        var entries: [Entry] = []
        var seen = Set<String>()
        var offset = 0
        for (key, size) in counts {
            let letter = Self.letter(of: key)
            if seen.insert(letter).inserted { entries.append(Entry(letter: letter, offset: offset)) }
            offset += size
        }
        self.entries = entries
    }

    /// From the titles in listing order.
    init(titles: [String]) {
        var entries: [Entry] = []
        var seen = Set<String>()
        for (offset, title) in titles.enumerated() {
            let letter = Self.letter(of: title)
            if seen.insert(letter).inserted { entries.append(Entry(letter: letter, offset: offset)) }
        }
        self.entries = entries
    }
}
