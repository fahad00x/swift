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

/// The tab: one pill per filter (with what's chosen in it), then the matching posters.
struct LibraryFilterGrid: View {
    let client: PlexServerClient
    let scope: LibraryScope
    let model: LibraryFilterModel
    let scrollProxy: ScrollViewProxy

    enum Field: String, CaseIterable, Identifiable {
        case genre, rating, episodes, year, seasons, watched, order
        var id: String { rawValue }
        var title: String {
            switch self {
            case .genre: return "التصنيف"
            case .rating: return "التقييم"
            case .episodes: return "عدد الحلقات"
            case .year: return "سنة الإصدار"
            case .seasons: return "المواسم"
            case .watched: return "المشاهدة"
            case .order: return "الترتيب"
            }
        }
    }

    @Environment(\.contentFilter) private var filter
    @Environment(ProfileStore.self) private var store
    @State private var open: Field?
    @FocusState private var focused: Field?
    /// Posters drawn so far (the rest on scroll).
    @State private var shown = Self.page
    private static let page = 60

    /// Movies have no episodes or seasons.
    private var fields: [Field] {
        scope.section.type == "movie" 
            ? [.genre, .rating, .year, .watched] : [.genre, .rating, .episodes, .year, .seasons, .watched]
    }

    var body: some View {
        let items = Array(model.results.prefix(shown))
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    ForEach(fields) { pill($0) }
                }
                .frame(maxWidth: .infinity)
                .focusSection()

                // The order, how many there are, and clearing the choices.
                HStack(spacing: 24) {
                    pill(.order)
                    if model.loaded {
                        Text(FilterText.results(model.results.count))
                            .font(.system(size: 24))
                            .foregroundStyle(.white.opacity(0.5))
                            .opacity(model.isLoading || model.failed ? 0 : 1)
                    }
                    if !model.criteria.isEmpty {
                        Button {
                            // This button goes away: keep the focus on the pills.
                            focused = fields.first
                            model.criteria = FilterCriteria()
                        } label: {
                            Label("مسح الكل", systemImage: "xmark")
                        }
                        .buttonStyle(FilterPillStyle(selected: false))
                    }
                }
                .frame(maxWidth: .infinity)
                .focusSection()
            }
            .padding(.horizontal, CardKind.inset)
            .padding(.top, -12)

            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if model.failed {
                ContentUnavailableView {
                    Label("تعذّر جلب التصنيف من الخادم", systemImage: "wifi.exclamationmark")
                } actions: {
                    Button("إعادة المحاولة") { model.retry() }
                }
                .frame(maxWidth: .infinity)
            } else if items.isEmpty && model.loaded {
                ContentUnavailableView("لا توجد نتائج", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("جرّب تقليل الاختيارات"))
                    .frame(maxWidth: .infinity)
            }

            PosterGrid(items: items, client: client, scrollProxy: scrollProxy, rowID: "filter") { item in
                if item.id == items.last?.id, shown < model.results.count { shown += Self.page }
            }
        }
        .task { await model.load(client: client, scope: scope, filter: filter, store: store) }
        .onReceive(NotificationCenter.default.publisher(for: .localLibraryDidChange)) { _ in
            Task { await model.load(client: client, scope: scope, filter: filter, store: store) }
        }
        .onChange(of: model.criteria) { shown = Self.page }
        .onChange(of: model.order) { shown = Self.page }
        .fullScreenCover(item: $open) { field in
            FilterPanel(field: field, model: model, movies: scope.section.type == "movie")
        }
    }

    private func pill(_ field: Field) -> some View {
        Button { open = field } label: {
            HStack(spacing: 10) {
                if field == .order {
                    Image(systemName: model.order.ascending ? "arrow.up" : "arrow.down").font(.system(size: 18, weight: .semibold))
                }
                // What's chosen says enough on its own.
                Text(value(field) ?? field.title).lineLimit(1).minimumScaleFactor(0.75)
                Image(systemName: "chevron.down").font(.system(size: 16, weight: .semibold)).opacity(0.6)
            }
        }
        .buttonStyle(FilterPillStyle(selected: field != .order && value(field) != nil))
        .focused($focused, equals: field)
    }

    /// What's chosen in a filter, in short; nil when nothing is.
    private func value(_ field: Field) -> String? {
        let c = model.criteria
        switch field {
        case .genre:
            return FilterText.list(c.genres.sorted())
        case .rating:
            return c.minRating.map { "التقييم " + FilterText.rating($0) }
        case .episodes:
            let parts = [c.moreEpisodes.map { "أكثر من \(ArabicFormat.digits($0))" },
                         c.fewerEpisodes.map { "أقل من \(ArabicFormat.digits($0))" }].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "، ") + " حلقة"
        case .year:
            let from = c.fromYear.map { ArabicFormat.digits($0) }, to = c.toYear.map { ArabicFormat.digits($0) }
            switch (from, to) {
            case let (from?, to?): return from == to ? from : "\(from) – \(to)"
            case let (from?, nil): return "من سنة \(from)"
            case let (nil, to?): return "إلى سنة \(to)"
            default: return nil
            }
        case .seasons:
            return FilterText.list(c.seasons.sorted().map(FilterText.seasons))
        case .watched:
            let movies = scope.section.type == "movie"
            return FilterText.list(FilterWatched.choices(movies: movies).filter(c.watched.contains).map { $0.title(movies: movies) })
        case .order:
            return "الترتيب: " + model.order.key.title
        }
    }
}

