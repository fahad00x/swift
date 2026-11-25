import SwiftUI

// «فلترة»: a library's titles narrowed by any mix of genre, rating, episodes, year, seasons and
// what the profile watched, in a chosen order.
// Every choice is optional. Everything is read on the device, except the library's own genres:
// its listing only carries two per title, so they're asked from the server (and remembered).

/// What the profile chose; nothing chosen = the whole library.
struct FilterCriteria: Equatable {
    /// Arabic genre names (several server tags can share one).
    var genres: Set<String> = []
    /// Several genres: a title needs all of them, or any of them.
    var matchAllGenres = true
    var minRating: Double?
    /// More than / fewer than this many episodes.
    var moreEpisodes: Int?
    var fewerEpisodes: Int?
    var fromYear: Int?
    var toYear: Int?
    /// 5 = five or more.
    var seasons: Set<Int> = []
    var watched: Set<FilterWatched> = []

    var isEmpty: Bool { self == FilterCriteria(matchAllGenres: matchAllGenres) }

    /// Everything but the genres.
    func matches(_ item: PlexItem, rating: Double, specials: Int, status: FilterWatched) -> Bool {
        if !watched.isEmpty, !watched.contains(status) { return false }
        if let minRating, rating < minRating { return false }
        if moreEpisodes != nil || fewerEpisodes != nil {
            guard let leaves = item.leafCount else { return false }
            let count = leaves - specials
            if let moreEpisodes, count <= moreEpisodes { return false }
            if let fewerEpisodes, count >= fewerEpisodes { return false }
        }
        if fromYear != nil || toYear != nil {
            guard let year = item.year else { return false }
            // «من» after «إلى»: the same range, the other way round.
            let ends = [fromYear, toYear].compactMap { $0 }
            if ends.count == 2 {
                guard (ends.min()!...ends.max()!).contains(year) else { return false }
            }
            else if let fromYear, year < fromYear { return false }
            else if let toYear, year > toYear { return false }
        }
        if !seasons.isEmpty {
            guard let children = item.childCount else { return false }
            let count = children - (specials > 0 ? 1 : 0)
            guard seasons.contains(min(count, 5)) else { return false }
        }
        return true
    }
}

/// Where the profile is with a title (always exactly one).
enum FilterWatched: CaseIterable {
    case notStarted, started
    /// Everything out so far, of a show still getting episodes: not finished, nothing to watch
    /// yet. Back to `started` when the next episode comes, `finished` once none comes anymore.
    case upToDate
    case finished

    func title(movies: Bool) -> String {
        switch self {
        case .notStarted: return "لم أشاهده"
        case .started: return movies ? "بدأته ولم أكمله" : "شاهدته ولم أكمله"
        case .upToDate: return "متابع أول بأول"
        case .finished: return movies ? "شاهدته" : "شاهدته وأكملته"
        }
    }

    static func choices(movies: Bool) -> [FilterWatched] {
        movies ? [.notStarted, .finished, .started] : [.notStarted, .finished, .started, .upToDate]
    }
}

/// Order of the results.
struct FilterOrder: Equatable {
    enum Key: CaseIterable {
        case added, title, year, rating
        var title: String {
            switch self {
            case .added: return "أضيف مؤخرًا"
            case .title: return "الاسم"
            case .year: return "السنة"
            case .rating: return "التقييم"
            }
        }
    }

    var key = Key.rating
    var ascending = false

    /// What the direction means for the key.
    var meaning: String {
        switch key {
        case .added: return ascending ? "الأقدم إضافة أولًا" : "الأحدث إضافة أولًا"
        case .title: return ascending ? "من A إلى Z" : "من Z إلى A"
        case .year: return ascending ? "الأقدم أولًا" : "الأحدث أولًا"
        case .rating: return ascending ? "الأقل تقييمًا أولًا" : "الأعلى تقييمًا أولًا"
        }
    }
}

/// The choices of one library and what they match. Kept by the library page, so the choices
/// stay when moving between its tabs.
@MainActor
@Observable
final class LibraryFilterModel {
    var criteria = FilterCriteria() {
        didSet { if criteria != oldValue { apply() } }
    }

    /// Kept when the choices are cleared.
    var order = FilterOrder() {
        didSet { if order != oldValue { apply() } }
    }

    struct Genre: Identifiable {
        let name: String
        let ids: [String]
        var id: String { name }
    }

    /// The library's own genres (Plex).
    private(set) var genres: [Genre] = []
    /// An anime library: anime genres, and ratings like MyAnimeList's (`AnimeIndex`).
    private(set) var animeGenres: [String] = []
    private(set) var ratingSource: String?
    private(set) var years: [Int] = []
    private(set) var results: [PlexItem] = []
    private(set) var isLoading = false
    private(set) var loaded = false
    /// A chosen genre could not be read from the server.
    private(set) var failed = false

