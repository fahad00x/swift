import SwiftUI

// «فلترة»: a library's titles narrowed by any mix of genre, rating, episodes, year, seasons.
// Every choice is optional. Everything but the genre is read from the library on the device
// (its listing only carries two genres per title, so genres are asked from the server).

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
    var years: Set<Int> = []
    var periods: Set<FilterPeriod> = []
    /// 5 = five or more.
    var seasons: Set<Int> = []

    var isEmpty: Bool { self == FilterCriteria(matchAllGenres: matchAllGenres) }

    /// Everything but the genres.
    func matches(_ item: PlexItem) -> Bool {
        if let minRating, (item.ratingDisplay?.value ?? 0) < minRating { return false }
        if moreEpisodes != nil || fewerEpisodes != nil {
            guard let count = item.leafCount else { return false }
            if let moreEpisodes, count <= moreEpisodes { return false }
            if let fewerEpisodes, count >= fewerEpisodes { return false }
        }
        if !years.isEmpty || !periods.isEmpty {
            guard let year = item.year else { return false }
            guard years.contains(year) || periods.contains(where: { $0.contains(year) }) else { return false }
        }
        if !seasons.isEmpty {
            guard let count = item.childCount, seasons.contains(min(count, 5)) else { return false }
        }
        return true
    }
}

enum FilterPeriod: CaseIterable {
    case from2020, from2010, from2000, from1990, older

    func contains(_ year: Int) -> Bool {
        switch self {
        case .from2020: return year >= 2020
        case .from2010: return (2010...2019).contains(year)
        case .from2000: return (2000...2009).contains(year)
        case .from1990: return (1990...1999).contains(year)
        case .older: return year < 1990
        }
    }

