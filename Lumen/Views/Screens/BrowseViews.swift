import SwiftUI

/// Wraps a browsing screen with a NavigationStack, shared backdrop and detail routing.
struct BrowseContainer<Content: View>: View {
    let client: PlexServerClient
    /// Home draws its own backdrop (the focused item's).
    var showsBackdrop = true
    @ViewBuilder let content: () -> Content
    @Environment(BackdropState.self) private var backdrop
    @Environment(\.focusSidebar) private var focusSidebar
    @Namespace private var detailNamespace
    @State private var returnState = BrowseReturnState()

    var body: some View {
        NavigationStack {
            ZStack {
                // Full screen, under the sidebar too.
                if showsBackdrop {
                    BackdropView(url: backdrop.url)
                }
                content()
            }
            // Menu on a top-level screen goes to the sidebar (pushed pages handle their own Back).
            .onExitCommand(perform: focusSidebar)
            // A new screen starts without the artwork focused on another one.
            .onAppear { if showsBackdrop, backdrop.url != nil { backdrop.url = nil } }
            .navigationDestination(for: DetailRoute.self) { route in
                // The page applies the zoom transition itself so it can follow paging.
                DetailPage(client: client, entry: route.item, context: route.context, sourceID: route.sourceID)
            }
            .navigationDestination(for: PlexItem.self) { item in
                ItemRouter(item: item, client: client)
            }
            .navigationDestination(for: BrowseRoute.self) { route in
                ItemListPage(client: client, route: route)
            }
        }
        .environment(\.detailNamespace, detailNamespace)
        .environment(returnState)
    }
}

// MARK: - Library page

/// A library like a page of Apple's TV app: its banner, a glass tab bar
/// (مقترح / تصفح / المجموعات / قوائم التشغيل / فلترة), then the chosen tab. The bar scrolls
/// away with the page when moving into the rows.
struct LibraryView: View {
    let client: PlexServerClient
    let scope: LibraryScope

    enum Tab: String, CaseIterable, Identifiable {
        case suggested, browse, collections, playlists, filter
        var id: String { rawValue }
        var title: String {
            switch self {
            case .suggested: return "مقترح"
            case .browse: return "تصفح"
            case .collections: return "المجموعات"
            case .playlists: return "قوائم التشغيل"
            case .filter: return "فلترة"
            }
        }
    }

    @Environment(ProfileStore.self) private var store
    @Environment(\.contentFilter) private var filter
    @Environment(ShowNews.self) private var news: ShowNews?
    @State private var tab: Tab = .suggested
    @State private var filterModel = LibraryFilterModel()
    @State private var banner: [BannerItem] = []
    @State private var rows: [Shelf] = []
    /// Rows the profile added to this library's «مقترح».
    @State private var customRows: [Shelf] = []
    @State private var loaded = false
    @FocusState private var bannerFocus: HeroBanner.Control?

