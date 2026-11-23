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
/// (مقترح / تصفح / المجموعات / قوائم التشغيل / الفئات), then the chosen tab. The bar scrolls
/// away with the page when moving into the rows.
struct LibraryView: View {
    let client: PlexServerClient
    let scope: LibraryScope

    enum Tab: String, CaseIterable, Identifiable {
        case suggested, browse, collections, playlists, categories
        var id: String { rawValue }
        var title: String {
            switch self {
            case .suggested: return "مقترح"
            case .browse: return "تصفح"
            case .collections: return "المجموعات"
            case .playlists: return "قوائم التشغيل"
            case .categories: return "الفئات"
            }
        }
    }

    @Environment(ProfileStore.self) private var store
    @Environment(\.contentFilter) private var filter
    @State private var tab: Tab = .suggested
    @State private var banner: [BannerItem] = []
    @State private var rows: [Shelf] = []
    @State private var loaded = false
    @FocusState private var bannerFocus: HeroBanner.Control?

    var body: some View {
        BrowseContainer(client: client, showsBackdrop: false) {
            ScrollViewReader { proxy in
                BannerPage(banner: banner, chipTitle: scope.title, client: client, bannerFocus: $bannerFocus,
                           firstRowID: BannerPageID.firstRow) {
                    Color.clear.frame(height: 1).id(BannerPageID.firstRow)
                    LibraryTabBar(selection: $tab)
                        .padding(.top, banner.isEmpty ? 20 : 0)
                        .padding(.bottom, 40)

                    switch tab {
                    case .suggested:
                        if rows.isEmpty && loaded {
                            ContentUnavailableView("لا توجد عناصر", systemImage: "tray").frame(maxWidth: .infinity)
                        }
                        ForEach(rows) { shelf in
                            PageRow(id: shelf.id) { ShelfView(shelf: shelf, client: client) }
                        }
                    case .browse:
                        LibraryBrowseGrid(client: client, scope: scope, scrollProxy: proxy)
                    case .collections:
                        ListingGrid(client: client, path: "/library/sections/\(scope.section.key)/collections")
                    case .playlists:
                        ListingGrid(client: client, path: "/playlists", query: [("playlistType", "video")])
                    case .categories:
                        CategoryGrid(client: client, section: scope.section)
                    }
                }
            }
        }
        .task { await load() }
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

    var body: some View {
        HStack(spacing: 6) {
            ForEach(LibraryView.Tab.allCases) { tab in
                Button { selection = tab } label: { Text(tab.title) }
                    .buttonStyle(TabPillStyle(selected: tab == selection))
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

private struct TabPillStyle: ButtonStyle {
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
                .font(.system(size: 26, weight: selected ? .semibold : .regular))
                .foregroundStyle(isFocused ? Color.black : (selected ? Color.white : Color.white.opacity(0.7)))
                .environment(\.colorScheme, isFocused ? .light : .dark)
                .padding(.horizontal, 30)
                .frame(height: 60)
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
            HStack(spacing: 30) {
                if let total, total > 0 {
                    Text("\(ArabicFormat.digits(total)) عنصر").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 40)
                Picker("الترتيب", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 1000)
            }
            .padding(.horizontal, CardKind.inset)

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

/// «الفئات»: the library's genres; each opens the library filtered by it.
private struct CategoryGrid: View {
    let client: PlexServerClient
    let section: PlexDirectory

    @State private var genres: [PlexDirectory] = []
    @State private var loaded = false

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 30)], alignment: .leading, spacing: 30) {
            ForEach(genres) { genre in
                NavigationLink(value: BrowseRoute(title: ArabicFormat.genre(genre.title),
                                                  path: "/library/sections/\(section.key)/all",
                                                  query: ["genre": Self.genreID(genre.key)])) {
                    Text(ArabicFormat.genre(genre.title))
                        .font(.system(size: 28, weight: .semibold))
                        .lineLimit(1)
                        .frame(width: 340, height: 120)
                        .background(RoundedRectangle(cornerRadius: CardKind.cornerRadius, style: .continuous)
                            .fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.card)
            }
        }
        .padding(.horizontal, CardKind.inset)
        .overlay {
            if genres.isEmpty && loaded {
                ContentUnavailableView("لا توجد فئات", systemImage: "square.grid.2x2")
            }
        }
        .task {
            genres = await client.genreDirectories(section: section.key)
            loaded = true
        }
    }

    /// The genre's id: Plex gives it alone ("123") or inside a filter path ("…/all?genre=123").
    static func genreID(_ key: String) -> String {
        if let range = key.range(of: "genre=") {
            return String(key[range.upperBound...].prefix { $0 != "&" })
        }
        return key.split(separator: "/").last.map(String.init) ?? key
    }
}

/// A plain listing pushed from a collection, a playlist or a category.
struct ItemListPage: View {
    let client: PlexServerClient
    let route: BrowseRoute

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
    @State private var query = ""
    @State private var results: [PlexItem] = []
    @State private var isSearching = false

    var body: some View {
        BrowseContainer(client: client) {
            ScrollViewReader { proxy in
                ScrollView {
                    if results.isEmpty && !query.isEmpty && !isSearching {
                        ContentUnavailableView.search(text: query)
                    }
                    PosterGrid(items: results, client: client, scrollProxy: proxy)
                        .padding(.top, 40)
                }
                .sidebarSafeArea()
                .searchable(text: $query, prompt: "ابحث عن فيلم أو مسلسل")
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
            results = visible
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    let client: PlexServerClient
    let sections: [PlexDirectory]
    @Environment(AppSession.self) private var session
    @Environment(ProfileStore.self) private var store
    @Environment(SidebarPrefs.self) private var sidebarPrefs
    @Environment(\.contentFilter) private var filter
    @Environment(\.focusSidebar) private var focusSidebar
    @AppStorage(PlaybackSettings.forceTranscodeKey) private var forceTranscode = false
    @AppStorage(PlaybackSettings.engineKey) private var engine: PlaybackEngine = .mpv
    @AppStorage(PlaybackSettings.fastProfileKey) private var fastProfile = false
    @AppStorage(PlaybackSettings.autoSkipIntroKey) private var autoSkipIntro = false
    @AppStorage(PlaybackSettings.autoPlayNextKey) private var autoPlayNext = true
    @AppStorage(PlaybackSettings.maxBitrateKey) private var maxBitrate = PlaybackSettings.defaultBitrate
    @State private var editing: UserProfile?
    @State private var pin: PinRequest?

    var body: some View {
        NavigationStack {
            List {
                if let profile = store.activeProfile {
                    Section {
                        HStack(spacing: 24) {
                            ProfileAvatar(profile: profile, size: 70)
                            VStack(alignment: .leading) {
                                Text(profile.name)
                                if profile.isKids {
                                    Text("حساب أطفال").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button("تبديل المستخدم") { store.deactivate() }
                        Button("إعدادات المستخدم") { editProfile(profile) }
                        Toggle("تذكّر آخر مستخدم", isOn: Binding(get: { store.rememberLastProfile },
                                                               set: { store.setRememberLastProfile($0) }))
                    } header: {
                        Text("المستخدم")
                    } footer: {
                        Text("مع «تذكّر آخر مستخدم» يفتح التطبيق على آخر مستخدم مباشرة بدون شاشة «مين يشاهد؟».")
                    }

                    Section {
                        LabeledContent("المزامنة", value: store.cloudStatus.description)
                        if store.cloudStatus != .localOnly {
                            Button("مزامنة الآن") { Task { await store.syncNow() } }
                        }
                    } header: {
                        Text("iCloud")
                    } footer: {
                        Text("بيانات كل مستخدم (التقدّم، المشاهَد، قائمتي، المكتبات) محفوظة في iCloud وعلى الجهاز، ولا تُرسل إلى Plex.")
                    }
                }

                if !filter.scopes.isEmpty {
                    Section {
                        ForEach(filter.scopes) { scope in
                            sidebarRow(scope)
                        }
                    } header: {
                        Text("مكتبات الشريط الجانبي")
                    } footer: {
                        Text("اختر حتى \(ArabicFormat.digits(SidebarPrefs.maxPinned)) مكتبات تظهر في الشريط الجانبي بهذا الترتيب، والباقي تحت «المزيد». زر السهم يقدّم المكتبة خطوة.")
                    }
                }

                Section("حساب Plex") {
                    HStack(spacing: 24) {
                        RemoteImage(url: session.user?.thumb.flatMap(URL.init(string:)))
                            .frame(width: 70, height: 70)
                            .background(Circle().fill(Color.white.opacity(0.1)))
                            .clipShape(Circle())
                        VStack(alignment: .leading) {
                            Text(session.user?.displayName ?? "Plex")
                            if let email = session.user?.email {
                                Text(email).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("تسجيل الخروج", role: .destructive) { guarded { session.signOut() } }
                }

                Section("الخادم") {
                    LabeledContent("متصل بـ", value: client.name)
                    LabeledContent("نوع الاتصال", value: client.isLocal ? "شبكة محلية" : "عن بُعد")
                    LibrarySyncStatusRow()
                    // Full reload: connection, libraries and every screen from the server.
                    Button {
                        Task { await session.refreshLibrary() }
                    } label: {
                        HStack {
                            Text("تحديث المكتبة")
                            Spacer()
                            if session.isRefreshing { ProgressView() }
                        }
                    }
                    .disabled(session.isRefreshing)
                    if session.servers.count > 1 {
                        Button("تغيير الخادم") { guarded { session.chooseAnotherServer() } }
                    }
                }

                Section {
                    Picker("مشغّل الفيديو", selection: $engine) {
                        ForEach(PlaybackEngine.allCases) { Text($0.title).tag($0) }
                    }
                    if engine == .mpv {
                        Toggle("وضع الأداء العالي (لأجهزة Apple TV الأقدم)", isOn: $fastProfile)
                    }
                    Picker("الحد الأقصى للجودة", selection: $maxBitrate) {
                        ForEach(PlaybackSettings.bitrateOptions, id: \.kbps) { option in
                            Text(option.title).tag(option.kbps)
                        }
                    }
                    Toggle("فرض التحويل عبر الخادم (Transcode)", isOn: $forceTranscode)
                } header: {
                    Text("التشغيل")
                } footer: {
                    Text(engine == .mpv
                         ? "مشغّل Lumen يشغّل الملف الأصلي مباشرة بكل صيغه (MKV، HEVC، 4K، HDR10، Dolby Vision، DTS، TrueHD، ترجمات ASS/PGS) دون تحويل في الخادم. فعّل «مطابقة المحتوى» في إعدادات Apple TV ← الفيديو والصوت ليتحوّل التلفاز تلقائياً إلى HDR ومعدل الإطارات الصحيح."
                         : "مشغّل النظام يشغّل MP4/MOV مباشرة، وباقي الصيغ يحوّلها خادم Plex.")
                }

                Section {
                    Toggle("تخطي المقدمة تلقائياً", isOn: $autoSkipIntro)
                    Toggle("تشغيل الحلقة التالية تلقائياً", isOn: $autoPlayNext)
                } header: {
                    Text("المقدمة والختام")
                } footer: {
                    Text("يظهر زر «تخطي المقدمة» و«الحلقة التالية» عندما يكتشف خادم Plex المقدمة وشارة النهاية (ميزة Plex Pass: فعّل Intro/Credits detection في إعدادات المكتبة).")
                }

                Section("حول") {
                    LabeledContent("الإصدار", value: PlexClientInfo.version)
                    LabeledContent("رقم البناء", value: PlexClientInfo.build)
                }
            }
            .frame(maxWidth: 1300)
            // Centred in the area next to the sidebar.
            .frame(maxWidth: .infinity)
            .sidebarPadding()
            .navigationTitle("الإعدادات")
            // Menu on Settings goes to the sidebar (pushed pickers handle their own Back).
            .onExitCommand(perform: focusSidebar)
            // Follow the profile to its other devices.
            .onChange(of: autoSkipIntro) { _, on in store.updateSettings { $0.autoSkipIntro = on } }
            .onChange(of: autoPlayNext) { _, on in store.updateSettings { $0.autoPlayNext = on } }
        }
        .fullScreenCover(item: $editing) { profile in
            ProfileEditorView(client: client, sections: sections, existing: profile)
        }
        .pinRequest($pin)
    }

    private func sidebarRow(_ scope: LibraryScope) -> some View {
        let position = sidebarPrefs.pinned(from: filter.scopes).firstIndex { $0.id == scope.id }
        return HStack(spacing: 30) {
            Button {
                sidebarPrefs.toggle(scope, in: filter.scopes)
            } label: {
                HStack(spacing: 20) {
                    Image(systemName: position != nil ? "checkmark.circle.fill" : "circle")
                    Image(systemName: scope.icon)
                    Text(scope.title)
                    Spacer()
                    if let position {
                        Text(ArabicFormat.digits(position + 1)).foregroundStyle(.secondary)
                    }
                }
            }
            if let position, position > 0 {
                Button {
                    sidebarPrefs.moveUp(scope, in: filter.scopes)
                } label: {
                    Image(systemName: "arrow.up")
                }
            }
        }
    }

    /// A kids profile needs the main profile's PIN to open its settings.
    private func editProfile(_ profile: UserProfile) {
        let editors = profile.isKids ? ProfileGate.editors(for: profile, store: store) : []
        guard !editors.isEmpty else { editing = profile; return }
        pin = PinRequest(title: "رمز المستخدم الرئيسي", subtitle: "مطلوب لتغيير إعدادات حساب الأطفال",
                         profiles: editors) { editing = profile }
    }

    /// Account-wide actions from a kids profile also need the main PIN.
    private func guarded(_ action: @escaping () -> Void) {
        guard let profile = store.activeProfile, profile.isKids else { action(); return }
        let editors = ProfileGate.editors(for: profile, store: store)
        guard !editors.isEmpty else { action(); return }
        pin = PinRequest(title: "رمز المستخدم الرئيسي", profiles: editors, onSuccess: action)
    }
}
