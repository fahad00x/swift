import SwiftUI

struct HomeView: View {
    let client: PlexServerClient

    @Environment(ProfileStore.self) private var store
    @Environment(\.contentFilter) private var filter
    @State private var feed = HomeFeed()
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var shownSignature: String?
    /// Rows the profile added (Settings → «صفوف الرئيسية»).
    @State private var customRows: [HomeFeed.Row] = []
    @Environment(ShowNews.self) private var news: ShowNews?
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        BrowseStack(client: client) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if !feed.featured.isEmpty {
                        HeroPager(items: feed.featured, client: client)
                    }
                    // Fixed / dynamic / removed rows and the rows the profile added, as it
                    // arranged them (the same arrangement on every device).
                    ForEach(homeRows) { row in
                        switch row.id {
                        case "continue":
                            ShelfRow(title: row.title, items: row.items, client: client,
                                     style: .landscape, logos: feed.continueLogos)
                                .environment(\.showsNewsMarks, true)
                        case "mylist":
                            ShelfRow(title: row.title, items: row.items, client: client)
                                .environment(\.showsNewsMarks, true)
                        default:
                            ShelfRow(title: row.title, items: row.items, client: client, ranked: row.ranked)
                        }
                    }
                    if !isLoading && feed.isEmpty && homeRows.isEmpty {
                        ContentUnavailableView("لا يوجد محتوى", systemImage: "film.stack",
                                               description: Text(filter.scopes.isEmpty
                                                                 ? "لا توجد مكتبات مفتوحة لهذا المستخدم. افتحها من الإعدادات ← إعدادات المستخدم."
                                                                 : "أضف أفلاماً ومسلسلات إلى خادم Plex لتظهر هنا."))
                            .padding(.top, 80)
                    }
                }
                .padding(.bottom, 30)
            }
            .ignoresSafeArea(edges: feed.featured.isEmpty ? [] : .top)
            .topScrim(after: feed.featured.isEmpty ? 4 : Metrics(sizeClass).heroHeight * 0.6)
            .overlay {
                if isLoading && feed.isEmpty { LoadingView() }
            }
            .overlay(alignment: .bottom) { LibrarySyncBanner().padding(.bottom, 16) }
            .refreshable { await load(showCached: false) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { profileButton }
                ToolbarItem(placement: .topBarTrailing) {
                    // Small, non-blocking refresh indicator.
                    if isRefreshing && !feed.isEmpty { ProgressView().controlSize(.small) }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        // Re-runs when the profile's visible libraries / kids mode / genres change; then it
        // starts from that content's own saved Home, never keeping rows from hidden libraries.
        .task(id: filter.signature) {
            if let shown = shownSignature, shown != filter.signature { feed = HomeFeed() }
            shownSignature = filter.signature
            // A library just enabled starts downloading in the background.
            LibrarySync.shared.start(client: client, force: true)
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .plexPlaybackDidEnd)) { _ in
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .profileDataDidChangeRemotely)) { _ in
            guard !PlaybackManager.shared.isPlaying else { return }
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryShouldRefresh)) { _ in
            Task { await load(showCached: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .localLibraryDidChange)) { _ in
            Task { await load(showCached: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .myListDidChange)) { _ in
            Task { feed.myList = await UserFeed.myList(store: store, client: client, filter: filter) }
        }
        .task(id: customSignature) { await loadCustomRows() }
        // «صفوف الرئيسية» lists what Home built.
        .onChange(of: rowInfos, initial: true) { _, infos in HomeRowCatalog.shared.rows = infos }
    }

    // MARK: Rows

    private var layout: [HomeRowConfig]? { store.activeProfile?.settings?.homeRows }

    /// Home's rows as the app built them: Continue Watching, «قائمتي», the feed's rows, then
    /// the rows the profile added.
    private var baseRows: [HomeFeed.Row] {
        var out: [HomeFeed.Row] = []
        let continuing = ContinueActions.shown(feed.continueWatching, store: store, news: news, filter: filter)
        if !continuing.isEmpty { out.append(HomeFeed.Row(id: "continue", title: "متابعة المشاهدة", items: continuing)) }
        if !feed.myList.isEmpty { out.append(HomeFeed.Row(id: "mylist", title: "قائمتي", items: feed.myList)) }
        return out + feed.rows + customRows
    }

    private var homeRows: [HomeFeed.Row] { HomeLayout.arrange(baseRows, id: \.id, layout: layout) }

    private var rowInfos: [HomeRowInfo] { baseRows.map { HomeRowInfo(id: $0.id, title: $0.title) } }

    /// Changes when the rows the profile added change (not when one only moves).
    private var customSignature: String {
        (layout ?? []).filter { $0.custom != nil && !$0.hidden }.map(\.id).sorted().joined(separator: ",") + "|" + filter.signature
    }

    private func loadCustomRows() async {
        // A saved filter's row doesn't repeat what Home's own rows show.
        let shown = Set((feed.continueWatching + feed.myList + feed.rows.flatMap(\.items)).map(\.ratingKey))
        let added = await CustomHomeRows.load(layout, client: client, filter: filter, store: store, exclude: shown)
        customRows = added.map { HomeFeed.Row(id: $0.id, title: $0.title, items: $0.items) }
    }

    /// Current profile; tap to go back to «مين يشاهد؟».
    @ViewBuilder
    private var profileButton: some View {
        if let profile = store.activeProfile {
            Button { store.deactivate() } label: {
                ProfileAvatar(profile: profile, size: 32)
            }
            .accessibilityLabel("تبديل المستخدم (\(profile.name))")
        }
    }

    /// Cached library first (no spinner), then the server in the background.
    private func load(showCached: Bool = true) async {
        isRefreshing = true
        defer { isRefreshing = false; isLoading = false }
        await HomeFeed.loadCacheFirst(client: client, store: store, filter: filter,
                                      showCached: showCached && feed.isEmpty, current: feed) { new in
            // Keep the current slide when nothing visible changed (e.g. after playback).
            var updated = new
            if new.featured == feed.featured { updated.featured = feed.featured }
            feed = updated
        }
        await loadCustomRows()
    }
}

