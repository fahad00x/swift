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
    /// «تصفّح» (the server's pages) or «فلترة» (choices read on the device).
    @State private var filtering = false
    /// Kept with the page, so the choices stay when switching back and forth.
    @State private var filterModel = LibraryFilterModel()
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            Picker("العرض", selection: $filtering) {
                Text("تصفّح").tag(false)
                Text("فلترة").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .padding(.horizontal, Metrics(sizeClass).margin)
            .padding(.top, 4)

            if filtering {
                LibraryFilterSection(client: client, scope: scope, model: filterModel)
                    .padding(.vertical, 8)
            } else {
                browse
            }
        }
        .navigationTitle(scope.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !filtering {
                    Menu {
                        Picker("الترتيب", selection: $sort) {
                            ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                    }
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

    private var browse: some View {
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
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        BrowseStack(client: client) {
            ScrollView {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    kinds
                }
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
                        prompt: "اسم، نوع، أو «مسلسل كوميدي»")
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
            results = visible.mergingCopies(ProfileStore.shared)
        }
    }

    /// «مسلسل كوميدي», «أنمي فانتازيا»…: one tap searches by kind.
    private var kinds: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ابحث حسب النوع")
                .font(.headline)
                .foregroundStyle(.secondary)
            if Metrics(sizeClass).isWide {
                // Chips side by side at their own width, wrapping like words.
                FlowLayout(spacing: 10) { kindButtons }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], alignment: .leading, spacing: 10) {
                    kindButtons
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics(sizeClass).margin)
        .padding(.vertical)
    }

    private var kindButtons: some View {
        ForEach(SearchSuggestions.kinds, id: \.self) { kind in
            Button(kind) { query = kind }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
    }
}
