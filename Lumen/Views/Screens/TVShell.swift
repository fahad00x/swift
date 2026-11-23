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

    /// Content uses the full width; the sidebar floats over it only while open.
    static let railInset: CGFloat = 0

    @Environment(ProfileStore.self) private var store
    @State private var newSections: [PlexDirectory] = []
    @State private var selection: TVDestination = .home
    @State private var prefs: SidebarPrefs
    /// The sidebar is on screen (hidden completely while closed).
    @State private var sidebarVisible = false
    @FocusState private var sidebarFocus: TVDestination?
    @FocusState private var edgeFocused: Bool
    @Namespace private var shellNamespace
    @Environment(\.resetFocus) private var resetFocus

    init(client: PlexServerClient, sections: [PlexDirectory], profile: UserProfile) {
        self.client = client
        self.sections = sections
        self.profile = profile
        _prefs = State(initialValue: SidebarPrefs(profileID: profile.id))
    }

    var body: some View {
        let filter = ContentFilter(profile: profile, sections: sections)
        let pinned = prefs.pinned(from: filter.scopes)
        let rest = filter.scopes.filter { scope in !pinned.contains { $0.id == scope.id } }

        // Arabic layout: the sidebar floats on the leading side, which is the right. No rail,
        // no dimming: the content never moves.
        ZStack(alignment: .leading) {
            Color.black.ignoresSafeArea()

            content(filter: filter, rest: rest)
                .environment(\.focusSidebar, { openSidebar() })
                .environment(\.sidebarInset, Self.railInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .prefersDefaultFocus(true, in: shellNamespace)

            // Pressing toward the right edge from the first item of a row opens the sidebar.
            Color.clear
                .frame(width: 12)
                .frame(maxHeight: .infinity)
                .focusable(!sidebarVisible)
                .focused($edgeFocused)
                .focusSection()

            if sidebarVisible {
                TVSidebar(selection: $selection, focus: $sidebarFocus, profile: profile,
                          pinned: pinned, hasMore: !rest.isEmpty) {
                    store.deactivate()
                } onSelect: { destination in
                    selection = destination
                    // Hand focus to the chosen screen; the sidebar closes.
                    DispatchQueue.main.async { sidebarFocus = nil }
                } onClose: {
                    closeSidebar()
                }
                .padding(.leading, TVSidebar.margin)
                .padding(.vertical, TVSidebar.margin)
                .transition(.asymmetric(
                    // Grows out of the edge with its items fading in (~0.22 s); closes at once.
                    insertion: .scale(scale: 0.86, anchor: .trailing).combined(with: .opacity),
                    removal: .opacity))
            }
        }
        .focusScope(shellNamespace)
        .overlay(alignment: .topTrailing) {
            // First library download only (the clock lives in the sidebar).
            LibrarySyncBanner()
                .padding(.top, 30)
                .padding(.trailing, 60)
                .allowsHitTesting(false)
        }
        .onChange(of: edgeFocused) { _, focused in
            if focused { openSidebar() }
        }
        .onChange(of: sidebarFocus) { _, focus in
            // Focus left the sidebar: it closes.
            if focus == nil, sidebarVisible {
                withAnimation(.linear(duration: 0.05)) { sidebarVisible = false }
            }
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

    /// Left (toward the content) or a left swipe: the panel closes at once and focus goes back
    /// to the content (the item it had, else the screen's default: the banner's Play).
    private func closeSidebar() {
        withAnimation(.linear(duration: 0.05)) { sidebarVisible = false }
        sidebarFocus = nil
        DispatchQueue.main.async { resetFocus(in: shellNamespace) }
    }

    /// Back / Menu on a top-level screen, or Right at the edge: shows the sidebar on the
    /// current page's row.
    private func openSidebar() {
        guard !sidebarVisible else { sidebarFocus = selection; return }
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22)) { sidebarVisible = true }
        DispatchQueue.main.async { sidebarFocus = selection }
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
                .onExitCommand { openSidebar() }
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

/// Apple TV app–style sidebar (mirrored to the right): a floating translucent glass card,
/// shown only while it has focus. Header with the profile and the clock, filled-symbol rows,
/// one white pill on the focused row, Settings at the bottom.
private struct TVSidebar: View {
    @Binding var selection: TVDestination
    var focus: FocusState<TVDestination?>.Binding
    let profile: UserProfile
    let pinned: [LibraryScope]
    let hasMore: Bool
    let onProfile: () -> Void
    let onSelect: (TVDestination) -> Void
    let onClose: () -> Void

    static let width: CGFloat = 340
    static let margin: CGFloat = 36
    static let cornerRadius: CGFloat = 40
    /// Row pitch 78: a 72 pt row (the focused pill) + 6 pt gap.
    static let rowHeight: CGFloat = 72

    private var selectedIsUnpinnedLibrary: Bool {
        guard case .library(let id) = selection else { return false }
        return !pinned.contains { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
                .padding(.bottom, 14)

            row(.search, "بحث", "magnifyingglass")
            row(.home, "الرئيسية", "house.fill")
            row(.myList, "قائمتي", "bookmark.fill")
            ForEach(pinned) { scope in
                row(.library(scope.id), scope.title, Self.filledIcon(scope.icon))
            }
            if hasMore {
                row(.more, "المزيد", "ellipsis.circle.fill", selected: selection == .more || selectedIsUnpinnedLibrary)
            }

            Spacer(minLength: 12)
            row(.settings, "الإعدادات", "gearshape.fill")
        }
        .padding(9)
        .padding(.top, 14)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            // Liquid Glass look: translucent with a strong blur and a subtle light rim.
            let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            shape.fill(.ultraThinMaterial)
            shape.fill(Color.white.opacity(0.04))
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.06), .white.opacity(0.18)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1.2)
        }
        .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
        .focusSection()
        .defaultFocus(focus, selection)
        // Left (physical; the sidebar is on the right) closes it, also from a swipe.
        .onMoveCommand { direction in
            if direction == .left { onClose() }
        }
        .onChange(of: focus.wrappedValue) { old, new in
            // Entering from the content lands on the current page.
            guard old == nil, let new, new != selection else { return }
            DispatchQueue.main.async { focus.wrappedValue = selection }
        }
        // Menu on the sidebar leaves the app (the system handles it: no handler here).
    }

    /// Avatar with the initial, the profile name, and the clock on the far side.
    private var header: some View {
        Button(action: onProfile) {
            HStack(spacing: 14) {
                Text(String(profile.name.prefix(1)))
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(Color(hex: profile.colorHex)))
                Text(profile.name)
                    .font(.system(size: 26, weight: .regular))
                    .lineLimit(1)
                Spacer(minLength: 8)
                ClockView()
            }
        }
        .buttonStyle(SidebarButtonStyle(selected: false, dimText: true))
        .focused(focus, equals: .profile)
    }

    private func row(_ destination: TVDestination, _ title: String, _ icon: String, selected: Bool? = nil) -> some View {
        Button { onSelect(destination) } label: {
            HStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .regular))
                    .frame(width: 40)
                // Long library names wrap (or shrink a little); never truncated.
                Text(title)
                    .font(.system(size: 27, weight: .regular))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(SidebarButtonStyle(selected: selected ?? (selection == destination), dimText: false))
        .focused(focus, equals: destination)
    }

    /// Filled SF Symbol for a library icon.
    static func filledIcon(_ name: String) -> String {
        switch name {
        case "tv": return "tv.fill"
        case "film": return "film.fill"
        default: return name
        }
    }
}

