import SwiftUI

// «فلترة» on the iPhone and iPad: the same choices as the Apple TV (`LibraryFilterModel`), as
// chips over the posters; a chip opens its choices in a sheet. Choices apply at once.

enum FilterField: String, CaseIterable, Identifiable {
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

    /// Movies have no episodes or seasons.
    static func fields(movies: Bool) -> [FilterField] {
        movies ? [.genre, .rating, .year, .watched] : [.genre, .rating, .episodes, .year, .seasons, .watched]
    }
}

/// Chips, the count and the order, then the matching posters (drawn a page at a time).
struct LibraryFilterSection: View {
    let client: PlexServerClient
    let scope: LibraryScope
    let model: LibraryFilterModel

    @Environment(\.contentFilter) private var filter
    @Environment(ProfileStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var open: FilterField?
    @State private var shown = Self.page
    private static let page = 60
    /// «حفظ كصف»: what the alert says.
    @State private var saved: (title: String, isNew: Bool, home: Bool)?

    private var movies: Bool { scope.section.type == "movie" }

    var body: some View {
        let metrics = Metrics(sizeClass)
        let items = Array(model.results.prefix(shown))
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FilterField.fields(movies: movies)) { chip($0) }
                }
                .padding(.horizontal, metrics.margin)
            }

            HStack(spacing: 12) {
                Text(model.loaded && !model.isLoading && !model.failed ? FilterText.results(model.results.count) : " ")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !model.criteria.isEmpty {
                    Button("مسح الكل") { model.criteria = FilterCriteria() }
                        .font(.footnote.weight(.semibold))
                    Menu {
                        Button("في الرئيسية") { saveAsRow(.home) }
                        Button("في «مقترح» \(scope.title)") { saveAsRow(.library(scope.id)) }
                    } label: {
                        Label("حفظ كصف", systemImage: "rectangle.stack.badge.plus")
                            .font(.footnote.weight(.semibold))
                    }
                }
                Spacer(minLength: 8)
                Button { open = .order } label: {
                    Label(model.order.key.title, systemImage: model.order.ascending ? "arrow.up" : "arrow.down")
                        .font(.footnote.weight(.medium))
                }
                .foregroundStyle(.primary)
            }
            .padding(.horizontal, metrics.margin)

            if model.isLoading && items.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            } else if model.failed {
                ContentUnavailableView {
                    Label("تعذّر جلب التصنيف من الخادم", systemImage: "wifi.exclamationmark")
                } actions: {
                    Button("إعادة المحاولة") { model.retry() }
                }
            } else if items.isEmpty && model.loaded {
                ContentUnavailableView("لا توجد نتائج", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("جرّب تقليل الاختيارات"))
            }

            PosterGrid(items: items, client: client) { item in
                if item.id == items.last?.id, shown < model.results.count { shown += Self.page }
            }
        }
        .task { await model.load(client: client, scope: scope, filter: filter, store: store) }
        .onReceive(NotificationCenter.default.publisher(for: .localLibraryDidChange)) { _ in
            Task { await model.load(client: client, scope: scope, filter: filter, store: store) }
        }
        .onChange(of: model.criteria) { shown = Self.page }
        .onChange(of: model.order) { shown = Self.page }
        .alert(saved.map { $0.isNew ? "انضاف إلى \(place($0.home))" : "الصف موجود في \(place($0.home))" } ?? "",
               isPresented: Binding(get: { saved != nil }, set: { if !$0 { saved = nil } })) {
            Button("حسناً", role: .cancel) {}
        } message: {
            if let saved {
                Text(saved.isNew ? "«\(saved.title)»: في الآخر، ومحتواه يتغيّر كل يوم. نفس الصف في كل أجهزتك." : "«\(saved.title)»")
            }
        }
        .sheet(item: $open) { field in
            FilterSheet(field: field, model: model, movies: movies)
                .presentationDetents(field == .genre || field == .year ? [.large] : [.medium, .large])
        }
    }

    private func place(_ home: Bool) -> String { home ? "الرئيسية" : "«مقترح» في \(scope.title)" }

    /// The choices as a row of Home or of this library's «مقترح» (the same rows as the Apple
    /// TV's), named after them: «كوميديا، التقييم ٧ وأعلى في الأفلام».
    private func saveAsRow(_ target: RowsTarget) {
        let criteria = model.criteria
        let home = target == .home
        if let existing = target.layout(store.activeProfile?.settings)?.first(where: {
            $0.custom?.kind == .filter && $0.custom?.scope == scope.id && $0.custom?.criteria == criteria
        }) {
            saved = (existing.title ?? "", false, home)
            return
        }
        let parts = FilterField.fields(movies: movies)
            .compactMap { FilterSummary.value($0, model: model, movies: movies) }.joined(separator: "، ")
        let title = home ? "\(parts) في \(scope.rowName)" : parts
        let row = HomeRowConfig(id: "custom-\(UUID().uuidString)", title: title,
                                custom: CustomHomeRow(kind: .filter, section: scope.section.key,
                                                      scope: scope.id, criteria: criteria))
        let current = HomeRowCatalog.shared.rows(of: target)
        store.updateSettings { target.set(HomeLayout.adding(row, current: current, layout: target.layout($0)), in: &$0) }
        saved = (title, true, home)
    }

    private func chip(_ field: FilterField) -> some View {
        let value = FilterSummary.value(field, model: model, movies: movies)
        return Button { open = field } label: {
            HStack(spacing: 6) {
                Text(value ?? field.title).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).opacity(0.6)
            }
            .font(.subheadline.weight(value != nil ? .semibold : .regular))
            .foregroundStyle(value != nil ? Theme.accent : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(value != nil ? 0.16 : 0.08)))
        }
        .buttonStyle(.plain)
    }
}