/// One filter's choices on a glass card over the page. Choices apply at once; Back closes.
/// Numbers are single lines of plain figures; genres a list with check marks.
private struct FilterPanel: View {
    let field: LibraryFilterGrid.Field
    let model: LibraryFilterModel
    let movies: Bool

    private static let width: CGFloat = 1400
    private static let inset: CGFloat = 70

    var body: some View {
        VStack(spacing: 44) {
            VStack(spacing: 8) {
                Text(field.title).font(.system(size: 44, weight: .bold))
                Text(model.isLoading ? "…" : FilterText.results(model.results.count))
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.55))
            }
            content
        }
        .padding(.vertical, 54)
        .frame(width: Self.width)
        .background {
            RoundedRectangle(cornerRadius: 48, style: .continuous).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 48, style: .continuous).fill(Color.black.opacity(0.35))
            RoundedRectangle(cornerRadius: 48, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.6).ignoresSafeArea())
        .presentationBackground(.clear)
    }

    @ViewBuilder
    private var content: some View {
        @Bindable var model = model
        switch field {
        case .genre:
            genreList
        case .rating:
            VStack(spacing: 20) {
                FigureLine(title: nil, figures: [5, 6, 6.5, 7, 7.5, 8, 8.5, 9].map { (FilterText.figure($0), $0) },
                           selection: $model.criteria.minRating)
                Text(["الرقم المختار وأعلى", model.ratingSource.map { "التقييم \($0)" }].compactMap { $0 }.joined(separator: " • "))
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.45))
            }
        case .episodes:
            VStack(spacing: 40) {
                FigureLine(title: "أكثر من", figures: [6, 12, 24, 50, 100, 200].map { (ArabicFormat.digits($0), $0) },
                           selection: $model.criteria.moreEpisodes)
                FigureLine(title: "أقل من", figures: [7, 13, 25, 50, 100, 200].map { (ArabicFormat.digits($0), $0) },
                           selection: $model.criteria.fewerEpisodes)
            }
        case .year:
            VStack(spacing: 40) {
                FigureLine(title: "من سنة", figures: model.years.map { (ArabicFormat.digits($0), $0) },
                           selection: $model.criteria.fromYear)
                FigureLine(title: "إلى سنة", figures: model.years.map { (ArabicFormat.digits($0), $0) },
                           selection: $model.criteria.toYear)
            }
        case .watched:
            VStack(spacing: 24) {
                HStack(spacing: 16) {
                    ForEach(FilterWatched.choices(movies: movies), id: \.self) { status in
                        Button { model.criteria.watched.formSymmetricDifference([status]) } label: {
                            Text(status.title(movies: movies))
                        }
                        .buttonStyle(FigureStyle(selected: model.criteria.watched.contains(status), width: 300))
                    }
                }
                .focusSection()
                if !movies {
                    Text("متابع أول بأول: شاهدت كل حلقاته وما زالت تنزل له حلقات أسبوعية")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        case .order:
            VStack(spacing: 40) {
                HStack(spacing: 16) {
                    ForEach(FilterOrder.Key.allCases, id: \.self) { key in
                        Button {
                            guard model.order.key != key else { return }
                            // The usual direction of each: names A–Z, the rest newest / best first.
                            model.order = FilterOrder(key: key, ascending: key == .title)
                        } label: { Text(key.title) }
                            .buttonStyle(FigureStyle(selected: model.order.key == key, width: 260))
                    }
                }
                .focusSection()
                VStack(spacing: 20) {
                    HStack(spacing: 16) {
                        Button { model.order.ascending = false } label: { Label("تنازلي", systemImage: "arrow.down") }
                            .buttonStyle(FigureStyle(selected: !model.order.ascending, width: 260))
                        Button { model.order.ascending = true } label: { Label("تصاعدي", systemImage: "arrow.up") }
                            .buttonStyle(FigureStyle(selected: model.order.ascending, width: 260))
                    }
                    .focusSection()
                    Text(model.order.meaning)
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        case .seasons:
            HStack(spacing: 16) {
                ForEach(1...5, id: \.self) { count in
                    Button { model.criteria.seasons.formSymmetricDifference([count]) } label: {
                        Text(count == 5 ? "٥ أو أكثر" : FilterText.seasons(count))
                    }
                    .buttonStyle(FigureStyle(selected: model.criteria.seasons.contains(count), width: 236))
                }
            }
        }
    }

    private var genreList: some View {
        let several = model.criteria.genres.count > 1
        return VStack(spacing: 24) {
            // Always there, so the list doesn't jump when a second genre is chosen.
            HStack(spacing: 16) {
                Button { model.criteria.matchAllGenres = true } label: { Text("كل التصنيفات معًا") }
                    .buttonStyle(FigureStyle(selected: several && model.criteria.matchAllGenres, width: 300))
                Button { model.criteria.matchAllGenres = false } label: { Text("أي تصنيف منها") }
                    .buttonStyle(FigureStyle(selected: several && !model.criteria.matchAllGenres, width: 300))
            }
            .opacity(several ? 1 : 0.3)
            .disabled(!several)
            .focusSection()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 44) {
                    if !model.animeGenres.isEmpty {
                        genreSection("تصنيفات الأنمي", model.animeGenres)
                    }
                    if !model.genres.isEmpty {
                        genreSection(model.animeGenres.isEmpty ? nil : "تصنيفات عامة", model.genres.map(\.name))
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, Self.inset)
            }
            .frame(height: 560)
            // Rows fade out at the edges instead of being cut.
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                         .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .focusSection()
        }
    }

    private func genreSection(_ title: String?, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if let title {
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 24)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24), count: 3), spacing: 14) {
                ForEach(names, id: \.self) { name in
                    Button { model.criteria.genres.formSymmetricDifference([name]) } label: { Text(name) }
                        .buttonStyle(GenreRowStyle(selected: model.criteria.genres.contains(name)))
                }
            }
        }
    }
}

