import SwiftUI

// Apple TV layout: a collapsible sidebar on the left (an icon rail that expands while it has
// focus) next to the selected screen, a clock in the top corner, and a Home that shows the
// focused item's details and backdrop above the rows.

enum TVDestination: Hashable {
    case profile
    case myList
    case search
    case home
    case library(String)
    case more
    case settings
}

/// The four libraries pinned to the sidebar (per profile, chosen in Settings); the rest are under «المزيد».
@MainActor
@Observable
final class SidebarPrefs {
    static let maxPinned = 4

    private let key: String
    private var pinnedIDs: [String]?

    /// From the profile (synced through iCloud); older builds kept it on the device only.
    init(profileID: String) {
        key = "sidebar.libraries.\(profileID)"
        let profile = ProfileStore.shared.profiles.first { $0.id == profileID }
        pinnedIDs = profile?.settings?.sidebarScopes ?? UserDefaults.standard.stringArray(forKey: key)
    }

    /// Pinned libraries in order (the first four by default).
    ///
    /// Saved ids can go stale (a library removed or renamed on the server, a scope split into
    /// anime / non-anime, or a choice synced from another device with other libraries). When
    /// none of the saved ids match an open library any more, the sidebar used to show the
    /// «المكتبات» header with nothing under it; it now falls back to the default first four.
    /// An explicitly empty choice (everything under «المزيد») is kept.
    func pinned(from scopes: [LibraryScope]) -> [LibraryScope] {
        guard let pinnedIDs, !pinnedIDs.isEmpty else {
            return pinnedIDs == nil ? Array(scopes.prefix(Self.maxPinned)) : []
        }
        let chosen = pinnedIDs.compactMap { id in scopes.first { $0.id == id } }
        if chosen.isEmpty { return Array(scopes.prefix(Self.maxPinned)) }
        return Array(chosen.prefix(Self.maxPinned))
    }

    func isPinned(_ scope: LibraryScope, in scopes: [LibraryScope]) -> Bool {
        pinned(from: scopes).contains { $0.id == scope.id }
    }

    /// Adds (dropping the last one when four are pinned) or removes a library.
    func toggle(_ scope: LibraryScope, in scopes: [LibraryScope]) {
        var ids = pinned(from: scopes).map(\.id)
        if let i = ids.firstIndex(of: scope.id) {
            ids.remove(at: i)
        } else {
            if ids.count >= Self.maxPinned { ids.removeLast() }
            ids.append(scope.id)
        }
        save(ids)
    }

    func moveUp(_ scope: LibraryScope, in scopes: [LibraryScope]) {
        var ids = pinned(from: scopes).map(\.id)
        guard let i = ids.firstIndex(of: scope.id), i > 0 else { return }
        ids.swapAt(i, i - 1)
        save(ids)
    }

    private func save(_ ids: [String]) {
        pinnedIDs = ids
        UserDefaults.standard.set(ids, forKey: key)
        ProfileStore.shared.updateSettings { $0.sidebarScopes = ids }
    }
}

/// Lets a screen send focus back to the sidebar (Menu on a root screen).
private struct FocusSidebarKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var focusSidebar: (() -> Void)? {
        get { self[FocusSidebarKey.self] }
        set { self[FocusSidebarKey.self] = newValue }
    }
}

/// Room the floating sidebar takes on the leading (right) edge. Screens fill the whole screen
/// (backgrounds run under the sidebar); only scrolling / focusable content is inset by this.
private struct SidebarInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var sidebarInset: CGFloat {
        get { self[SidebarInsetKey.self] }
        set { self[SidebarInsetKey.self] = newValue }
    }
}

extension View {
    /// For a ScrollView (row or grid): its content starts after the sidebar but can scroll
    /// underneath it, and focus-driven scrolling keeps the focused item out from under it.
    func sidebarSafeArea() -> some View { modifier(SidebarSafeArea()) }

    /// For static content (titles, text blocks): a plain leading padding past the sidebar.
    func sidebarPadding(_ extra: CGFloat = 0) -> some View { modifier(SidebarPadding(extra: extra)) }
}