/// What's chosen in a filter, in short; nil when nothing is.
enum FilterSummary {
    @MainActor
    static func value(_ field: FilterField, model: LibraryFilterModel, movies: Bool) -> String? {
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
            return FilterText.list(FilterWatched.choices(movies: movies).filter(c.watched.contains).map { $0.title(movies: movies) })
        case .order:
            return model.order.key.title
        }
    }
}

/// One filter's choices. The count of matching titles stays in sight while choosing.
private struct FilterSheet: View {
    let field: FilterField
    @Bindable var model: LibraryFilterModel
    let movies: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { content }
                .navigationTitle(field.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text(field.title).font(.headline)
                            Text(model.isLoading ? "…" : FilterText.results(model.results.count))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch field {
        case .genre:
            let several = model.criteria.genres.count > 1
            Section {
                Picker("التصنيفات المختارة", selection: $model.criteria.matchAllGenres) {
                    Text("كلها معًا").tag(true)
                    Text("أي واحد منها").tag(false)
                }
                .pickerStyle(.segmented)
                .disabled(!several)
            } footer: {
                Text(several ? (model.criteria.matchAllGenres ? "يظهر ما فيه كل التصنيفات المختارة." : "يظهر ما فيه أي تصنيف منها.")
                             : "اختر أكثر من تصنيف لتحدد كيف تُجمع.")
            }
            if !model.animeGenres.isEmpty {
                Section("تصنيفات الأنمي") { genreRows(model.animeGenres) }
            }
            if !model.genres.isEmpty {
                Section(model.animeGenres.isEmpty ? "" : "تصنيفات عامة") { genreRows(model.genres.map(\.name)) }
            }
            if model.genres.isEmpty && model.animeGenres.isEmpty {
                Text(model.loaded ? "لا توجد تصنيفات" : "جارٍ التحميل…").foregroundStyle(.secondary)
            }
        case .rating:
            Section {
                single(nil, label: "الكل", selection: $model.criteria.minRating)
                ForEach([5, 6, 6.5, 7, 7.5, 8, 8.5, 9], id: \.self) { value in
                    single(value, label: FilterText.rating(value), selection: $model.criteria.minRating)
                }
            } footer: {
                if let source = model.ratingSource { Text("التقييم \(source)") }
            }
        case .episodes:
            Section("أكثر من") {
                single(nil, label: "الكل", selection: $model.criteria.moreEpisodes)
                ForEach([6, 12, 24, 50, 100, 200], id: \.self) { n in
                    single(n, label: "\(ArabicFormat.digits(n)) حلقة", selection: $model.criteria.moreEpisodes)
                }
            }
            Section("أقل من") {
                single(nil, label: "الكل", selection: $model.criteria.fewerEpisodes)
                ForEach([7, 13, 25, 50, 100, 200], id: \.self) { n in
                    single(n, label: "\(ArabicFormat.digits(n)) حلقة", selection: $model.criteria.fewerEpisodes)
                }
            }
        case .year:
            Section {
                yearPicker("من سنة", selection: $model.criteria.fromYear)
                yearPicker("إلى سنة", selection: $model.criteria.toYear)
            } footer: {
                Text("اختر سنة واحدة أو مدى بين سنتين.")
            }
        case .seasons:
            Section {
                ForEach(1...5, id: \.self) { count in
                    multi(count == 5 ? "٥ أو أكثر" : FilterText.seasons(count),
                          isOn: model.criteria.seasons.contains(count)) {
                        model.criteria.seasons.formSymmetricDifference([count])
                    }
                }
            }
        case .watched:
            Section {
                ForEach(FilterWatched.choices(movies: movies), id: \.self) { status in
                    multi(status.title(movies: movies), isOn: model.criteria.watched.contains(status)) {
                        model.criteria.watched.formSymmetricDifference([status])
                    }
                }
            } footer: {
                if !movies { Text("متابع أول بأول: شاهدت كل حلقاته وما زالت تنزل له حلقات أسبوعية.") }
            }
        case .order:
            Section("حسب") {
                ForEach(FilterOrder.Key.allCases, id: \.self) { key in
                    multi(key.title, isOn: model.order.key == key) {
                        guard model.order.key != key else { return }
                        // The usual direction of each: names A–Z, the rest newest / best first.
                        model.order = FilterOrder(key: key, ascending: key == .title)
                    }
                }
            }
            Section {
                Picker("الاتجاه", selection: $model.order.ascending) {
                    Label("تنازلي", systemImage: "arrow.down").tag(false)
                    Label("تصاعدي", systemImage: "arrow.up").tag(true)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(model.order.meaning)
            }
        }
    }

    private func genreRows(_ names: [String]) -> some View {
        ForEach(names, id: \.self) { name in
            multi(name, isOn: model.criteria.genres.contains(name)) {
                model.criteria.genres.formSymmetricDifference([name])
            }
        }
    }

    private func yearPicker(_ title: String, selection: Binding<Int?>) -> some View {
        Picker(title, selection: selection) {
            Text("الكل").tag(Int?.none)
            ForEach(model.years, id: \.self) { Text(ArabicFormat.digits($0)).tag(Int?.some($0)) }
        }
    }

    /// One choice of several (tapping the chosen one again clears it).
    private func single<Value: Hashable>(_ value: Value?, label: String, selection: Binding<Value?>) -> some View {
        multi(label, isOn: selection.wrappedValue == value) {
            selection.wrappedValue = (value != nil && selection.wrappedValue == value) ? nil : value
        }
    }

    private func multi(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).foregroundStyle(Color.primary)
                Spacer()
                if isOn { Image(systemName: "checkmark").foregroundStyle(Theme.accent).fontWeight(.semibold) }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
    }
}
