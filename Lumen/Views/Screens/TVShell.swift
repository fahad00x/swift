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
    /// The sidebar's ends (never pages): catch Up on the first row and Down on the last.
    case topEdge, bottomEdge
}

// `SidebarPrefs` (the pinned libraries) is in Lumen/Common/SidebarPrefs.swift, shared with the iPad.

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

/// Shell state shared with the screens: how many pages (details, listings) are pushed on top
/// of the current screen. While one is, the sidebar can't open (no edge catcher).
@MainActor
@Observable
final class ShellState {
    var pushedPages = 0
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
    @State private var shell = ShellState()
    @State private var news = ShowNews()
    @FocusState private var sidebarFocus: TVDestination?
    @FocusState private var edgeFocused: Bool
    @State private var edgeArmed = false
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
                // Armed once the first screen has loaded: at launch focus could land here
                // first and open the sidebar over the banner.
                .focusable(edgeArmed && !sidebarVisible && shell.pushedPages == 0)
                .focused($edgeFocused)
                .focusSection()

            if sidebarVisible {
                TVSidebar(selection: $selection, focus: $sidebarFocus, profile: profile,
                          pinned: pinned, hasMore: !rest.isEmpty, onBack: sidebarBack) {
                    store.deactivate()
                } onSelect: { destination in
                    selection = destination
                    // Hand focus to the chosen screen; the sidebar closes.
                    DispatchQueue.main.async { sidebarFocus = nil }
                    // A screen with nothing to focus (an empty «قائمتي») sends focus back to the
                    // sidebar's first row: keep it on the chosen one instead.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        if sidebarVisible, let focus = sidebarFocus, focus != destination { sidebarFocus = destination }
                    }
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
        .environment(shell)
        .environment(news)
        .task(id: profile.id) { news.refresh(client: client, store: store) }
        .onReceive(NotificationCenter.default.publisher(for: .myListDidChange)) { _ in news.refresh(client: client, store: store) }
        .onReceive(NotificationCenter.default.publisher(for: .plexPlaybackDidEnd)) { _ in news.refresh(client: client, store: store) }
        .onReceive(NotificationCenter.default.publisher(for: .localLibraryDidChange)) { _ in news.refresh(client: client, store: store) }
        .onReceive(NotificationCenter.default.publisher(for: .profileDataDidChangeRemotely)) { _ in news.refresh(client: client, store: store) }
        .ignoresSafeArea(.container, edges: .horizontal)
        .task {
            checkForNewLibraries()
            // At launch Home puts focus on its banner first; only then can the edge catcher
            // (which opens the sidebar) take focus.
            try? await Task.sleep(for: .seconds(2))
            edgeArmed = true
        }
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

    /// Back on the sidebar: first to «الرئيسية»; from there (nil: no handler) the system
    /// leaves the app.
    private var sidebarBack: (() -> Void)? {
        if sidebarFocus == .home && selection == .home { return nil }
        return {
            selection = .home
            sidebarFocus = .home
        }
    }

    /// Back / Menu on a top-level screen, or Right at the edge: shows the sidebar on the
    /// current page's row.
    private func openSidebar() {
        // Only from a top-level screen (never from a details page).
        guard shell.pushedPages == 0 else { return }
        guard !sidebarVisible else { sidebarFocus = selection; return }
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22)) { sidebarVisible = true }
        DispatchQueue.main.async { sidebarFocus = selection }
    }

    @ViewBuilder
    private func content(filter: ContentFilter, rest: [LibraryScope]) -> some View {
        switch selection {
        case .home, .profile, .topEdge, .bottomEdge:
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
            MoreLibrariesView(client: client, scopes: rest) { scope in selection = .library(scope.id) }
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
    @Environment(ProfileStore.self) private var store
    @Environment(ShowNews.self) private var news: ShowNews?

    @Binding var selection: TVDestination
    var focus: FocusState<TVDestination?>.Binding
    let profile: UserProfile
    let pinned: [LibraryScope]
    let hasMore: Bool
    /// Back / Menu; nil lets the system handle it (leaves the app).
    let onBack: (() -> Void)?
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
            edge(.topEdge)
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
            edge(.bottomEdge)
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
            // Past an end: stays on its row (the focus would leave and close the sidebar).
            if old != nil, new == .topEdge { DispatchQueue.main.async { focus.wrappedValue = .profile }; return }
            if old != nil, new == .bottomEdge { DispatchQueue.main.async { focus.wrappedValue = .settings }; return }
            // Entering from the content lands on the current page.
            guard old == nil, let new, new != selection else { return }
            DispatchQueue.main.async { focus.wrappedValue = selection }
        }
        // Menu on the sidebar: to «الرئيسية» first, then (no handler) the system leaves the app.
        .onExitCommand(perform: onBack)
    }

    private func edge(_ side: TVDestination) -> some View {
        Color.white.opacity(0.001)
            .frame(maxWidth: .infinity)
            .frame(height: 2)
            // Only while the sidebar has the focus: never a way in.
            .focusable(focus.wrappedValue != nil)
            .focused(focus, equals: side)
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
                // «قائمتي»: how many of its shows have new episodes.
                if destination == .myList, let count = news?.count(in: store), count > 0 {
                    Text(ArabicFormat.digits(count))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(minWidth: 34, minHeight: 34)
                        .background(Circle().fill(ArtworkStatusOverlay.orange))
                }
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
    @Environment(ShowNews.self) private var news: ShowNews?
    @State private var banner: [BannerItem] = []
    @State private var rows: [Shelf] = []
    @State private var isLoading = true
    @FocusState private var bannerFocus: HeroBanner.Control?
    /// Focus went to the banner's Play once, when Home first had content.
    @State private var focusedBanner = false

    private var isEmpty: Bool { banner.isEmpty && rows.isEmpty }
    @State private var myList: [PlexItem] = []

    /// The profile's rows: without what it removed from Continue Watching, and «قائمتي» right
    /// after it when the profile wants it on Home.
    private var homeRows: [Shelf] {
        var out = rows.shown(to: store, news: news, filter: filter)
        if store.activeProfile?.settings?.myListOnHome == true, !myList.isEmpty {
            out.insert(Shelf(id: "mylist", title: "قائمتي", kind: .poster, items: myList),
                       at: out.first?.id == "continue" ? 1 : 0)
        }
        // Fixed / dynamic / removed rows, as the profile arranged them.
        return HomeLayout.arrange(out, id: \.id, layout: store.activeProfile?.settings?.homeRows)
    }

    private func loadMyList() async {
        guard store.activeProfile?.settings?.myListOnHome == true else { myList = []; return }
        myList = await UserFeed.myList(store: store, client: client, filter: filter)
    }

    var body: some View {
        BrowseContainer(client: client, showsBackdrop: false) {
            if isLoading && isEmpty {
                // The first library download shows only here, while Home has nothing yet.
                VStack(spacing: 40) {
                    LoadingView()
                    LibrarySyncBanner()
                }
            } else if isEmpty {
                ContentUnavailableView("لا يوجد محتوى", systemImage: "film.stack",
                                       description: Text(filter.scopes.isEmpty
                                                         ? "لا توجد مكتبات مفتوحة لهذا المستخدم. افتحها من الإعدادات ← إعدادات المستخدم."
                                                         : "أضف أفلاماً ومسلسلات إلى خادم Plex لتظهر هنا."))
            } else {
                BannerPage(banner: banner, chipTitle: "الرئيسية", client: client, bannerFocus: $bannerFocus,
                           firstRowID: homeRows.first?.id) {
                    ForEach(homeRows) { shelf in
                        PageRow(id: shelf.id) {
                            ShelfView(shelf: shelf, client: client)
                                .environment(\.marksNewEpisodes, shelf.id == "mylist" || shelf.id == "continue")
                        }
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
        .task(id: "\(filter.signature)|\(store.activeProfile?.settings?.myListOnHome == true)") { await loadMyList() }
        .onReceive(NotificationCenter.default.publisher(for: .myListDidChange)) { _ in Task { await loadMyList() } }
        // Opening the app lands on the banner's Play (like Apple's TV app), not on nothing.
        .onChange(of: banner.isEmpty, initial: true) { _, empty in
            guard !empty, !focusedBanner else { return }
            focusedBanner = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { bannerFocus = .play }
        }
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

/// A banner page (Home, a library): the banner, then `content` (rows, a tab bar…), all in
/// ONE vertical scroll, so the banner leaves the screen like the rest of the page.
///
/// Scroll positions (1080p, Apple TV app): banner focused → top of the page; the first row
/// focused → its header at y≈230 (the bottom ~200 pt of the banner, dimmed, above it); any
/// later row → its header at y≈300 with the bottom of the previous row's posters above it.
/// Below the banner the page is a flat #1F2020.
struct BannerPage<Content: View>: View {
    let banner: [BannerItem]
    let chipTitle: String
    let client: PlexServerClient
    var bannerFocus: FocusState<HeroBanner.Control?>.Binding
    /// Scroll marker id of the first row (or tab bar) under the banner.
    var firstRowID: String?
    @ViewBuilder let content: () -> Content

    @State private var index = 0
    @State private var atRows = false
    @State private var chipVisible = false
    @State private var infoRoute: DetailRoute?

    static var pageColor: Color { Color(red: 0x1F / 255, green: 0x20 / 255, blue: 0x20 / 255) }
    private static var firstRowY: CGFloat { 230 }
    private static var laterRowY: CGFloat { 300 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if banner.isEmpty {
                        Color.clear.frame(height: 90)
                    } else {
                        HeroBanner(items: banner, client: client, chipTitle: chipTitle, focus: bannerFocus,
                                   index: $index, chipVisible: chipVisible) { item in
                            infoRoute = DetailRoute(item: item.display, sourceID: "banner|\(item.id)",
                                                    context: BrowseContext(rowID: "banner-\(chipTitle)", items: banner.map(\.display)))
                        }
                        // Scrolled into the rows: what's left of the banner (artwork included,
                        // down to the bottom edge) is dimmed.
                        .overlay(alignment: .top) {
                            // Fades out toward the artwork's bottom edge, which is already the
                            // page colour (a flat dim there left a dark seam above the rows).
                            LinearGradient(stops: [
                                .init(color: .black.opacity(0.5), location: 0),
                                .init(color: .black.opacity(0.5), location: 0.7),
                                .init(color: .clear, location: 1),
                            ], startPoint: .top, endPoint: .bottom)
                                .opacity(atRows ? 1 : 0)
                                .frame(height: HeroBanner.artHeight)
                                .allowsHitTesting(false)
                        }
                        .id("banner")
                    }

                    LazyVStack(alignment: .leading, spacing: 0) {
                        content()
                    }
                    // The last row stays fully visible with its focus lift.
                    .padding(.bottom, 120)
                }
            }
            .background(Self.pageColor)
            .scrollClipDisabled()
            .ignoresSafeArea()
            .environment(\.pageContentFocused, {
                // Banner → content: the first row at its reading position.
                guard !atRows else { return }
                chipVisible = false
                withAnimation(.easeOut(duration: 0.3)) { atRows = true }
                if let firstRowID { scroll(proxy, to: firstRowID, y: Self.firstRowY) }
            })
            .environment(\.pageRowFocused, { id in
                if !atRows {
                    chipVisible = false
                    withAnimation(.easeOut(duration: 0.3)) { atRows = true }
                }
                scroll(proxy, to: id, y: id == firstRowID ? Self.firstRowY : Self.laterRowY)
            })
            .onChange(of: bannerFocus.wrappedValue) { old, new in
                if new != nil {
                    if atRows {
                        // Rows → banner: the whole page back to the top, focus on the primary button.
                        withAnimation(.easeOut(duration: 0.3)) { atRows = false }
                        DispatchQueue.main.async { withAnimation(.appleScroll) { proxy.scrollTo("banner", anchor: .top) } }
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
        }
        .frame(width: 1920, height: 1080)
        .navigationDestination(item: $infoRoute) { route in
            DetailPage(client: client, entry: route.item, context: route.context, sourceID: route.sourceID)
        }
    }

    /// Puts the row's top marker (a 1 pt view at the top of the row) at `y` on the screen.
    /// The marker has its own id: the row itself shares the row id with `ForEach`, and
    /// scrolling to the whole row would anchor its middle instead of its header.
    private func scroll(_ proxy: ScrollViewProxy, to id: String, y: CGFloat) {
        let target = id == BannerPageID.firstRow ? id : PageRow<EmptyView>.markerID(id)
        DispatchQueue.main.async {
            withAnimation(.appleScroll) { proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: y / 1080)) }
        }
    }
}

/// A row in a banner page with its 1 pt scroll marker on top (the marker carries the id).
struct PageRow<Row: View>: View {
    let id: String
    @ViewBuilder let row: () -> Row

    static func markerID(_ id: String) -> String { id + "#top" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 1).id(Self.markerID(id))
            row()
        }
    }
}

// MARK: - My List

struct TVMyListView: View {
    let client: PlexServerClient

    @Environment(ProfileStore.self) private var store
    @Environment(ShowNews.self) private var news: ShowNews?
    @Environment(\.contentFilter) private var filter
    @State private var items: [PlexItem] = []
    @State private var loaded = false

    var body: some View {
        // What's new, then what the profile is watching, then the rest.
        let new = items.filter { news?.of($0)?.badge != nil }
            .sorted { (news?.of($0)?.newest ?? 0) > (news?.of($1)?.newest ?? 0) }
        let others = items.filter { news?.of($0)?.badge == nil }
        let watching = others.filter { store.isInContinue($0.ratingKey) && store.isUnwatched($0) }
        let keys = Set(watching.map(\.ratingKey))
        let rest = watching + others.filter { !keys.contains($0.ratingKey) }
        BrowseContainer(client: client) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Text("قائمتي").font(.system(size: 44, weight: .bold))
                            Spacer()
                            SettingsSwitch("إظهارها في الرئيسية", isOn: Self.onHome(store))
                                .frame(width: 440)
                        }
                        .padding(.horizontal, CardKind.inset)
                        .focusSection()
                        if items.isEmpty && loaded {
                            ContentUnavailableView("قائمتك فارغة", systemImage: "bookmark",
                                                   description: Text("أضف أفلاماً ومسلسلات من صفحة التفاصيل."))
                                .frame(maxWidth: .infinity)
                        }
                        if !new.isEmpty {
                            header("نزل جديدها")
                            PosterGrid(items: new, client: client, scrollProxy: proxy, rowID: "mylist-new")
                            if !rest.isEmpty { header("باقي القائمة") }
                        }
                        if !rest.isEmpty {
                            PosterGrid(items: rest, client: client, scrollProxy: proxy)
                        }
                    }
                    .padding(.vertical, 50)
                }
                .sidebarSafeArea()
            }
        }
        .environment(\.marksNewEpisodes, true)
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .myListDidChange)) { _ in
            Task { await load() }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 30))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, CardKind.inset)
            .padding(.top, 10)
    }

    /// The profile's «قائمتي on Home» setting.
    static func onHome(_ store: ProfileStore) -> Binding<Bool> {
        Binding { store.activeProfile?.settings?.myListOnHome ?? false }
            set: { on in store.updateSettings { $0.myListOnHome = on } }
    }

    private func load() async {
        items = await UserFeed.myList(store: store, client: client, filter: filter)
        loaded = true
    }
}