/// «أي  ٥  ٦  ٧ …»: one line of figures (scrolls when long), one of them chosen.
private struct FigureLine<Value: Hashable>: View {
    let title: String?
    let figures: [(String, Value)]
    @Binding var selection: Value?

    private let cell: CGFloat = 124
    private let gap: CGFloat = 12
    private let inset: CGFloat = 70

    var body: some View {
        let fits = CGFloat(figures.count + 1) * (cell + gap) - gap <= 1400 - 2 * inset
        VStack(spacing: 16) {
            if let title {
                Text(title)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            if fits {
                row
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        row.padding(.horizontal, inset).padding(.vertical, 10)
                    }
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                                 .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                                         startPoint: .leading, endPoint: .trailing))
                    .onAppear { if let selection { proxy.scrollTo(selection, anchor: .center) } }
                }
            }
        }
        .focusSection()
    }

    private var row: some View {
        HStack(spacing: gap) {
            Button { selection = nil } label: { Text("الكل") }
                .buttonStyle(FigureStyle(selected: selection == nil, width: cell))
            ForEach(figures, id: \.1) { figure in
                Button { selection = selection == figure.1 ? nil : figure.1 } label: { Text(figure.0) }
                    .buttonStyle(FigureStyle(selected: selection == figure.1, width: cell))
                    .id(figure.1)
            }
        }
    }
}

/// Plain text; focused: white capsule; chosen: amber with a line under it.
private struct FigureStyle: ButtonStyle {
    let selected: Bool
    let width: CGFloat

    func makeBody(configuration: Configuration) -> some View { FigureBody(configuration: configuration, selected: selected, width: width) }

    private struct FigureBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let width: CGFloat
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.system(size: 32, weight: selected ? .bold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(isFocused ? Color.black : (selected ? ArtworkStatusOverlay.orange : Color.white.opacity(0.75)))
                .padding(.horizontal, 12)
                .frame(width: width, height: 76)
                .background(Capsule().fill(isFocused ? Color.white : Color.clear))
                .overlay(alignment: .bottom) {
                    Capsule().fill(ArtworkStatusOverlay.orange)
                        .frame(width: 34, height: 4)
                        .offset(y: -6)
                        .opacity(selected ? 1 : 0)
                }
                .scaleEffect(configuration.isPressed ? 0.95 : 1)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

/// A genre: a circle (✓ when chosen) and the name; focused: white.
private struct GenreRowStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View { RowBody(configuration: configuration, selected: selected) }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            HStack(spacing: 18) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 28, weight: selected ? .bold : .light))
                    .foregroundStyle(selected ? ArtworkStatusOverlay.orange : (isFocused ? Color.black.opacity(0.4) : Color.white.opacity(0.3)))
                configuration.label
                    .font(.system(size: 29, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(isFocused ? Color.black : Color.white.opacity(selected ? 1 : 0.8))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .frame(height: 74)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(isFocused ? Color.white : Color.clear))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

/// Focused: white. Chosen: amber text on lighter glass. Otherwise dark glass.
private struct FilterPillStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View { PillBody(configuration: configuration, selected: selected) }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.pageContentFocused) private var pageContentFocused

        var body: some View {
            configuration.label
                .onChange(of: isFocused) { _, focused in if focused { pageContentFocused?() } }
                .font(.system(size: 23, weight: selected ? .semibold : .regular))
                .foregroundStyle(isFocused ? Color.black : (selected ? ArtworkStatusOverlay.orange : Color.white.opacity(0.8)))
                .padding(.horizontal, 24)
                .frame(height: 52)
                .background(Capsule().fill(isFocused ? Color.white : Color.white.opacity(selected ? 0.18 : 0.08)))
                .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.05 : 1))
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

private enum FilterText {
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