private struct SidebarSafeArea: ViewModifier {
    @Environment(\.sidebarInset) private var inset
    func body(content: Content) -> some View { content.safeAreaPadding(.leading, inset) }
}

private struct SidebarPadding: ViewModifier {
    let extra: CGFloat
    @Environment(\.sidebarInset) private var inset
    func body(content: Content) -> some View { content.padding(.leading, inset + extra) }
}

struct MainTabView: View {
    let client: PlexServerClient
    let sections: [PlexDirectory]
    let profile: UserProfile

    /// Distance of the floating sidebar from the screen edge (the right, in Arabic).
    static let railMargin: CGFloat = 30
    /// Width of the collapsed sidebar capsule.
    static let railWidth: CGFloat = 96
    /// Where scrolling content starts: past the collapsed capsule plus a small gap.
    static let railInset: CGFloat = railMargin + railWidth + 24

    @Environment(ProfileStore.self) private var store
    @State private var newSections: [PlexDirectory] = []
    @State private var selection: TVDestination = .home
    @State private var prefs: SidebarPrefs
    @FocusState private var sidebarFocus: TVDestination?
    @Namespace private var shellNamespace

    init(client: PlexServerClient, sections: [PlexDirectory], profile: UserProfile) {
        self.client = client
        self.sections = sections
        self.profile = profile
        _prefs = State(initialValue: SidebarPrefs(profileID: profile.id))
    }

    private var sidebarOpen: Bool { sidebarFocus != nil }

