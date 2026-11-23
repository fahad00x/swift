import SwiftUI

struct MainTabView: View {
    let client: PlexServerClient
    let sections: [PlexDirectory]
    let profile: UserProfile

    @Environment(ProfileStore.self) private var store
    @State private var newSections: [PlexDirectory] = []

    var body: some View {
        let filter = ContentFilter(profile: profile, sections: sections)
        TabView {
            HomeView(client: client)
                .tabItem { Label("الرئيسية", systemImage: "house.fill") }
            // Only the libraries this profile opened, in its own order.
            ForEach(filter.scopes) { scope in
                LibraryView(client: client, scope: scope)
                    .tabItem { Label(scope.title, systemImage: scope.icon) }
            }
            SearchView(client: client)
                .tabItem { Label("بحث", systemImage: "magnifyingglass") }
            SettingsView(client: client, sections: sections)
                .tabItem { Label("الإعدادات", systemImage: "gearshape") }
        }
        .environment(\.contentFilter, filter)
        .task { checkForNewLibraries() }
        .alert(newLibraryTitle, isPresented: Binding(get: { !newSections.isEmpty }, set: { if !$0 { newSections = [] } })) {
            Button("إضافة") { acknowledge(enable: true) }
            Button("لا", role: .cancel) { acknowledge(enable: false) }
        } message: {
            Text("«\(newSections.map(\.title).joined(separator: "»، «"))» — تبي تضيفها لمكتباتك؟")
        }
    }

    private var newLibraryTitle: String {
        newSections.count > 1 ? "فيه مكتبات جديدة" : "فيه مكتبة جديدة"
    }

    /// Libraries added to the server since the profile last looked start locked; ask once.
    private func checkForNewLibraries() {
        let unknown = sections.filter { !profile.knownSections.contains($0.key) }
        guard !unknown.isEmpty else { return }
        if profile.isKids {
            // Kids can't change their libraries without the main PIN: keep them locked.
            store.acknowledgeSections(unknown.map(\.key), enable: false)
        } else {
            newSections = unknown
        }
    }

    private func acknowledge(enable: Bool) {
        let keys = newSections.map(\.key)
        newSections = []
        store.acknowledgeSections(keys, enable: enable)
    }
}

/// Wraps a browsing screen with a NavigationStack, shared backdrop and detail routing.
struct BrowseContainer<Content: View>: View {
    let client: PlexServerClient
    @ViewBuilder let content: () -> Content
    @Environment(BackdropState.self) private var backdrop
    @Namespace private var detailNamespace
    @State private var returnState = BrowseReturnState()

    var body: some View {
        NavigationStack {
            ZStack {
                BackdropView(url: backdrop.url)
                content()
            }
            .navigationDestination(for: DetailRoute.self) { route in
                // The page applies the zoom transition itself so it can follow paging.
                DetailPage(client: client, entry: route.item, context: route.context, sourceID: route.sourceID)
            }
            .navigationDestination(for: PlexItem.self) { item in
                ItemRouter(item: item, client: client)
            }
        }
        .environment(\.detailNamespace, detailNamespace)
        .environment(returnState)
    }
}

// MARK: - Home

struct HomeView: View {
    let client: PlexServerClient

    @Environment(BackdropState.self) private var backdrop
    @Environment(ProfileStore.self) private var store
    @Environment(\.contentFilter) private var filter
    @State private var featured: [FeaturedItem] = []
    @State private var continueWatching: [PlexItem] = []
    @State private var myList: [PlexItem] = []
    @State private var shelves: [Shelf] = []
    /// Full-screen spinner only while nothing (not even the cache) can be shown.
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var showingPicker = false

    @State private var continueLogos: [String: String] = [:]

    /// How much of the hero image the "Continue Watching" row sits on.
    private let continueOverlap: CGFloat = 320

    private var isEmpty: Bool { featured.isEmpty && continueWatching.isEmpty && shelves.isEmpty && myList.isEmpty }