    var body: some View {
        BrowseContainer(client: client, showsBackdrop: false) {
            ScrollViewReader { proxy in
                // The banner only on «مقترح»: the other tabs open straight on their grid.
                BannerPage(banner: tab == .suggested ? banner : [], chipTitle: scope.title, client: client,
                           bannerFocus: $bannerFocus,
                           firstRowID: BannerPageID.firstRow) {
                    Color.clear.frame(height: 1).id(BannerPageID.firstRow)
                    LibraryTabBar(selection: $tab, hasBanner: tab == .suggested && !banner.isEmpty) {
                        bannerFocus = .play
                    }
                        .padding(.top, banner.isEmpty ? 20 : 0)
                        .padding(.bottom, 40)

                    switch tab {
                    case .suggested:
                        if rows.isEmpty && loaded {
                            ContentUnavailableView("لا توجد عناصر", systemImage: "tray").frame(maxWidth: .infinity)
                        }
                        ForEach(arrangedRows) { shelf in
                            PageRow(id: shelf.id) {
                                ShelfView(shelf: shelf, client: client)
                                    .environment(\.marksNewEpisodes, shelf.id == "continue")
                            }
                        }
                    case .browse:
                        LibraryBrowseGrid(client: client, scope: scope, scrollProxy: proxy)
                    case .collections:
                        ListingGrid(client: client, path: "/library/sections/\(scope.section.key)/collections")
                    case .playlists:
                        ListingGrid(client: client, path: "/playlists", query: [("playlistType", "video")])
                    case .filter:
                        LibraryFilterGrid(client: client, scope: scope, model: filterModel, scrollProxy: proxy)
                    }
                }
            }
        }
        .task { await load() }
        .task(id: customSignature) { await loadCustomRows() }
        // The rows editor lists what this library built.
        .onChange(of: rowInfos, initial: true) { _, infos in HomeRowCatalog.shared.libraries[scope.id] = infos }
        .onAppear { if loaded { Task { await load(cached: false) } } }
        .onReceive(NotificationCenter.default.publisher(for: .plexPlaybackDidEnd)) { _ in
            Task { await load(cached: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryShouldRefresh)) { _ in
            Task { await load(cached: false) }
        }
    }

    private func load(cached: Bool = true) async {
        defer { loaded = true }
        if cached && rows.isEmpty {
            await PlexResponseCache.$policy.withValue(.cacheOnly) { await fetch() }
        }
        await fetch()
    }

    private var target: RowsTarget { .library(scope.id) }
    private var layout: [HomeRowConfig]? { target.layout(store.activeProfile?.settings) }

    /// The library's rows (as the app built them) and the ones the profile added.
    private var baseRows: [Shelf] {
        rows.shown(to: store, news: news, filter: filter, section: scope.section.key) + customRows
    }

    /// Fixed / dynamic / removed rows, as the profile arranged this library.
    private var arrangedRows: [Shelf] { HomeLayout.arrange(baseRows, id: \.id, layout: layout) }

    private var rowInfos: [HomeRowInfo] { baseRows.map { HomeRowInfo(id: $0.id, title: $0.title) } }

    /// Changes when the rows the profile added change (not when one only moves).
    private var customSignature: String {
        (layout ?? []).filter { $0.custom != nil && !$0.hidden }.map(\.id).sorted().joined(separator: ",") + "|" + filter.signature
    }

    private func loadCustomRows() async {
        let shown = Set(rows.flatMap { $0.items.map(\.ratingKey) })
        let added = await CustomHomeRows.load(layout, client: client, filter: filter, store: store, exclude: shown)
        customRows = added.map { Shelf(id: $0.id, title: $0.title, kind: .poster, items: $0.items) }
    }

    private func fetch() async {
        async let bannerTask = TVFeed.banner(client: client, store: store, filter: filter, sections: [scope.section])
        async let rowsTask = TVFeed.rows(client: client, store: store, filter: filter, section: scope.section)
        let (newBanner, newRows) = await (bannerTask, rowsTask)
        if !newBanner.isEmpty, newBanner.map(\.id) != banner.map(\.id) {
            await HeroBanner.preload(newBanner, client: client)
            banner = newBanner
        }
        if !newRows.isEmpty { rows = newRows }
    }
}

/// Glass segmented pill bar under a library's banner.
private struct LibraryTabBar: View {
    @Binding var selection: LibraryView.Tab
    /// A banner is above the tabs.
    let hasBanner: Bool
    let onUp: () -> Void

    @FocusState private var focusedTab: LibraryView.Tab?
    @FocusState private var catcherFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Up from any tab: the banner's buttons sit on one side, so the focus engine finds
            // nothing above the other tabs. Only while a tab has focus (Down from the banner
            // must not land here).
            Color.white.opacity(0.001)
                .frame(maxWidth: .infinity)
                .frame(height: 4)
                .focusable(hasBanner && (focusedTab != nil || catcherFocused))
                .focused($catcherFocused)
                .onChange(of: catcherFocused) { _, focused in
                    if focused { DispatchQueue.main.async { onUp() } }
                }
            HStack(spacing: 6) {
                ForEach(LibraryView.Tab.allCases) { tab in
                    Button { selection = tab } label: { Text(tab.title) }
                        .buttonStyle(TabPillStyle(selected: tab == selection))
                        .focused($focusedTab, equals: tab)
                }
            }
            .padding(7)
            .background {
                Capsule().fill(.ultraThinMaterial)
                Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            }
            .frame(maxWidth: .infinity)
            .focusSection()
        }
    }
}

