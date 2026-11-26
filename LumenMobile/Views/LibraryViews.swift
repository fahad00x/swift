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
    /// «مقترح» (rows, as on the Apple TV), «تصفّح» (the server's pages) or «فلترة» (choices read
    /// on the device).
    enum Tab: Hashable { case suggested, browse, filter }
    @State private var tab: Tab = .suggested
    private var filtering: Bool { tab == .filter }
    /// Kept with the page, so the choices stay when switching back and forth.
    @State private var filterModel = LibraryFilterModel()
    /// Sorted by name: where each letter starts, for the bar on the side.
    @State private var letters: LetterIndex?
    /// Server position the grid starts at (after jumping to a letter).
    @State private var startOffset = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var showsLetters: Bool { !filtering && sort == .title && (letters?.entries.count ?? 0) > 1 }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            Picker("العرض", selection: $tab) {
                Text("مقترح").tag(Tab.suggested)
                Text("تصفّح").tag(Tab.browse)
                Text("فلترة").tag(Tab.filter)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            .padding(.horizontal, Metrics(sizeClass).margin)
            .padding(.top, 4)
            .id("top")

            switch tab {
            case .suggested:
                LibrarySuggestedSection(client: client, scope: scope)
                    .padding(.vertical, 8)
            case .filter:
                LibraryFilterSection(client: client, scope: scope, model: filterModel)
                    .padding(.vertical, 8)
            case .browse:
                browse
                    // Room for the letter bar.
                    .padding(.trailing, showsLetters ? 14 : 0)
            }
        }
        // «#، A–Z، ا–ي» on the side, like Contacts; tap or slide to jump.
        .overlay(alignment: .trailing) {
            if showsLetters, let letters {
                LetterBar(index: letters, current: currentLetter) { entry in
                    Task { await jump(to: entry) }
                    proxy.scrollTo("top", anchor: .top)
                }
                .padding(.vertical, 8)
            }
        }
        }
        .navigationTitle(scope.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if tab == .browse {
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
        .task(id: sort) { letters = sort == .title ? await client.letters(section: scope.section) : nil }
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
                    Text("\(ArabicFormat.count(total)) عنصر")
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

    /// The letter the grid starts at (none at the start of the library).
    private var currentLetter: String? {
        guard startOffset > 0 else { return nil }
        return letters?.entries.last { $0.offset <= startOffset }?.letter
    }

    /// The grid from the first title under that letter onward.
    private func jump(to entry: LetterIndex.Entry) async {
        guard entry.offset != startOffset || items.isEmpty else { return }
        startOffset = entry.offset
        items = []
        exhausted = false
        isLoading = true
        let page = await LibraryPager.page(client: client, scope: scope, filter: filter, sort: sort,
                                           from: entry.offset, shown: 0)
        isLoading = false
        // Another letter chosen meanwhile.
        guard startOffset == entry.offset, let page else { return }
        show(page, replacing: true)
    }

    /// Cached first page right away, then the server's; more pages from the server on scroll.
    private func reload() async {
        startOffset = 0
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
    @State private var recent: [String] = RecentSearches.load()
    /// «الكل • أفلام • مسلسلات» above the results.
    @State private var kind: SearchKind = .all
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        BrowseStack(client: client) {
            ScrollView {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    recentSearches
                    kinds
                }
                if results.isEmpty && query.count >= 2 && !isSearching {
                    ContentUnavailableView.search(text: query)
                        .padding(.top, 60)
                }
                if !results.isEmpty { resultsView }
            }
            // Not once the field is cleared: the old request may still be on its way back.
            .overlay {
                if isSearching && results.isEmpty && query.trimmingCharacters(in: .whitespaces).count >= 2 {
                    ProgressView()
                }
            }
            .navigationTitle("بحث")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "اسم، نوع، أو «مسلسل كوميدي»")
            // «بحث» on the keyboard: remembered right away (if it found something).
            .onSubmit(of: .search) {
                let q = query.trimmingCharacters(in: .whitespaces)
                if q.count >= 2, !results.isEmpty { recent = RecentSearches.add(q) }
            }
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
            // Exact title matches first («mom»: Mom before Mommy).
            results = SearchResults.exactFirst(visible.mergingCopies(ProfileStore.shared), query: q)
            // Remembered once the term stays put a moment (not every partial word typed), as on Apple TV.
            guard !visible.isEmpty else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            recent = RecentSearches.add(q)
        }
    }

    /// The kind buttons, then «الكل» as a section per kind (best match's kind first), or one kind.
    private var resultsView: some View {
        let metrics = Metrics(sizeClass)
        let sections = SearchResults.sections(results)
        return VStack(alignment: .leading, spacing: 18) {
            // Only worth it when both kinds came back.
            if sections.count > 1 {
                Picker("النوع", selection: $kind) {
                    ForEach(SearchKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: metrics.isWide ? 360 : .infinity)
                .padding(.horizontal, metrics.margin)
            }
            if kind == .all || sections.count < 2 {
                ForEach(sections, id: \.kind) { section in
                    if sections.count > 1 {
                        Text(section.kind.title)
                            .font(metrics.isWide ? .title2.weight(.bold) : .title3.weight(.bold))
                            .padding(.horizontal, metrics.margin)
                    }
                    PosterGrid(items: section.items, client: client)
                }
            } else {
                PosterGrid(items: kind.filter(results), client: client)
            }
        }
        .padding(.top, 8)
    }

    /// The last searches that found something, newest first; one tap searches again.
    @ViewBuilder
    private var recentSearches: some View {
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("عمليات البحث الأخيرة")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("مسح") {
                        RecentSearches.clear()
                        withAnimation { recent = [] }
                    }
                    .font(.subheadline)
                }
                FlowLayout(spacing: 10) {
                    ForEach(recent, id: \.self) { term in
                        Button { query = term } label: {
                            Label(term, systemImage: "clock.arrow.circlepath")
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics(sizeClass).margin)
            .padding(.top)
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

/// Contacts-style index on the side: tap or slide over it; letters that don't fit are dots.
private struct LetterBar: View {
    let index: LetterIndex
    let current: String?
    let onSelect: (LetterIndex.Entry) -> Void

    @State private var touched: String?

    var body: some View {
        GeometryReader { geo in
            let entries = index.entries
            let rowHeight = geo.size.height / CGFloat(max(entries.count, 1))
            // Every letter when there is room, else every other one with a dot between.
            let step = rowHeight >= 13 ? 1 : 2
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { position, entry in
                    if position % step == 0 {
                        Text(entry.letter)
                            .font(.system(size: min(12, rowHeight * CGFloat(step) * 0.75), weight: .semibold))
                            .foregroundStyle(entry.letter == (touched ?? current) ? Theme.accent : .secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Circle().fill(.secondary).frame(width: 3, height: 3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(maxHeight: min(geo.size.height, CGFloat(entries.count) * 18))
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in select(at: value.location.y, in: geo.size.height, entries: entries) }
                .onEnded { _ in touched = nil })
            .sensoryFeedback(.selection, trigger: touched)
        }
        .frame(width: 22)
        .accessibilityElement()
        .accessibilityLabel("فهرس الحروف")
        .accessibilityAdjustableAction { direction in
            let entries = index.entries
            let at = entries.firstIndex { $0.letter == current } ?? -1
            let next = direction == .increment ? at + 1 : at - 1
            if entries.indices.contains(next) { onSelect(entries[next]) }
        }
    }

    private func select(at y: CGFloat, in height: CGFloat, entries: [LetterIndex.Entry]) {
        let barHeight = min(height, CGFloat(entries.count) * 18)
        let top = (height - barHeight) / 2
        let position = Int(((y - top) / barHeight * CGFloat(entries.count)).rounded(.down))
        let entry = entries[min(max(position, 0), entries.count - 1)]
        guard entry.letter != touched else { return }
        touched = entry.letter
        onSelect(entry)
    }
}