// MARK: - Hero

/// Swipeable featured items at the top of Home (auto-advances every 7 s).
struct HeroPager: View {
    let items: [FeaturedItem]
    let client: PlexServerClient

    @State private var selection: String?
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        TabView(selection: $selection) {
            ForEach(items) { item in
                HeroSlide(item: item, client: client)
                    .tag(Optional(item.id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .frame(height: Metrics(sizeClass).heroHeight)
        .task(id: selection) {
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled, items.count > 1, !PlaybackManager.shared.isPlaying else { return }
            let index = items.firstIndex { $0.id == selection } ?? 0
            withAnimation { selection = items[(index + 1) % items.count].id }
        }
        .onAppear { if selection == nil { selection = items.first?.id } }
        .onChange(of: items.map(\.id)) { _, ids in
            // New suggestions: never stay on a page that no longer exists (blank hero).
            if let selection, ids.contains(selection) { return }
            selection = ids.first
        }
    }
}

private struct HeroSlide: View {
    let item: FeaturedItem
    let client: PlexServerClient

    @Environment(ProfileStore.self) private var store
    @State private var showEpisode: PlexItem?
    @State private var starting = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let metrics = Metrics(sizeClass)
        ZStack(alignment: .bottom) {
            Color.black
            // A wide iPad shows the landscape backdrop; the iPhone the portrait poster.
            if metrics.isWide {
                RemoteImage(url: client.imageURL(item.display.backdropPath ?? item.display.thumb, width: 1920, height: 1080))
            } else {
                RemoteImage(url: client.imageURL(item.display.thumb ?? item.display.backdropPath, width: 900, height: 1350))
            }
            LinearGradient(stops: [
                .init(color: .black.opacity(0.35), location: 0),
                .init(color: .clear, location: 0.25),
                .init(color: .black.opacity(0.6), location: 0.6),
                .init(color: .black, location: 1),
            ], startPoint: .top, endPoint: .bottom)

            VStack(spacing: 12) {
                Text(eyebrow)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                TitleLogo(item: item.display, client: client, maxHeight: metrics.logoHeight)
                Text(metaLine)
                    .font(metrics.isWide ? .subheadline : .caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)

                HStack(spacing: 12) {
                    Button(action: play) {
                        Label(playTitle, systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(.white))
                            .foregroundStyle(.black)
                    }
                    Button { store.toggleMyList(item.display.mediaInfo) } label: {
                        Image(systemName: store.isOnMyList(item.display.ratingKey) ? "checkmark" : "plus")
                            .font(.headline)
                            .frame(width: 46, height: 46)
                            .background(Circle().fill(.white.opacity(0.2)))
                            .foregroundStyle(.white)
                    }
                    NavigationLink(value: item.display) {
                        Image(systemName: "info")
                            .font(.headline)
                            .frame(width: 46, height: 46)
                            .background(Circle().fill(.white.opacity(0.2)))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: metrics.actionsWidth)
                .padding(.horizontal, 28)
            }
            .padding(.bottom, metrics.isWide ? 56 : 44)
        }
        .clipped()
        .task(id: item.id) {
            if item.playable == nil, item.display.isShow, showEpisode == nil {
                showEpisode = await client.episodeToPlay(showKey: item.display.ratingKey)
            }
        }
    }

    private var metaLine: String {
        let d = item.display
        var parts: [String] = [d.isShow ? "مسلسل" : "فيلم"]
        parts += ArabicFormat.genres(d.genres.map(\.tag), limit: 2)
        if let year = d.year { parts.append(ArabicFormat.digits(year)) }
        return ArabicFormat.joined(parts)
    }

    private var target: PlexItem? { item.playable ?? showEpisode ?? (item.display.isShow ? nil : item.display) }

    /// «لم تكمله» alone when the button already says «استئناف الموسم ٣ • الحلقة ٢».
    private var eyebrow: String {
        guard playTitle != "تشغيل", playTitle != "استئناف",
              let code = item.playable?.episodeCode else { return item.eyebrow }
        let suffix = ArabicFormat.separator + code
        return item.eyebrow.hasSuffix(suffix) ? String(item.eyebrow.dropLast(suffix.count)) : item.eyebrow
    }

    private var playTitle: String {
        let verb = (target?.progress != nil && target?.isWatched == false) ? "استئناف" : "تشغيل"
        if item.display.isShow, let code = target?.episodeCode { return "\(verb) \(code)" }
        return verb
    }

    private func play() {
        guard !starting else { return }
        starting = true
        Task {
            defer { starting = false }
            var playable = target
            if playable == nil, item.display.isShow {
                playable = await client.episodeToPlay(showKey: item.display.ratingKey)
            }
            guard let playable else { return }
            await PlaybackManager.shared.play(playable, client: client)
        }
    }
}

/// Clear logo when Plex has one, otherwise the title.
struct TitleLogo: View {
    let item: PlexItem
    let client: PlexServerClient
    var maxHeight: CGFloat = 80

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: maxHeight * 3.1, maxHeight: maxHeight)
            } else if failed || item.clearLogoPath == nil {
                Text(item.title)
                    .font(.system(size: 32, weight: .heavy))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
            } else {
                Color.clear.frame(height: maxHeight)
            }
        }
        .task(id: item.ratingKey) {
            guard let url = client.imageURL(item.clearLogoPath, width: 840, height: 280, png: true) else {
                failed = true
                return
            }
            image = await ImageLoader.shared.image(for: url)
            failed = image == nil
        }
    }
}
