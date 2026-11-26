import Foundation

/// «الكل • أفلام • مسلسلات» over search results, and the order they are shown in.
enum SearchKind: String, CaseIterable, Identifiable {
    case all, movies, shows

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "الكل"
        case .movies: return "أفلام"
        case .shows: return "مسلسلات"
        }
    }

    /// Shows, their seasons and episodes count as «مسلسلات».
    static func isShow(_ item: PlexItem) -> Bool { item.isShow || item.isSeason || item.isEpisode }

    func filter(_ items: [PlexItem]) -> [PlexItem] {
        switch self {
        case .all: return items
        case .movies: return items.filter { !Self.isShow($0) }
        case .shows: return items.filter(Self.isShow)
        }
    }
}

enum SearchResults {
    /// Titles that are exactly the query (ignoring case and accents) first, the rest in the
    /// order the search gave them: «mom» puts Mom the show and Mom the movie before Mommy.
    static func exactFirst(_ items: [PlexItem], query: String) -> [PlexItem] {
        let q = normalized(query)
        guard !q.isEmpty else { return items }
        let exact = items.filter { normalized($0.cardTitle) == q }
        guard !exact.isEmpty else { return items }
        let keys = Set(exact.map(\.ratingKey))
        return exact + items.filter { !keys.contains($0.ratingKey) }
    }

    /// The kinds to list under their own headers, the one with the best match first.
    static func sections(_ items: [PlexItem]) -> [(kind: SearchKind, items: [PlexItem])] {
        let order: [SearchKind] = items.first.map { SearchKind.isShow($0) } == false ? [.movies, .shows] : [.shows, .movies]
        return order.map { ($0, $0.filter(items)) }.filter { !$0.items.isEmpty }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