// MARK: - More libraries

struct MoreLibrariesView: View {
    let client: PlexServerClient
    let scopes: [LibraryScope]
    let open: (LibraryScope) -> Void

    private static let tile = CGSize(width: 520, height: 292)

    /// Library key → backdrop of its newest title (libraries rarely have artwork of their own).
    @State private var art: [String: String] = [:]

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 30) {
                Text("المزيد من المكتبات")
                    .font(.system(size: 44, weight: .bold))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.tile.width), spacing: 60), count: 3),
                          alignment: .leading, spacing: 60) {
                    ForEach(scopes) { scope in
                        Button { open(scope) } label: { tile(scope) }
                            .buttonStyle(.card)
                    }
                }
            }
            .padding(.horizontal, CardKind.inset)
            .padding(.vertical, 50)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sidebarSafeArea()
        .task {
            await withTaskGroup(of: (String, String?).self) { group in
                for scope in scopes where scope.section.art == nil {
                    group.addTask {
                        let newest = try? await client.recentlyAdded(section: scope.section, limit: 1)
                        return (scope.section.key, newest?.first?.backdropPath)
                    }
                }
                for await (key, path) in group { if let path { art[key] = path } }
            }
        }
    }

    /// 16:9 tile: the library's artwork darkened, its icon and full name (never cut).
    private func tile(_ scope: LibraryScope) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color(white: 0.16)
            RemoteImage(url: client.imageURL(scope.section.art ?? art[scope.section.key], width: 1040, height: 584))
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
            HStack(spacing: 16) {
                Image(systemName: scope.icon).font(.system(size: 34, weight: .semibold))
                Text(scope.title)
                    .font(.system(size: 32, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(.white)
            .padding(28)
        }
        .frame(width: Self.tile.width, height: Self.tile.height)
    }
}
