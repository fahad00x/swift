import SwiftUI

// The filter's model and texts are in Lumen/Common/LibraryFilterModel.swift (shared with the iPhone).

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
    @Environment(ShellState.self) private var shell: ShellState?
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

                // On the posters' edges, plain text: how many (and clearing the choices) on the
                // reading side, the order on the other.
                HStack(spacing: 4) {
                    Text(FilterText.results(model.results.count))
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.5))
                        .opacity(!model.loaded || model.isLoading || model.failed ? 0 : 1)
                    if !model.criteria.isEmpty {
                        Button {
                            // This button goes away: keep the focus on the pills.
                            focused = fields.first
                            model.criteria = FilterCriteria()
                        } label: { Text("مسح الكل") }
                            .buttonStyle(FilterTextStyle(accent: true))
                    }
                    Spacer(minLength: 40)
                    Button { open = .order } label: {
                        HStack(spacing: 10) {
                            Image(systemName: model.order.ascending ? "arrow.up" : "arrow.down")
                                .font(.system(size: 19, weight: .semibold))
                            Text(model.order.key.title)
                        }
                    }
                    .buttonStyle(FilterTextStyle(accent: false))
                    .focused($focused, equals: .order)
                    // The text itself on the posters' edge.
                    .padding(.trailing, -FilterTextStyle.inset)
                }
                .frame(height: 48)
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
        // The focused poster went away with the last result.
        .onChange(of: model.results.isEmpty) { _, empty in
            // (Not under a details page: it would take the focus from it.)
            if empty, open == nil, (shell?.pushedPages ?? 0) == 0 { focused = fields.first }
        }
        .fullScreenCover(item: $open) { field in
            FilterPanel(field: field, model: model, movies: scope.section.type == "movie")
        }
    }

    private func pill(_ field: Field) -> some View {
        Button { open = field } label: {
            HStack(spacing: 10) {
                // What's chosen says enough on its own.
                Text(value(field) ?? field.title).lineLimit(1).minimumScaleFactor(0.75)
                Image(systemName: "chevron.down").font(.system(size: 16, weight: .semibold)).opacity(0.6)
            }
        }
        .buttonStyle(FilterPillStyle(selected: value(field) != nil))
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
            return model.order.key.title
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

/// Plain text; focused: white capsule.
private struct FilterTextStyle: ButtonStyle {
    let accent: Bool
    static let inset: CGFloat = 20

    func makeBody(configuration: Configuration) -> some View { TextBody(configuration: configuration, accent: accent) }

    private struct TextBody: View {
        let configuration: ButtonStyleConfiguration
        let accent: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.pageContentFocused) private var pageContentFocused

        var body: some View {
            configuration.label
                .onChange(of: isFocused) { _, focused in if focused { pageContentFocused?() } }
                .font(.system(size: 24, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(isFocused ? Color.black : (accent ? ArtworkStatusOverlay.orange : Color.white.opacity(0.75)))
                .padding(.horizontal, FilterTextStyle.inset)
                .frame(height: 48)
                .background(Capsule().fill(isFocused ? Color.white : Color.clear))
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
