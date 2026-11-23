import SwiftUI

struct LibraryGridView: View {
    let client: PlexServerClient
    let scope: LibraryScope

    @Environment(\.contentFilter) private var filter
    @State private var items: [PlexItem] = []
    @State private var total: Int?
    @State private var sort: LibrarySort = .recentlyAdded
    @State private var isLoading = false
    @State private var loadedOnce = false
    @State private var serverOffset = 0
    @State private var exhausted = false



    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let total, total > 0 {
                    Text("\(ArabicFormat.digits(total)) عنصر")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                }
                if items.isEmpty && loadedOnce && !isLoading {
                    ContentUnavailableView("لا توجد عناصر", systemImage: "tray")
                }
                PosterGrid(items: items, client: client) { item in
                    if item.id == items.last?.id { Task { await loadMore() } }
                }
                if isLoading { ProgressView().padding() }
            }
            .padding(.vertical, 8)
        }
        .navigationTitle(scope.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("الترتيب", selection: $sort) {
                        ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                }
            }
        }
        .task(id: sort) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .plexPlaybackDidEnd)) { _ in
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryShouldRefresh)) { _ in
            Task { await reload() }
        }
    }

    /// Cached first page right away, then the server's; more pages from the server on scroll.
    private func reload() async {
        exhausted = false
        let cached = await PlexResponseCache.$policy.withValue(.cacheOnly) {
            await LibraryPager.page(client: client, scope: scope, filter: filter, sort: sort, from: 0, shown: 0)
        }
        if let cached, !cached.items.isEmpty {
            show(cached, replacing: true)
            loadedOnce = true
        } else {
            items = []
            total = nil
        }
        isLoading = true
        let fresh = await LibraryPager.page(client: client, scope: scope, filter: filter, sort: sort, from: 0, shown: 0)
        isLoading = false
        if let fresh { show(fresh, replacing: true) }
        loadedOnce = true
    }

    private func loadMore() async {
        guard !isLoading, !exhausted else { return }
        isLoading = true
        defer { isLoading = false }
        guard let page = await LibraryPager.page(client: client, scope: scope, filter: filter, sort: sort,
                                                 from: serverOffset, shown: items.count) else { return }
        show(page, replacing: false)
    }

    private func show(_ page: LibraryPage, replacing: Bool) {
        if replacing {
            var seen = Set<String>()
            items = page.items.filter { seen.insert($0.id).inserted }
        } else {
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
        }
        serverOffset = page.nextOffset
        exhausted = page.exhausted
        total = page.total ?? (page.exhausted ? items.count : nil)
    }
}

struct SearchView: View {
    let client: PlexServerClient

    @Environment(\.contentFilter) private var filter
    @State private var query = ""
    @State private var results: [PlexItem] = []
    @State private var isSearching = false

    var body: some View {
        BrowseStack(client: client) {
            ScrollView {
                if results.isEmpty && query.count >= 2 && !isSearching {
                    ContentUnavailableView.search(text: query)
                        .padding(.top, 60)
                }
                PosterGrid(items: results, client: client)
                    .padding(.top, 8)
            }
            .overlay { if isSearching && results.isEmpty { ProgressView() } }
            .navigationTitle("بحث")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "ابحث عن فيلم أو مسلسل")
        }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { results = []; return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            // Locked libraries, anime scopes and unsuitable ratings never show up in search.
            let found = (try? await client.search(q)) ?? []
            let visible = await filter.resolve(found, client: client)
            guard !Task.isCancelled else { return }
            results = visible
        }
    }
}