/// Only the focused row gets the (single) white pill, with dark text; the rest is white at
/// ~85%, the current page full white.
private struct SidebarButtonStyle: ButtonStyle {
    let selected: Bool
    /// Header: light grey name.
    let dimText: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, selected: selected, dimText: dimText)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let dimText: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let text: Color = isFocused ? .black : (dimText ? Color.white.opacity(0.7) : (selected ? .white : Color.white.opacity(0.85)))
            configuration.label
                .foregroundStyle(text)
                .environment(\.colorScheme, isFocused ? .light : .dark)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: TVSidebar.rowHeight, alignment: .leading)
                .background(Capsule().fill(isFocused ? Color.white : Color.clear))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: isFocused)
        }
    }
}

private struct ClockView: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(ArabicFormat.time(context.date))
                .font(.system(size: 22, weight: .regular))
                .opacity(0.75)
                .monospacedDigit()
        }
    }
}

// MARK: - Home

/// Kept for cards that report focus; Home no longer follows the focused poster.
@MainActor
@Observable
final class HomeFocus {
    var item: PlexItem?
}

/// Apple TV app–style Home: the banner (per profile, every enabled library), then every row
/// (Plex's hubs merged with the profile's own rows). Up from the first row scrolls the whole
/// page back to the banner's primary button.
struct HomeView: View {
    let client: PlexServerClient