private struct TabPillStyle: ButtonStyle {
    let selected: Bool
    /// Smaller, for choices under the tabs.
    var compact = false

    func makeBody(configuration: Configuration) -> some View { PillBody(configuration: configuration, selected: selected, compact: compact) }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let compact: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.pageContentFocused) private var pageContentFocused

        var body: some View {
            configuration.label
                .onChange(of: isFocused) { _, focused in if focused { pageContentFocused?() } }
                .font(.system(size: compact ? 23 : 26, weight: selected ? .semibold : .regular))
                .foregroundStyle(isFocused ? Color.black : (selected ? Color.white : Color.white.opacity(0.7)))
                .environment(\.colorScheme, isFocused ? .light : .dark)
                .padding(.horizontal, compact ? 24 : 30)
                .frame(height: compact ? 50 : 60)
                .background(Capsule().fill(isFocused ? Color.white : (selected ? Color.white.opacity(0.18) : Color.clear)))
                .scaleEffect(isFocused ? 1.05 : 1)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

/// «تصفح»: every title of the library as a poster grid, with sort / filter.
private struct LibraryBrowseGrid: View {
    let client: PlexServerClient
    let scope: LibraryScope
    let scrollProxy: ScrollViewProxy

    @Environment(\.contentFilter) private var filter
    @State private var items: [PlexItem] = []
    @State private var total: Int?
    @State private var sort: LibrarySort = .recentlyAdded
    @State private var isLoading = false
    @State private var loadedOnce = false
    /// Position in the server listing (differs from `items.count` when filtering on the device).
    @State private var serverOffset = 0
    @State private var exhausted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Sort choices centred under the library's tabs (same pills, smaller and without
            // the bar); the count on the reading side of the same line.
            ZStack {
                if let total, total > 0 {
                    Text("\(ArabicFormat.count(total)) عنصر")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    ForEach(LibrarySort.allCases) { option in
                        Button { sort = option } label: { Text(option.title) }
                            .buttonStyle(TabPillStyle(selected: option == sort, compact: true))
                    }
                }
                .frame(maxWidth: .infinity)
                .focusSection()
            }
            .padding(.horizontal, CardKind.inset)
            // Closer to the tabs they belong to (40 pt under the bar otherwise).
            .padding(.top, -12)

            if items.isEmpty && loadedOnce && !isLoading {
                ContentUnavailableView("لا توجد عناصر", systemImage: "tray").frame(maxWidth: .infinity)
            }

            PosterGrid(items: items, client: client, scrollProxy: scrollProxy) { item in
                if item.id == items.last?.id { Task { await loadMore() } }
            }

            if isLoading { ProgressView().frame(maxWidth: .infinity) }
        }
        .task(id: sort) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .localLibraryDidChange)) { _ in
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

/// «المجموعات» / «قوائم التشغيل»: a grid of collections or playlists (each opens its listing).
private struct ListingGrid: View {
    let client: PlexServerClient
    let path: String
    var query: [(String, String)] = []

    @State private var items: [PlexItem] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading) {
            if items.isEmpty && loaded {
                ContentUnavailableView("لا توجد عناصر", systemImage: "square.stack").frame(maxWidth: .infinity)
            }
            PosterGrid(items: items, client: client)
        }
        .task {
            items = await client.listing(path, query)
            loaded = true
        }
    }
}

/// A plain listing pushed from a collection or a playlist.
struct ItemListPage: View {
    let client: PlexServerClient
    let route: BrowseRoute

    @Environment(ShellState.self) private var shell: ShellState?