    var title: String {
        switch self {
        case .from2020: return "٢٠٢٠ وما بعد"
        case .from2010: return "٢٠١٠ – ٢٠١٩"
        case .from2000: return "٢٠٠٠ – ٢٠٠٩"
        case .from1990: return "التسعينات"
        case .older: return "قبل ١٩٩٠"
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

    struct Genre: Identifiable {
        let name: String
        let ids: [String]
        var id: String { name }
    }

    private(set) var genres: [Genre] = []
    private(set) var years: [Int] = []
    private(set) var results: [PlexItem] = []
    private(set) var isLoading = false
    private(set) var loaded = false
    /// A chosen genre could not be read from the server.
    private(set) var failed = false

    @ObservationIgnored private var all: [PlexItem] = []
    /// Genre name → titles that have it.
    @ObservationIgnored private var titles: [String: Set<String>] = [:]
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var source: (client: PlexServerClient, section: PlexDirectory)?

    func load(client: PlexServerClient, scope: LibraryScope, filter: ContentFilter) async {
        source = (client, scope.section)
        if !loaded { isLoading = true }
        async let genreTask = client.genreDirectories(section: scope.section.key)
        let items = (try? await client.items(section: scope.section, sort: .rating, start: 0, size: 100_000))?.items ?? []
        all = await filter.resolve(items, client: client, scope: scope)
        years = Set(all.compactMap(\.year)).sorted(by: >)
        loaded = true
        isLoading = false
        apply()

        var grouped: [String: [String]] = [:]
        for directory in await genreTask {
            grouped[ArabicFormat.genre(directory.title), default: []].append(Self.genreID(directory.key))
        }
        if !grouped.isEmpty {
            genres = grouped.map { Genre(name: $0.key, ids: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private func apply() {
        work?.cancel()
        let criteria = criteria
        work = Task {
            // Genres not asked yet, at the same time.
            let missing = genres.filter { criteria.genres.contains($0.name) && titles[$0.name] == nil }
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
            let sets = criteria.genres.compactMap { titles[$0] }
            failed = sets.count < criteria.genres.count
            results = failed ? [] : all.filter { item in
                guard criteria.matches(item) else { return false }
                guard !sets.isEmpty else { return true }
                return criteria.matchAllGenres
                    ? sets.allSatisfy { $0.contains(item.ratingKey) }
                    : sets.contains { $0.contains(item.ratingKey) }
            }
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
        case genre, rating, episodes, year, seasons
        var id: String { rawValue }
        var title: String {
            switch self {
            case .genre: return "التصنيف"
            case .rating: return "التقييم"
            case .episodes: return "عدد الحلقات"
            case .year: return "سنة الإصدار"
            case .seasons: return "المواسم"
            }
        }
    }

    @Environment(\.contentFilter) private var filter
    @State private var open: Field?
    @FocusState private var focused: Field?
    /// Posters drawn so far (the rest on scroll).
    @State private var shown = Self.page
    private static let page = 60

    /// Movies have no episodes or seasons.
    private var fields: [Field] {
        scope.section.type == "movie" ? [.genre, .rating, .year] : Field.allCases
    }

    var body: some View {
        let items = Array(model.results.prefix(shown))
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    ForEach(fields) { field in
                        Button { open = field } label: {
                            HStack(spacing: 10) {
                                Text(label(field)).lineLimit(1)
                                Image(systemName: "chevron.down").font(.system(size: 16, weight: .semibold)).opacity(0.6)
                            }
                        }
                        .buttonStyle(FilterPillStyle(selected: value(field) != nil))
                        .focused($focused, equals: field)
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

                if model.loaded {
                    Text(FilterText.results(model.results.count))
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.5))
                        .opacity(model.isLoading || model.failed ? 0 : 1)
                }
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
        .task { await model.load(client: client, scope: scope, filter: filter) }
        .onReceive(NotificationCenter.default.publisher(for: .localLibraryDidChange)) { _ in
            Task { await model.load(client: client, scope: scope, filter: filter) }
        }
        .onChange(of: model.criteria) { shown = Self.page }
        .fullScreenCover(item: $open) { field in
            FilterPanel(field: field, model: model)
        }
    }

    private func label(_ field: Field) -> String {
        value(field).map { "\(field.title): \($0)" } ?? field.title
    }

    /// What's chosen in a filter, in short; nil when nothing is.
    private func value(_ field: Field) -> String? {
        let c = model.criteria
        switch field {
        case .genre:
            return FilterText.list(c.genres.sorted())
        case .rating:
            return c.minRating.map(FilterText.rating)
        case .episodes:
            let parts = [c.moreEpisodes.map { "أكثر من \(ArabicFormat.digits($0))" },
                         c.fewerEpisodes.map { "أقل من \(ArabicFormat.digits($0))" }].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "، ")
        case .year:
            return FilterText.list(FilterPeriod.allCases.filter(c.periods.contains).map(\.title)
                + c.years.sorted(by: >).map { ArabicFormat.digits($0) })
        case .seasons:
            return FilterText.list(c.seasons.sorted().map(FilterText.seasons))
        }
    }
}

/// One filter's choices over the page. Choices apply at once; Back closes.
private struct FilterPanel: View {
    let field: LibraryFilterGrid.Field
    let model: LibraryFilterModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 30) {
            HStack(alignment: .firstTextBaseline) {
                Text(field.title).font(.system(size: 46, weight: .bold))
                Spacer()
                Text(model.isLoading ? "…" : FilterText.results(model.results.count))
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.6))
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 34) {
                    switch field {
                    case .genre:
                        if model.criteria.genres.count > 1 {
                            section(nil) {
                                chip("كل التصنيفات معًا", model.criteria.matchAllGenres) { model.criteria.matchAllGenres = true }
                                chip("أي تصنيف منها", !model.criteria.matchAllGenres) { model.criteria.matchAllGenres = false }
                            }
                        }
                        section(nil) {
                            ForEach(model.genres) { genre in
                                chip(genre.name, model.criteria.genres.contains(genre.name)) {
                                    model.criteria.genres.formSymmetricDifference([genre.name])
                                }
                            }
                        }
                    case .rating:
                        section(nil) {
                            ForEach([9, 8.5, 8, 7.5, 7, 6.5, 6, 5], id: \.self) { (value: Double) in
                                chip(FilterText.rating(value), model.criteria.minRating == value) {
                                    model.criteria.minRating = model.criteria.minRating == value ? nil : value
                                }
                            }
                        }
                    case .episodes:
                        section("أكثر من") {
                            ForEach([6, 12, 24, 50, 100, 200], id: \.self) { count in
                                chip(ArabicFormat.digits(count), model.criteria.moreEpisodes == count) {
                                    model.criteria.moreEpisodes = model.criteria.moreEpisodes == count ? nil : count
                                }
                            }
                        }
                        section("أقل من") {
                            ForEach([7, 13, 25, 50, 100, 200], id: \.self) { count in
                                chip(ArabicFormat.digits(count), model.criteria.fewerEpisodes == count) {
                                    model.criteria.fewerEpisodes = model.criteria.fewerEpisodes == count ? nil : count
                                }
                            }
                        }
                    case .year:
                        section("فترة") {
                            ForEach(FilterPeriod.allCases, id: \.self) { period in
                                chip(period.title, model.criteria.periods.contains(period)) {
                                    model.criteria.periods.formSymmetricDifference([period])
                                }
                            }
                        }
                        section("سنة") {
                            ForEach(model.years, id: \.self) { year in
                                chip(ArabicFormat.digits(year), model.criteria.years.contains(year)) {
                                    model.criteria.years.formSymmetricDifference([year])
                                }
                            }
                        }
                    case .seasons:
                        section(nil) {
                            ForEach(1...5, id: \.self) { count in
                                chip(FilterText.seasons(count), model.criteria.seasons.contains(count)) {
                                    model.criteria.seasons.formSymmetricDifference([count])
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 20)
            }
            .padding(.horizontal, -20)
            Button("تم") { dismiss() }
                .buttonStyle(FilterPillStyle(selected: true))
                .frame(maxWidth: .infinity)
                .focusSection()
        }
        .padding(.horizontal, 140)
        .padding(.vertical, 70)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.55).ignoresSafeArea())
        .presentationBackground(.ultraThinMaterial)
    }

    private func section(_ title: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                Text(title).font(.system(size: 28)).foregroundStyle(.white.opacity(0.6))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 20)], alignment: .leading, spacing: 20) {
                content()
            }
        }
        .focusSection()
    }

    private func chip(_ title: String, _ selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if selected { Image(systemName: "checkmark").font(.system(size: 20, weight: .bold)) }
                Text(title).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(FilterPillStyle(selected: selected))
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
    static func rating(_ value: Double) -> String {
        let text = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        return ArabicFormat.digits(text.replacingOccurrences(of: ".", with: "٫")) + " وأعلى"
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