    @Environment(ProfileStore.self) private var store
    @Environment(\.contentFilter) private var filter
    @State private var banner: [BannerItem] = []
    @State private var rows: [Shelf] = []
    @State private var isLoading = true
    @FocusState private var bannerFocus: HeroBanner.Control?

    private var isEmpty: Bool { banner.isEmpty && rows.isEmpty }

    var body: some View {
        BrowseContainer(client: client, showsBackdrop: false) {
            if isLoading && isEmpty {
                LoadingView()
            } else if isEmpty {
                ContentUnavailableView("لا يوجد محتوى", systemImage: "film.stack",
                                       description: Text(filter.scopes.isEmpty
                                                         ? "لا توجد مكتبات مفتوحة لهذا المستخدم. افتحها من الإعدادات ← إعدادات المستخدم."
                                                         : "أضف أفلاماً ومسلسلات إلى خادم Plex لتظهر هنا."))
            } else {
                BannerPage(banner: banner, chipTitle: "الرئيسية", client: client, bannerFocus: $bannerFocus) {
                    ForEach(rows) { shelf in
                        ShelfView(shelf: shelf, client: client).id(shelf.id)
                    }
                }
            }
        }
        .task(id: filter.signature) {
            // A library just enabled starts downloading in the background.
            LibrarySync.shared.start(client: client, force: true)
            await load()
        }
        .onAppear { if !isEmpty { Task { await load(cached: false) } } }
        .onReceive(NotificationCenter.default.publisher(for: .plexPlaybackDidEnd)) { _ in
            Task { await load(cached: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryShouldRefresh)) { _ in
            Task { await load(cached: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .profileDataDidChangeRemotely)) { _ in
            guard !PlaybackManager.shared.isPlaying else { return }
            Task { await load(cached: false) }
        }
    }

    /// Saved server responses first (instant), then the server.
    private func load(cached: Bool = true) async {
        defer { isLoading = false }
        if cached && isEmpty {
            await PlexResponseCache.$policy.withValue(.cacheOnly) { await fetch() }
        }
        await fetch()
    }

    private func fetch() async {
        async let bannerTask = TVFeed.banner(client: client, store: store, filter: filter, sections: filter.sections)
        async let rowsTask = TVFeed.rows(client: client, store: store, filter: filter, section: nil)
        let (newBanner, newRows) = await (bannerTask, rowsTask)
        // A failed refresh (offline) keeps what's on screen. Artwork first: no text on black.
        if !newBanner.isEmpty, newBanner.map(\.id) != banner.map(\.id) {
            await HeroBanner.preload(newBanner, client: client)
            banner = newBanner
        }
        if !newRows.isEmpty { rows = newRows }
    }
}

enum BannerPageID {
    /// The first row (or tab bar) under the banner.
    static let firstRow = "banner-page-first-row"
}

/// Lets cards, tabs and tiles under a banner tell the page that focus moved into its rows.
private struct PageFocusKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var pageContentFocused: (() -> Void)? {
        get { self[PageFocusKey.self] }
        set { self[PageFocusKey.self] = newValue }
    }
}

/// A row under a banner got focus (its id): the page scrolls it to its reading position.
private struct RowFocusKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var pageRowFocused: ((String) -> Void)? {
        get { self[RowFocusKey.self] }
        set { self[RowFocusKey.self] = newValue }
    }
}