    var body: some View {
        BrowseContainer(client: client) {
            if isLoading && isEmpty {
                LoadingView()
            } else if isEmpty {
                VStack(spacing: 40) {
                    profileButton
                    ContentUnavailableView("لا يوجد محتوى", systemImage: "film.stack",
                                           description: Text(filter.scopes.isEmpty
                                                             ? "لا توجد مكتبات مفتوحة لهذا المستخدم. افتحها من الإعدادات ← إعدادات المستخدم."
                                                             : "أضف أفلاماً ومسلسلات إلى خادم Plex لتظهر هنا."))
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 6) {
                            profileButton
                                .padding(.top, featured.isEmpty ? 40 : 0)
                                .zIndex(2)

                            if !featured.isEmpty {
                                HeroCarousel(items: featured, client: client,
                                             bottomInset: continueWatching.isEmpty ? 40 : continueOverlap) {
                                    withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo("hero", anchor: .top) }
                                }
                                .id("hero")
                                // The avatar row sits over the top of the hero image.
                                .padding(.top, -profileRowHeight)
                            }

                            if !continueWatching.isEmpty {
                                ShelfView(shelf: Shelf(id: "continue", title: "متابعة المشاهدة",
                                                       kind: .landscape, items: continueWatching,
                                                       logos: continueLogos),
                                          client: client)
                                    // Sits on the lower part of the hero image, like the Apple TV app.
                                    .padding(.top, featured.isEmpty ? 30 : -continueOverlap)
                                    .zIndex(1)
                            }

                            if !myList.isEmpty {
                                ShelfView(shelf: Shelf(id: "mylist", title: "قائمتي", kind: .poster, items: myList),
                                          client: client)
                            }

                            ForEach(shelves) { shelf in
                                ShelfView(shelf: shelf, client: client)
                            }
                        }
                        .padding(.bottom, 60)
                    }
                    .ignoresSafeArea()
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if isRefreshing && !isEmpty {
                // Small, non-blocking refresh indicator.
                ProgressView()
                    .scaleEffect(0.6)
                    .padding(.top, 40)
                    .padding(.horizontal, 60)
                    .allowsHitTesting(false)
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .plexPlaybackDidEnd)) { _ in
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryShouldRefresh)) { _ in
            Task { await load(showCached: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .profileDataDidChangeRemotely)) { _ in
            guard !PlaybackManager.shared.isPlaying else { return }
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .myListDidChange)) { _ in
            Task { myList = await UserFeed.myList(store: store, client: client, filter: filter) }
        }
    }

    private let profileRowHeight: CGFloat = 150

    /// Small avatar of the current profile at the top of Home; opens «مين يشاهد؟».
    @ViewBuilder
    private var profileButton: some View {
        if let profile = store.activeProfile {
            HStack {
                Button { store.deactivate() } label: {
                    HStack(spacing: 16) {
                        ProfileAvatar(profile: profile, size: 64)
                        Text(profile.name).font(.callout.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                }
                .buttonStyle(ProfileChipStyle())
                Spacer()
            }
            .padding(.horizontal, 80)
            .frame(height: profileRowHeight)
            .focusSection()
        }
    }

    /// Cached library first (no spinner), then the server in the background.
    private func load(showCached: Bool = true) async {
        isRefreshing = true
        defer { isRefreshing = false; isLoading = false }
        let current = HomeFeed(featured: featured, continueWatching: continueWatching,
                               continueLogos: continueLogos, myList: myList, rows: [])
        await HomeFeed.loadCacheFirst(client: client, store: store, filter: filter,
                                      showCached: showCached && isEmpty, current: current) { apply($0) }
    }

    private func apply(_ feed: HomeFeed) {
        continueWatching = feed.continueWatching
        continueLogos = feed.continueLogos
        myList = feed.myList
        shelves = feed.rows.map { Shelf(id: $0.id, title: $0.title, kind: .poster, items: $0.items, ranked: $0.ranked) }
        // Keep the current slide when nothing visible changed (e.g. after playback).
        if feed.featured != featured { featured = feed.featured }

        if backdrop.url == nil, let first = (continueWatching.first ?? shelves.first?.items.first) {
            backdrop.url = client.imageURL(first.backdropPath, width: 1920, height: 1080)
        }
    }
}

/// Small capsule around the profile avatar on Home.
private struct ProfileChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration)
    }

    private struct ChipBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .padding(.vertical, 8)
                .padding(.trailing, 18)
                .background(Capsule().fill(isFocused ? Color.white : Color.black.opacity(0.35)))
                .scaleEffect(configuration.isPressed ? 0.95 : (isFocused ? 1.1 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 14, y: 8)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

// MARK: - Library grid

struct LibraryView: View {
    let client: PlexServerClient
    let scope: LibraryScope

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
        BrowseContainer(client: client) {
            ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 30) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(scope.title).font(.title2.weight(.bold))
                            if let total, total > 0 {
                                Text("\(ArabicFormat.digits(total)) عنصر").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Picker("الترتيب", selection: $sort) {
                            ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 1000)
                    }
                    .padding(.horizontal, 80)

                    if items.isEmpty && loadedOnce && !isLoading {
                        ContentUnavailableView("لا توجد عناصر", systemImage: "tray")
                            .frame(maxWidth: .infinity)
                    }

                    PosterGrid(items: items, client: client, scrollProxy: proxy) { item in
                        if item.id == items.last?.id { Task { await loadMore() } }
                    }

                    if isLoading { ProgressView().frame(maxWidth: .infinity) }
                }
                .padding(.vertical, 30)
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
            .navigationTitle("الإعدادات")
        }
        .fullScreenCover(item: $editing) { profile in
            ProfileEditorView(client: client, sections: sections, existing: profile)
        }
        .pinRequest($pin)
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
