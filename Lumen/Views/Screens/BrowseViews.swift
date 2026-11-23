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
                    BackdropView(url: backdrop.url, colors: backdrop.colors, colorsKey: backdrop.colorsKey, client: client)
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
        }
        .environment(\.detailNamespace, detailNamespace)
        .environment(returnState)
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
                        Spacer(minLength: 40)
                        Picker("الترتيب", selection: $sort) {
                            ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 1000)
                        // Room for the focus lift, so the picker never touches the screen edge.
                        .padding(.trailing, 20)
                    }
                    .padding(.horizontal, CardKind.inset)

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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The grid starts after the sidebar (the backdrop still fills the screen).
            .sidebarSafeArea()
            }
        }
        .task(id: sort) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .plexPlaybackDidEnd)) { _ in
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryShouldRefresh)) { _ in
            Task { await reload() }
        }
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