    @ObservationIgnored private var all: [PlexItem] = []
    /// Ratings by key (anime libraries), else Plex's own.
    @ObservationIgnored private var ratings: [String: Double] = [:]
    @ObservationIgnored private var animeTitles: [String: Set<String>] = [:]
    /// Genre name → titles that have it.
    @ObservationIgnored private var titles: [String: Set<String>] = [:]
    /// Show → specials, left out of its episodes and seasons.
    @ObservationIgnored private var specials: [String: Int] = [:]
    /// Show → newest episode's air date ("yyyy-MM-dd"), for shows the profile started.
    @ObservationIgnored private var aired: [String: String] = [:]
    /// Position by date added (newest first).
    @ObservationIgnored private var addedRank: [String: Int] = [:]
    @ObservationIgnored private var store: ProfileStore?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var source: (client: PlexServerClient, section: PlexDirectory)?

    func load(client: PlexServerClient, scope: LibraryScope, filter: ContentFilter, store: ProfileStore) async {
        source = (client, scope.section)
        self.store = store
        if !loaded { isLoading = true }
        async let genreTask = client.genreDirectories(section: scope.section.key)
        let items = (try? await client.items(section: scope.section, sort: .recentlyAdded, start: 0, size: 100_000))?.items ?? []
        all = await filter.resolve(items, client: client, scope: scope)
        addedRank = Dictionary(all.enumerated().map { ($1.ratingKey, $0) }, uniquingKeysWith: { a, _ in a })
        years = Set(all.compactMap(\.year)).sorted(by: >)
        let index = await AnimeIndex.shared.value
        let entries = all.compactMap { item in index.entry(item).map { (item.ratingKey, $0) } }
        // Mostly anime (a few anime in another library don't make it one).
        if !all.isEmpty, entries.count * 2 > all.count {
            var byGenre: [String: Set<String>] = [:]
            ratings = [:]
            for (key, entry) in entries {
                if let score = entry.score { ratings[key] = score }
                for genre in entry.genres { byGenre[genre, default: []].insert(key) }
            }
            animeTitles = byGenre
            animeGenres = byGenre.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            ratingSource = index.officialMAL ? "MyAnimeList" : "تقريبي لـ MyAnimeList"
        } else {
            ratings = [:]
            animeTitles = [:]
            animeGenres = []
            ratingSource = nil
        }
        let shows = Set(store.activeStates.compactMap(\.showKey))
        aired = [:]
        for item in all where item.isShow && shows.contains(item.ratingKey) {
            aired[item.ratingKey] = await client.latestAired(show: item.ratingKey)
        }
        loaded = true
        isLoading = false
        apply()

        if scope.section.type == "show", let found = await client.specials(section: scope.section), found != specials {
            specials = found
            apply()
        }
        var grouped: [String: [String]] = [:]
        for directory in await genreTask {
            grouped[ArabicFormat.genre(directory.title), default: []].append(Self.genreID(directory.key))
        }
        if !grouped.isEmpty {
            genres = grouped.filter { animeTitles[$0.key] == nil }.map { Genre(name: $0.key, ids: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// What posters print for anime (MAL), else Plex's rating.
    private func rating(_ item: PlexItem) -> Double {
        // Anime without a rating there yet: not Plex's, often a 10 from a couple of votes.
        if ratingSource != nil { return ratings[item.ratingKey] ?? 0 }
        return item.ratingDisplay?.value ?? 0
    }

    /// Where the profile is with every title (specials left out).
    private func statuses() -> [String: FilterWatched] {
        var seen: [String: Int] = [:]
        var started = Set<String>()
        var out: [String: FilterWatched] = [:]
        for state in store?.activeStates ?? [] {
            let touched = state.watched || state.offsetMs > 10_000
            guard touched else { continue }
            guard state.type == "episode", let show = state.showKey else {
                out[state.ratingKey] = state.watched ? .finished : .started
                continue
            }
            // Season 0: «sortIndex» below 10 000.
            if let order = state.sortIndex, order < 10_000 { continue }
            started.insert(show)
            if state.watched { seen[show, default: 0] += 1 }
        }
        // A new episode in the last three weeks (a skipped week or two is still weekly).
        let recent = Date().addingTimeInterval(-21 * 86_400).formatted(.iso8601.year().month().day())
        for item in all where item.isShow && started.contains(item.ratingKey) {
            let total = (item.leafCount ?? 0) - (specials[item.ratingKey] ?? 0)
            if total <= 0 || seen[item.ratingKey, default: 0] < total {
                out[item.ratingKey] = .started
            } else {
                out[item.ratingKey] = (aired[item.ratingKey] ?? "") >= recent ? .upToDate : .finished
            }
        }
        return out
    }

    private func sorted(_ items: [PlexItem], by order: FilterOrder) -> [PlexItem] {
        func byAdded(_ a: PlexItem, _ b: PlexItem) -> Bool { addedRank[a.ratingKey, default: .max] < addedRank[b.ratingKey, default: .max] }
        /// Titles without a value (no rating, no year) always last.
        func byValue(_ value: (PlexItem) -> Double) -> [PlexItem] {
            items.map { ($0, value($0)) }.sorted { a, b in
                if a.1 == b.1 { return byAdded(a.0, b.0) }
                if a.1 <= 0 || b.1 <= 0 { return a.1 > b.1 }
                return order.ascending ? a.1 < b.1 : a.1 > b.1
            }.map(\.0)
        }
        switch order.key {
        case .added: return items.sorted { order.ascending ? byAdded($1, $0) : byAdded($0, $1) }
        case .title:
            return items.sorted {
                $0.title.localizedStandardCompare($1.title) == (order.ascending ? .orderedAscending : .orderedDescending)
            }
        case .year: return byValue { Double($0.year ?? 0) }
        case .rating: return byValue { rating($0) }
        }
    }

    private func apply() {
        work?.cancel()
        let criteria = criteria, order = order
        work = Task {
            // Genres not asked yet, at the same time.
            let missing = genres.filter {
                criteria.genres.contains($0.name) && titles[$0.name] == nil && animeTitles[$0.name] == nil
            }
            if !missing.isEmpty, let source {
                isLoading = true
                await withTaskGroup(of: (String, Set<String>?).self) { group in
                    for genre in missing {
                        group.addTask {
                            (genre.name, await source.client.ratingKeys(section: source.section, genres: genre.ids))
                        }
                    }
                    for await (name, keys) in group { if let keys { titles[name] = keys } }
                }
            }
            guard !Task.isCancelled else { return }
            // A name in both lists: either source counts.
            let sets = criteria.genres.compactMap { name -> Set<String>? in
                guard let anime = animeTitles[name] else { return titles[name] }
                return anime.union(titles[name] ?? [])
            }
            failed = sets.count < criteria.genres.count
            let statuses = criteria.watched.isEmpty ? [:] : statuses()
            let matching = failed ? [] : all.filter { item in
                guard criteria.matches(item, rating: rating(item), specials: specials[item.ratingKey] ?? 0,
                                       status: statuses[item.ratingKey] ?? .notStarted) else { return false }
                guard !sets.isEmpty else { return true }
                return criteria.matchAllGenres
                    ? sets.allSatisfy { $0.contains(item.ratingKey) }
                    : sets.contains { $0.contains(item.ratingKey) }
            }
            results = sorted(matching, by: order)
            isLoading = false
        }
    }

    func retry() { apply() }

    /// The genre's id: Plex gives it alone ("123") or inside a filter path ("…/all?genre=123").
    private static func genreID(_ key: String) -> String {
        if let range = key.range(of: "genre=") {
            return String(key[range.upperBound...].prefix { $0 != "&" })
        }
        return key.split(separator: "/").last.map(String.init) ?? key
    }
}

/// Short texts of the filter (counts, ratings, seasons).
enum FilterText {
    static func results(_ n: Int) -> String {
        switch n {
        case 0: return "لا نتائج"
        case 1: return "نتيجة واحدة"
        case 2: return "نتيجتان"
        default: return ArabicFormat.digits(n) + ((3...10).contains(n % 100) ? " نتائج" : " نتيجة")
        }
    }

    /// "٧ وأعلى", "٧٫٥ وأعلى"
    static func rating(_ value: Double) -> String { figure(value) + " وأعلى" }

    /// "٧", "٧٫٥"
    static func figure(_ value: Double) -> String {
        let text = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        return ArabicFormat.digits(text.replacingOccurrences(of: ".", with: "٫"))
    }

    static func seasons(_ n: Int) -> String {
        switch n {
        case 1: return "موسم واحد"
        case 2: return "موسمان"
        case 5: return "٥ مواسم أو أكثر"
        default: return "\(ArabicFormat.digits(n)) مواسم"
        }
    }

    /// The first choice, and how many more.
    static func list(_ names: [String]) -> String? {
        guard let first = names.first else { return nil }
        return names.count == 1 ? first : "\(first) +\(ArabicFormat.digits(names.count - 1))"
    }
}
