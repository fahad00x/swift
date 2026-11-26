import SwiftUI

/// A library's «مقترح» on the iPhone / iPad: the Apple TV's rows for this library (`TVFeed`),
/// with the rows the profile added, as it arranged them (Settings → «صفوف المكتبات»; the same
/// arrangement on every device).
struct LibrarySuggestedSection: View {
    let client: PlexServerClient
    let scope: LibraryScope

    @Environment(ProfileStore.self) private var store
    @Environment(\.contentFilter) private var filter
    @Environment(ShowNews.self) private var news: ShowNews?
    @State private var rows: [Shelf] = []
    @State private var customRows: [Shelf] = []
    @State private var loaded = false

    private var target: RowsTarget { .library(scope.id) }
    private var layout: [HomeRowConfig]? { target.layout(store.activeProfile?.settings) }

    private var baseRows: [Shelf] {
        rows.shown(to: store, news: news, filter: filter, section: scope.section.key) + customRows
    }

    private var arranged: [Shelf] { HomeLayout.arrange(baseRows, id: \.id, layout: layout) }

    private var rowInfos: [HomeRowInfo] { baseRows.map { HomeRowInfo(id: $0.id, title: $0.title) } }

    private var customSignature: String {
        (layout ?? []).filter { $0.custom != nil && !$0.hidden }.map(\.id).sorted().joined(separator: ",") + "|" + filter.signature
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 26) {
            ForEach(arranged) { shelf in
                ShelfRow(title: shelf.title, items: shelf.items, client: client,
                         style: shelf.id == "continue" ? .landscape : .poster,
                         ranked: shelf.ranked, logos: shelf.logos)
                    .environment(\.showsNewsMarks, shelf.id == "continue")
            }
            if loaded && arranged.isEmpty {
                ContentUnavailableView("لا توجد عناصر", systemImage: "tray").padding(.top, 40)
            } else if !loaded {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            }
        }
        .task { await load() }
        .task(id: customSignature) { await loadCustomRows() }
        // «صفوف المكتبات» lists what this library built.
        .onChange(of: rowInfos, initial: true) { _, infos in HomeRowCatalog.shared.libraries[scope.id] = infos }
        .onReceive(NotificationCenter.default.publisher(for: .plexPlaybackDidEnd)) { _ in
            Task { await load(cached: false) }
        }
    }

    /// Cached responses first (no spinner on a known library), then the server.
    private func load(cached: Bool = true) async {
        if cached && rows.isEmpty {
            await PlexResponseCache.$policy.withValue(.cacheOnly) { await fetch() }
            if !rows.isEmpty { loaded = true }
        }
        await fetch()
        loaded = true
        await loadCustomRows()
    }

    private func fetch() async {
        let new = await TVFeed.rows(client: client, store: store, filter: filter, section: scope.section)
        if !new.isEmpty { rows = new }
    }

    private func loadCustomRows() async {
        let shown = Set(rows.flatMap { $0.items.map(\.ratingKey) })
        let added = await CustomHomeRows.load(layout, client: client, filter: filter, store: store, exclude: shown)
        customRows = added.map { Shelf(id: $0.id, title: $0.title, kind: .poster, items: $0.items) }
    }
}