/// A banner page (Home, a library): the banner, then `content` (rows, a tab bar…).
///
/// The page moves as one piece: with focus on the banner it shows full screen (the first row
/// peeking at the bottom); with focus in the rows the whole page (banner included, no
/// parallax) moves up ~660 pt with the Apple curve, and Up from the first row brings it back.
/// The banner artwork bleeds under the rows and fades into a dark tint of itself, never
/// into black.
struct BannerPage<Content: View>: View {
    let banner: [BannerItem]
    let chipTitle: String
    let client: PlexServerClient
    var bannerFocus: FocusState<HeroBanner.Control?>.Binding
    @ViewBuilder let content: () -> Content

    @State private var index = 0
    @State private var atRows = false
    @State private var chipVisible = false
    @State private var infoRoute: DetailRoute?

    /// How far the page moves up for the rows: the rows area then starts ~200 pt from the top.
    private static var shift: CGFloat { HeroBanner.height - 200 }
    /// Room above the first row inside the rows area (focus lift).
    private static var rowTopInset: CGFloat { 30 }
    private var rowsHeight: CGFloat {
        banner.isEmpty ? 990 : 1080 - (HeroBanner.height - Self.shift) + Self.rowTopInset
    }

    var body: some View {
        ZStack(alignment: .top) {
            PageTint(url: banner.isEmpty ? nil : HeroBanner.lowResURL(banner[min(index, banner.count - 1)], client: client))

            VStack(alignment: .leading, spacing: 0) {
                if banner.isEmpty {
                    Color.clear.frame(height: 90)
                } else {
                    HeroBanner(items: banner, client: client, chipTitle: chipTitle, focus: bannerFocus,
                               index: $index, chipVisible: chipVisible) { item in
                        infoRoute = DetailRoute(item: item.display, sourceID: "banner|\(item.id)",
                                                context: BrowseContext(rowID: "banner-\(chipTitle)", items: banner.map(\.display)))
                    }
                    // Scrolled into the rows: the banner stays visible above them, dimmed.
                    .overlay(Color.black.opacity(atRows ? 0.5 : 0).allowsHitTesting(false))
                }

                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            content()
                        }
                        .padding(.top, Self.rowTopInset)
                        // The last row stays fully visible with its focus lift.
                        .padding(.bottom, 120)
                    }
                    .frame(height: rowsHeight)
                    .padding(.top, -Self.rowTopInset)
                    .environment(\.pageRowFocused, { id in
                        // The focused row's header ~200 pt from the top of the screen, the
                        // next row's header and the top of its posters visible below it.
                        DispatchQueue.main.async {
                            withAnimation(.appleScroll) {
                                proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: Self.rowTopInset / rowsHeight))
                            }
                        }
                    })
                }
            }
            .offset(y: atRows && !banner.isEmpty ? -Self.shift : 0)
            .environment(\.pageContentFocused, {
                guard !atRows else { return }
                chipVisible = false
                withAnimation(.appleScroll) { atRows = true }
            })
        }
        .frame(width: 1920, height: 1080, alignment: .top)
        .ignoresSafeArea()
        .onChange(of: bannerFocus.wrappedValue) { old, new in
            if new != nil {
                if atRows {
                    // Rows → banner: the whole page back down, focus on the primary button.
                    withAnimation(.appleScroll) { atRows = false }
                    if old == nil, new != .play { DispatchQueue.main.async { bannerFocus.wrappedValue = .play } }
                }
                // The chip fades in once the scroll has settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + (old == nil ? 0.85 : 0)) {
                    guard bannerFocus.wrappedValue != nil, !atRows else { return }
                    withAnimation(.easeOut(duration: 0.3)) { chipVisible = true }
                }
            } else {
                withAnimation(.easeOut(duration: 0.15)) { chipVisible = false }
            }
        }
        .navigationDestination(item: $infoRoute) { route in
            DetailPage(client: client, entry: route.item, context: route.context, sourceID: route.sourceID)
        }
    }
}

/// The page background under a banner: a dark, blurred tint of the current artwork.
private struct PageTint: View {
    let url: URL?

    var body: some View {
        ZStack {
            Color(white: 0.06)
            if let url {
                RemoteImage(url: url)
                    .blur(radius: 80, opaque: true)
                    .scaleEffect(1.2)
                    .id(url)
                    .transition(.opacity)
            }
            Color.black.opacity(0.6)
        }
        .frame(width: 1920, height: 1080)
        .clipped()
        .animation(.easeInOut(duration: 0.5), value: url)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
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
