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
    static let generic: Set<String> = ["animation", "رسوم متحركة", "anime", "أنمي"]

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

    /// The row: the same series first; anime → AniList, Plex's strong groups, genres, then the
    /// rest; others → Plex's strong groups, actors / network, then genres when that's short.
    static func combine(item: PlexItem, isAnime: Bool, series: [PlexItem],
                        plex: (strong: [PlexItem], weak: [PlexItem]),
                        aniList: [PlexItem], genres: () -> [PlexItem]) -> [PlexItem] {
        var seen: Set<String> = [item.ratingKey]
        var out: [PlexItem] = []
        func add(_ items: [PlexItem]) {
            for title in items where seen.insert(title.ratingKey).inserted { out.append(title) }
        }
        add(series)
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

// MARK: - Same series

/// Titles of the same series across every library on the device, by any of their names
/// (English, Japanese in Latin letters, Arabic…): «Attack on Titan: Requiem» → the «Shingeki no
/// Kyojin» series and its other films; «El Camino: A Breaking Bad Movie» ↔ «Breaking Bad».
/// Built once per library size, then a lookup.
actor SeriesIndex {
    static let shared = SeriesIndex()

    private var built: (count: Int, map: [String: [PlexItem]])?

    /// Same-series titles of `item` among `all`, oldest first.
    func matches(for item: PlexItem, in all: [PlexItem]) async -> [PlexItem] {
        let aliases = await AnimeTitles.shared.aliasesByKey()
        if built?.count != all.count {
            var map: [String: [PlexItem]] = [:]
            for title in all where title.type == "movie" || title.type == "show" {
                for key in Self.keys(Self.names(of: title, aliases: aliases)) { map[key, default: []].append(title) }
            }
            built = (all.count, map)
        }
        guard let map = built?.map else { return [] }
        var seen: Set<String> = [item.ratingKey]
        if let guid = item.guid { seen.insert(guid) }
        // A different work with the very same name («Underground» and «Underground») is no series.
        let ownName = SearchText.normalize(item.title)
        var found: [PlexItem] = []
        for key in Self.keys(Self.names(of: item, aliases: aliases)) {
            for title in map[key] ?? [] where SearchText.normalize(title.title) != ownName
                && seen.insert(title.ratingKey).inserted
                && (title.guid.map { seen.insert($0).inserted } ?? true) {
                found.append(title)
            }
        }
        return found.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
    }

    private static func names(of title: PlexItem, aliases: [String: [String]]) -> [String] {
        [title.title, title.originalTitle].compactMap { $0 }
            + AnimeNames.shared.names(of: title)
            + (aliases[AnimeTitles.key(for: title)] ?? [])
    }

    /// The series names a title stands for: its whole name without «Movie», a year or a part
    /// number, the part before «:» / « - », and «X» of «…: A X Movie». Only names of two words or
    /// six letters at least, so «Mom» never pairs with «Mom and Dad».
    static func keys(_ names: [String]) -> Set<String> {
        var out = Set<String>()
        for name in names {
            var candidates = [name]
            for separator in [":", " - ", " – ", " — ", "："] {
                if let range = name.range(of: separator) {
                    candidates.append(String(name[..<range.lowerBound]))
                    // The part after only as «A X Movie» («Requiem» alone would pair with anything).
                    let after = String(name[range.upperBound...])
                    if let last = SearchText.normalize(after).split(separator: " ").last,
                       last == "movie" || last == "film" { candidates.append(after) }
                }
            }
            for candidate in candidates {
                guard let key = seriesName(candidate) else { continue }
                out.insert(key)
            }
        }
        return out
    }

    private static let trailing: Set<String> = ["movie", "the movie", "film", "the film", "ii", "iii", "iv", "v", "vi",
                                                "season", "series", "special", "ova", "ona"]

    private static func seriesName(_ raw: String) -> String? {
        var words = SearchText.normalize(raw).split(separator: " ").map(String.init)
        // «A Breaking Bad Movie» → «breaking bad».
        if words.first == "a" || words.first == "the" { words.removeFirst() }
        while let last = words.last, trailing.contains(last) || Int(last) != nil
                || (words.count >= 2 && trailing.contains(words.suffix(2).joined(separator: " "))) {
            if words.count >= 2, trailing.contains(words.suffix(2).joined(separator: " ")) {
                words.removeLast(2)
            } else {
                words.removeLast()
            }
        }
        let joined = words.joined(separator: " ")
        let letters = joined.replacingOccurrences(of: " ", with: "").count
        guard words.count >= 2 || letters >= 6 else { return nil }
        return joined
    }
}