    var body: some View {
        let filter = ContentFilter(profile: profile, sections: sections)
        let pinned = prefs.pinned(from: filter.scopes)
        let rest = filter.scopes.filter { scope in !pinned.contains { $0.id == scope.id } }

        // Arabic layout: the sidebar floats on the leading side, which is the right. Screens
        // fill the whole screen (their backgrounds run under the sidebar); the inset reaches
        // only their scrolling content, through the environment.
        ZStack(alignment: .leading) {
            Color.black.ignoresSafeArea()

            content(filter: filter, rest: rest)
                .environment(\.focusSidebar, { sidebarFocus = selection })
                .environment(\.sidebarInset, Self.railInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .prefersDefaultFocus(true, in: shellNamespace)

            // Darkens the right edge, so the sidebar icons read over light artwork and rows
            // fade out as they scroll under it.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.railInset + 200)
            }
            .environment(\.layoutDirection, .leftToRight)
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // The content dims while the menu is open.
            Color.black
                .opacity(sidebarOpen ? 0.5 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            TVSidebar(selection: $selection, focus: $sidebarFocus, profile: profile,
                      pinned: pinned, hasMore: !rest.isEmpty) {
                store.deactivate()
            } onSelect: { destination in
                selection = destination
                // Hand focus to the chosen screen; the panel collapses to the rail.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { sidebarFocus = nil }
            }
            .padding(.leading, Self.railMargin)
        }
        .animation(.easeOut(duration: 0.2), value: sidebarOpen)
        .focusScope(shellNamespace)
        .overlay(alignment: .topTrailing) {
            // Opposite corner from the sidebar: the clock, and under it the first-sync progress.
            VStack(alignment: .trailing, spacing: 14) {
                ClockView()
                LibrarySyncBanner()
            }
            .padding(.top, 4)
            .padding(.trailing, 64)
            .allowsHitTesting(false)
        }
        .environment(\.contentFilter, filter)
        .environment(prefs)
        .ignoresSafeArea(.container, edges: .horizontal)
        .task { checkForNewLibraries() }
        .alert(newLibraryTitle, isPresented: Binding(get: { !newSections.isEmpty }, set: { if !$0 { newSections = [] } })) {
            Button("إضافة") { acknowledge(enable: true) }
            Button("لا", role: .cancel) { acknowledge(enable: false) }
        } message: {
            Text("«\(newSections.map { ArabicFormat.isolated($0.title) }.joined(separator: "»، «"))» — تبي تضيفها لمكتباتك؟")
        }
    }

    @ViewBuilder
    private func content(filter: ContentFilter, rest: [LibraryScope]) -> some View {
        switch selection {
        case .home, .profile:
            HomeView(client: client)
        case .myList:
            TVMyListView(client: client)
        case .search:
            SearchView(client: client)
        case .library(let id):
            if let scope = filter.scopes.first(where: { $0.id == id }) {
                LibraryView(client: client, scope: scope).id(id)
            } else {
                HomeView(client: client)
            }
        case .more:
            MoreLibrariesView(scopes: rest) { scope in selection = .library(scope.id) }
                .onExitCommand { sidebarFocus = selection }
        case .settings:
            SettingsView(client: client, sections: sections)
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

// MARK: - Sidebar

/// Floating rounded menu (blue-grey, semi-transparent) that fits its content; a slim icon rail
/// while it doesn't have focus.
private struct TVSidebar: View {
    @Binding var selection: TVDestination
    var focus: FocusState<TVDestination?>.Binding
    let profile: UserProfile
    let pinned: [LibraryScope]
    let hasMore: Bool
    let onProfile: () -> Void
    let onSelect: (TVDestination) -> Void

    private var expanded: Bool { focus.wrappedValue != nil }
    private var hasLibraries: Bool { !pinned.isEmpty || hasMore }

    private var selectedIsUnpinnedLibrary: Bool {
        guard case .library(let id) = selection else { return false }
        return !pinned.contains { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: onProfile) {
                HStack(spacing: 16) {
                    Text(String(profile.name.prefix(1)))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(Color(hex: profile.colorHex)))
                    if expanded {
                        Text(profile.name)
                            .font(.system(size: 26, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .bold))
                            .opacity(0.6)
                        Spacer(minLength: 0)
                    }
                }
            }
            .buttonStyle(SidebarButtonStyle(selected: false, expanded: expanded))
            .focused(focus, equals: .profile)
            .padding(.bottom, 10)

            row(.myList, "قائمتي", "bookmark")
            row(.search, "بحث", "magnifyingglass")
            row(.home, "الرئيسية", "house")

            // The header and its spacing only when there are library rows to show under it.
            if !hasLibraries {
                EmptyView()
            } else if expanded {
                HStack(spacing: 12) {
                    Text("المكتبات")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(height: 1)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 4)
            } else {
                Color.clear.frame(height: 18)
            }

            ForEach(pinned) { scope in
                row(.library(scope.id), scope.title, scope.icon)
            }
            if hasMore {
                row(.more, "المزيد", "ellipsis", selected: selection == .more || selectedIsUnpinnedLibrary)
            }

            if hasLibraries {
                Rectangle()
                    .fill(Color.white.opacity(expanded ? 0.18 : 0))
                    .frame(height: 1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            row(.settings, "الإعدادات", "gearshape")
        }
        .padding(12)
        .frame(width: expanded ? 400 : MainTabView.railWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            // Floating translucent panel (no solid colour behind it): a slim capsule of icons,
            // the same panel with names while it has focus.
            let shape = RoundedRectangle(cornerRadius: expanded ? 34 : MainTabView.railWidth / 2, style: .continuous)
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(Color.black.opacity(expanded ? 0.5 : 0.4)))
                .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        }
        // Centred vertically. The focus section spans the full height of the screen, so Right
        // from the first item of any row or grid (top or bottom) reaches the sidebar.
        .frame(maxHeight: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .focusSection()
        .defaultFocus(focus, selection)
        // Menu on the sidebar leaves the app (the system handles it: no handler here).
    }

    private func row(_ destination: TVDestination, _ title: String, _ icon: String, selected: Bool? = nil) -> some View {
        Button { onSelect(destination) } label: {
            HStack(spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 46)
                if expanded {
                    Text(title)
                        .font(.system(size: 25, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(SidebarButtonStyle(selected: selected ?? (selection == destination), expanded: expanded))
        .focused(focus, equals: destination)
    }
}

private struct SidebarButtonStyle: ButtonStyle {
    let selected: Bool
    let expanded: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, selected: selected, expanded: expanded)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let expanded: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            // Focused: white pill with black text and icon. Selected: light pill, dark text. Otherwise plain.
            let onPill = isFocused || selected
            let pill: Color = isFocused ? .white : (selected ? Color.white.opacity(0.78) : .clear)
            let text: Color = onPill ? .black : Color.white.opacity(0.7)
            configuration.label
                .foregroundStyle(text)
                // Light scheme on the pill so nothing adapts to a grey tone.
                .environment(\.colorScheme, onPill ? .light : .dark)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Capsule().fill(pill))
                .scaleEffect(configuration.isPressed ? 0.97 : (isFocused && expanded ? 1.03 : 1))
        }
    }
}

private struct ClockView: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(ArabicFormat.time(context.date))
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .monospacedDigit()
        }
    }
}

// MARK: - Home

/// The card that has focus on Home (drives the details panel and backdrop).
@MainActor
@Observable
final class HomeFocus {
    var item: PlexItem?
}

struct HomeView: View {
    let client: PlexServerClient