    @Environment(\.contentFilter) private var filter
    @State private var items: [PlexItem] = []
    @State private var loaded = false

    var body: some View {
        ZStack {
            BackdropView(url: nil)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(route.title)
                            .font(.system(size: 44, weight: .bold))
                            .padding(.horizontal, CardKind.inset)
                        if items.isEmpty && loaded {
                            ContentUnavailableView("لا توجد عناصر", systemImage: "tray").frame(maxWidth: .infinity)
                        }
                        PosterGrid(items: items, client: client, scrollProxy: proxy)
                    }
                    .padding(.vertical, 60)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { shell?.pushedPages += 1 }
        .onDisappear { shell?.pushedPages = max(0, (shell?.pushedPages ?? 1) - 1) }
        .task {
            let query = route.query.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            let found = await client.listing(route.path, query)
            let containers = found.filter { $0.type == "collection" || $0.type == "playlist" }
            let plain = found.filter { $0.type != "collection" && $0.type != "playlist" }
            items = containers + (await filter.resolve(plain, client: client))
            loaded = true
        }
    }
}

// MARK: - Search

struct SearchView: View {
    let client: PlexServerClient

    @Environment(\.contentFilter) private var filter
    @Environment(ProfileStore.self) private var store
    @State private var query = ""
    @State private var results: [PlexItem] = []
    /// Query the current results are for (no «no results» before a search has run).
    @State private var searched = ""
    @State private var isSearching = false
    @State private var recent: [String] = RecentSearches.load()

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        // Plain background: the focused poster's full-screen artwork would sit behind the
        // keyboard and the results would look mixed into it.
        BrowseContainer(client: client, showsBackdrop: false) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        if trimmed.isEmpty {
                            recentSearches
                            kinds
                        } else if trimmed.count < 2 {
                            hint("اكتب حرفين على الأقل")
                        } else if results.isEmpty && searched == trimmed && !isSearching {
                            ContentUnavailableView.search(text: trimmed)
                        }
                        // «مسلسلات» and «أفلام» under their own headers, the kind of the best match first.
                        ForEach(SearchResults.sections(results), id: \.kind) { section in
                            header(section.kind.title)
                            PosterGrid(items: section.items, client: client, scrollProxy: proxy,
                                       rowID: section.kind == .shows ? "search-shows" : "search-movies")
                        }
                    }
                    .padding(.top, 40)
                }
                .sidebarSafeArea()
                .searchable(text: $query, prompt: "اسم، نوع، أو «مسلسل كوميدي»")
            }
        }
        .task(id: query) {
            let q = trimmed
            guard q.count >= 2 else { results = []; searched = ""; return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            // Locked libraries, anime scopes and unsuitable ratings never show up in search.
            let found = (try? await client.search(q)) ?? []
            let visible = await filter.resolve(found, client: client)
            guard !Task.isCancelled else { return }
            // 4K and 1080p copies of a title: once.
            // Exact title matches first («mom»: Mom before Mommy).
            results = SearchResults.exactFirst(visible.mergingCopies(store), query: q)
            searched = q
            // Remembered once the term stays put a moment (not every partial word typed).
            guard !visible.isEmpty else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            recent = RecentSearches.add(q)
        }
    }

    @ViewBuilder
    private var recentSearches: some View {
        if !recent.isEmpty {
            header("عمليات البحث الأخيرة")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(recent, id: \.self) { term in
                        Button(term) { query = term }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(nil)
                    }
                }
                .padding(.horizontal, CardKind.inset)
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }

    /// «مسلسل كوميدي», «أنمي فانتازيا»…: one press searches by kind.
    private var kinds: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("ابحث حسب النوع")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(SearchSuggestions.kinds, id: \.self) { kind in
                        Button(kind) { query = kind }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(nil)
                    }
                }
                .padding(.horizontal, CardKind.inset)
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, CardKind.inset)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 28))
            .foregroundStyle(.white.opacity(0.55))
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
    }
}
