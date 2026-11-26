import Foundation

/// «أفلام مشابهة» / «ذات صلة» / «لأنك شاهدت…»: what to show next to a title.
///
/// Plex's /related answers with groups (hubs) in no useful order: on this server most titles start
/// with big Kometa collections («أفضل أفلام 2019», «أفلام من عمر 18 سنة وأكثر», «BBC Two»…),
/// six titles each in alphabetical order, so the row looked random. The groups are ranked here,
/// those big lists dropped; anime get AniList's recommendations first; and when that leaves
/// little, titles of the same library sharing the most genres fill in (on the device).
enum RelatedTitles {
    /// How many titles make a row worth showing without filling in from genres.
    static let enough = 8

    // MARK: Plex groups

    enum Strength { case strong, weak }

    /// Plex's groups, best first: similar, same director, a small complete collection (a
    /// series: «Dirty Harry», «Ne Zha»), then same actors and same network. Collections with more
    /// titles than Plex sent are big lists, not a series: dropped.
    static func ranked(_ hubs: [PlexHub], excluding key: String) -> (strong: [PlexItem], weak: [PlexItem]) {
        func rank(_ hub: PlexHub) -> Int? {
            let kind = (hub.context ?? hub.hubIdentifier).lowercased()
            if kind.contains("similar") { return 0 }
            if kind.contains("same.director") { return 1 }
            if kind.contains("collection") { return hub.more ? nil : 2 }
            if kind.contains("same.actor") { return 3 }
            if kind.contains("morefromnetwork") || kind.contains("same.studio") { return 4 }
            return 5
        }
        let ordered = hubs.enumerated()
            .compactMap { offset, hub in rank(hub).map { (rank: $0, offset: offset, hub: hub) } }
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
        var seen: Set<String> = [key]
        var strong: [PlexItem] = []
        var weak: [PlexItem] = []
        for entry in ordered {
            for item in entry.hub.items where (item.type == "movie" || item.type == "show")
                && seen.insert(item.ratingKey).inserted {
                if entry.rank <= 2 { strong.append(item) } else { weak.append(item) }
            }
        }
        return (strong, weak)
    }

    // MARK: Genres

    /// Genres every title of a kind shares, which say nothing about it.
    private static let generic: Set<String> = ["animation", "رسوم متحركة", "anime", "أنمي"]

    /// Titles of the same library sharing the most genres with `item` (anime: also the app's own
    /// anime genres, إيسيكاي، شونين…), a bonus for the same studio, then by rating.
    static func byGenre(for item: PlexItem, in library: [PlexItem], anime: AnimeIndex?,
                        limit: Int = 20) -> [PlexItem] {
        func tags(_ title: PlexItem) -> Set<String> {
            var set = Set(title.genres.map { $0.tag.lowercased() }).subtracting(generic)
            if let anime, let entry = anime.entry(title) { set.formUnion(entry.genres.map { "a:" + $0 }) }
            return set
        }
        let own = tags(item)
        guard !own.isEmpty else { return [] }
        // Two shared genres at least, unless the title only has one.
        let needed = min(2, own.count)
        let studio = item.studio?.lowercased()
        var scored: [(item: PlexItem, score: Double, rating: Double)] = []
        for candidate in library where candidate.ratingKey != item.ratingKey && candidate.type == item.type {
            let shared = tags(candidate).intersection(own).count
            guard shared >= needed else { continue }
            var score = Double(shared)
            if let studio, candidate.studio?.lowercased() == studio { score += 1.5 }
            scored.append((candidate, score, candidate.audienceRating ?? candidate.rating ?? 0))
        }
        return scored
            .sorted { ($0.score, $0.rating) > ($1.score, $1.rating) }
            .prefix(limit)
            .map(\.item)
    }

    // MARK: Together

    /// The row: anime → AniList, Plex's strong groups, genres, then the rest; others → Plex's
    /// strong groups, actors / network, then genres when that's short.
    static func combine(item: PlexItem, isAnime: Bool, plex: (strong: [PlexItem], weak: [PlexItem]),
                        aniList: [PlexItem], genres: () -> [PlexItem]) -> [PlexItem] {
        var seen: Set<String> = [item.ratingKey]
        var out: [PlexItem] = []
        func add(_ items: [PlexItem]) {
            for title in items where seen.insert(title.ratingKey).inserted { out.append(title) }
        }
        add(aniList)
        add(plex.strong)
        if isAnime {
            // Voice actors' lists come back alphabetical: genres first.
            if out.count < enough { add(genres()) }
            if out.count < enough { add(plex.weak) }
        } else {
            add(plex.weak)
            if out.count < enough { add(genres()) }
        }
        return out
    }
}