    @Environment(ProfileStore.self) private var store
    @Environment(\.contentFilter) private var filter
    @State private var focus = HomeFocus()
    @State private var continueWatching: [PlexItem] = []
    @State private var shelves: [Shelf] = []
    @State private var isLoading = true

    private var isEmpty: Bool { continueWatching.isEmpty && shelves.isEmpty }

    /// Height of the focused item's details above the rows (was 440: the second row ended
    /// up below the bottom of the screen).
    static let detailsHeight: CGFloat = 370

    var body: some View {
        BrowseContainer(client: client, showsBackdrop: false) {
            ZStack(alignment: .top) {
                HomeBackdrop(item: focus.item, client: client)

                if isLoading && isEmpty {
                    LoadingView()
                } else if isEmpty {
                    ContentUnavailableView("لا يوجد محتوى", systemImage: "film.stack",
                                           description: Text(filter.scopes.isEmpty
                                                             ? "لا توجد مكتبات مفتوحة لهذا المستخدم. افتحها من الإعدادات ← إعدادات المستخدم."
                                                             : "أضف أفلاماً ومسلسلات إلى خادم Plex لتظهر هنا."))
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        // Short enough that a good part of the second row shows under the first.
                        FocusedDetails(item: focus.item, client: client)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: Self.detailsHeight, alignment: .bottomLeading)
                            .padding(.horizontal, CardKind.inset)
                            .sidebarPadding()
                            .padding(.bottom, 8)

                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                if !continueWatching.isEmpty {
                                    ShelfView(shelf: Shelf(id: "continue", title: "متابعة المشاهدة",
                                                           kind: .landscape, items: continueWatching),
                                              client: client)
                                }
                                ForEach(shelves) { shelf in
                                    ShelfView(shelf: shelf, client: client)
                                }
                            }
                            .padding(.bottom, 80)
                        }
                    }
                }
            }
            .environment(focus)
        }
        .task(id: filter.signature) {
            // A library just enabled starts downloading in the background.
            LibrarySync.shared.start(client: client, force: true)
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .plexPlaybackDidEnd)) { _ in
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryShouldRefresh)) { _ in
            Task { await load(showCached: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .localLibraryDidChange)) { _ in
            Task { await load(showCached: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .profileDataDidChangeRemotely)) { _ in
            guard !PlaybackManager.shared.isPlaying else { return }
            Task { await load() }
        }
    }

    /// Saved Home first (no spinner), then rebuilt from the on-device library.
    private func load(showCached: Bool = true) async {
        defer { isLoading = false }
        await HomeFeed.loadCacheFirst(client: client, store: store, filter: filter,
                                      showCached: showCached && isEmpty) { apply($0) }
    }

    private func apply(_ feed: HomeFeed) {
        continueWatching = feed.continueWatching
        shelves = feed.rows
            .filter { $0.id.hasPrefix("recent-") }
            .map { Shelf(id: $0.id, title: $0.title, kind: .poster, items: $0.items) }
        if focus.item == nil { focus.item = continueWatching.first ?? shelves.first?.items.first }
    }
}

/// Backdrop of the focused item, changed only after focus rests briefly (no work while
/// scrolling fast): its artwork at the top melting into its Plex UltraBlur colours, on which
/// the rows sit (the darkened artwork when the item has no colours). Full screen, under the sidebar too.
private struct HomeBackdrop: View {
    let item: PlexItem?
    let client: PlexServerClient
    @State private var url: URL?
    @State private var colors: PlexUltraBlurColors?

    var body: some View {
        ZStack {
            ArtworkBackdrop(url: url, colors: colors, fadeStart: 0.3, fadeEnd: 0.68)
            BackdropScrim(hasColors: colors != nil)
        }
        .animation(.easeInOut(duration: 0.4), value: colors)
        .ignoresSafeArea()
        .task(id: item?.ratingKey) {
            guard let item else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            url = client.imageURL(item.backdropPath, width: 1280, height: 720)
            colors = await Self.colors(for: item, client: client)
        }
    }

    /// The artwork shown is the movie's / show's, so are the colours (episodes and seasons use
    /// their show's). Listings may not carry them: the item's full metadata (cached) is asked once.
    static func colors(for item: PlexItem, client: PlexServerClient) async -> PlexUltraBlurColors? {
        let ownerKey = item.isEpisode ? (item.grandparentRatingKey ?? item.ratingKey)
            : (item.isSeason ? (item.parentRatingKey ?? item.ratingKey) : item.ratingKey)
        if ownerKey == item.ratingKey, let own = item.ultraBlurColors { return own }
        return await UltraBlurCache.shared.colors(for: ownerKey, client: client) ?? item.ultraBlurColors
    }
}

/// UltraBlur colours per movie / show for the session (nil = it has none). The on-device
/// library may predate the field: the server's metadata is asked once per title.
@MainActor
final class UltraBlurCache {
    static let shared = UltraBlurCache()
    private var colors: [String: PlexUltraBlurColors?] = [:]

    func colors(for key: String, client: PlexServerClient) async -> PlexUltraBlurColors? {
        if let known = colors[key] { return known }
        var found = await client.cachedMetadata(key)?.ultraBlurColors
        if found == nil { found = (try? await client.metadata(key))?.ultraBlurColors }
        colors[key] = .some(found)
        return found
    }
}

/// Logo (or title), episode, date, runtime, rating, synopsis and cast of the focused item.
private struct FocusedDetails: View {
    let item: PlexItem?
    let client: PlexServerClient

    @State private var owner: PlexItem?
    @State private var logo: URL?

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 14) {
                title(item)
                    .frame(height: 120, alignment: .bottomLeading)

                if item.isEpisode {
                    Text(episodeLine(item))
                        .font(.system(size: 28, weight: .semibold))
                        .lineLimit(1)
                }

                Text(metaLine(item))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)

                if let summary = (item.summary?.isEmpty == false ? item.summary : owner?.summary) {
                    Text(summary)
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                        .frame(maxWidth: 1000, alignment: .leading)
                }

                let cast = (item.roles.isEmpty ? owner?.roles ?? [] : item.roles).prefix(4).map(\.tag)
                if !cast.isEmpty {
                    Text("بطولة: " + ArabicFormat.list(cast))
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
            }
            .task(id: item.ratingKey) { await resolve(item) }
        }
    }

    @ViewBuilder
    private func title(_ item: PlexItem) -> some View {
        if let logo {
            RemoteImage(url: logo, contentMode: .fit)
                .frame(maxWidth: 520, maxHeight: 120, alignment: .bottomLeading)
        } else {
            Text(item.cardTitle)
                .font(.system(size: 56, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private func episodeLine(_ item: PlexItem) -> String {
        ArabicFormat.episodeLine(season: item.parentIndex, episode: item.index, title: item.title)
    }

    private func metaLine(_ item: PlexItem) -> String {
        var parts: [String] = []
        if item.isEpisode, let date = ArabicFormat.date(plex: item.originallyAvailableAt) {
            parts.append(date)
        } else if let year = item.year {
            parts.append(ArabicFormat.digits(year))
        }
        if item.isShow, let leaves = item.leafCount {
            parts.append("\(ArabicFormat.digits(leaves)) حلقة")
        }
        if let duration = item.duration, item.isPlayable { parts.append(ArabicFormat.duration(ms: duration)) }
        if let rating = item.normalizedContentRating ?? owner?.normalizedContentRating { parts.append(rating) }
        if let score = item.audienceRating ?? item.rating, score > 0 { parts.append(ArabicFormat.score(score)) }
        let genres = ArabicFormat.genres((item.genres.isEmpty ? owner?.genres ?? [] : item.genres).map(\.tag), limit: 2)
        if !genres.isEmpty { parts.append(ArabicFormat.list(genres)) }
        return ArabicFormat.joined(parts)
    }

    /// The show (for episodes) and the clear logo, after focus rests briefly.
    private func resolve(_ item: PlexItem) async {
        let ownerKey = item.isEpisode ? (item.grandparentRatingKey ?? item.ratingKey)
            : (item.isSeason ? (item.parentRatingKey ?? item.ratingKey) : item.ratingKey)
        if owner?.ratingKey != ownerKey { owner = nil }
        if let cached = LogoCache.shared.path(for: ownerKey) {
            logo = cached.flatMap { client.imageURL($0, width: 1040, height: 240, png: true) }
        } else {
            logo = nil
        }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        if ownerKey != item.ratingKey { owner = await client.cachedMetadata(ownerKey) }
        guard LogoCache.shared.path(for: ownerKey) == nil else { return }
        // The synced listing may not carry logos: one request per title, remembered.
        var path = (owner ?? item).clearLogoPath
        if path == nil { path = (try? await client.metadata(ownerKey))?.clearLogoPath }
        LogoCache.shared.set(path, for: ownerKey)
        guard !Task.isCancelled else { return }
        logo = path.flatMap { client.imageURL($0, width: 1040, height: 240, png: true) }
    }
}

/// Clear-logo path per movie / show (nil = it has none), for the session.
@MainActor
private final class LogoCache {
    static let shared = LogoCache()
    private var paths: [String: String?] = [:]

    func path(for key: String) -> String?? { paths[key] }
    func set(_ path: String?, for key: String) { paths[key] = .some(path) }
}

// MARK: - My List

struct TVMyListView: View {
    let client: PlexServerClient

    @Environment(ProfileStore.self) private var store
    @Environment(\.contentFilter) private var filter
    @State private var items: [PlexItem] = []
    @State private var loaded = false

    var body: some View {
        BrowseContainer(client: client) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("قائمتي")
                            .font(.system(size: 44, weight: .bold))
                            .padding(.horizontal, CardKind.inset)
                        if items.isEmpty && loaded {
                            ContentUnavailableView("قائمتك فارغة", systemImage: "bookmark",
                                                   description: Text("أضف أفلاماً ومسلسلات من صفحة التفاصيل."))
                                .frame(maxWidth: .infinity)
                        }
                        PosterGrid(items: items, client: client, scrollProxy: proxy)
                    }
                    .padding(.vertical, 50)
                }
                .sidebarSafeArea()
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .myListDidChange)) { _ in
            Task { await load() }
        }
    }

    private func load() async {
        items = await UserFeed.myList(store: store, client: client, filter: filter)
        loaded = true
    }
}

// MARK: - More libraries

struct MoreLibrariesView: View {
    let scopes: [LibraryScope]
    let open: (LibraryScope) -> Void

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 30) {
                Text("المزيد من المكتبات")
                    .font(.system(size: 44, weight: .bold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 40)], alignment: .leading, spacing: 40) {
                    ForEach(scopes) { scope in
                        Button { open(scope) } label: {
                            HStack(spacing: 20) {
                                Image(systemName: scope.icon).font(.system(size: 36))
                                Text(scope.title).font(.system(size: 28, weight: .semibold)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 30)
                            .frame(width: 380, height: 130)
                            .background(Color.white.opacity(0.08))
                        }
                        .buttonStyle(.card)
                    }
                }
            }
            .padding(.horizontal, CardKind.inset)
            .padding(.vertical, 50)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sidebarSafeArea()
    }
}
