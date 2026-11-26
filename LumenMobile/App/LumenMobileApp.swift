import SwiftUI

enum Theme {
    static let accent = Color(red: 1.0, green: 0.68, blue: 0.16)
}

@main
struct LumenMobileApp: App {
    @UIApplicationDelegateAdaptor(LumenAppDelegate.self) private var appDelegate
    @State private var session = AppSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(session.profiles)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .alert("تمت إضافة مستخدم مشترك",
                       isPresented: Binding(get: { session.profiles.acceptedShareTitle != nil },
                                            set: { if !$0 { session.profiles.acceptedShareTitle = nil } })) {
                    Button("حسناً", role: .cancel) {}
                } message: {
                    Text("«\(session.profiles.acceptedShareTitle ?? "")» صار متاحاً في «مين يشاهد؟» ويتزامن مع الجهاز الآخر.")
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive: session.profiles.flush()
            case .active:
                session.profiles.scheduleSync(after: 0)
                if let client = session.client { LibrarySync.shared.start(client: client) }
            @unknown default: break
            }
        }
    }
}

struct RootView: View {
    @Environment(AppSession.self) private var session
    @Environment(ProfileStore.self) private var profiles

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch session.phase {
            case .launching:
                LoadingView()
            case .signedOut:
                LinkAccountView()
            case .selectingServer:
                ServerPickerView()
            case .connecting(let message):
                LoadingView(message: message)
            case .failed(let message):
                ErrorView(message: message)
            case .ready:
                if let client = session.client {
                    if let profile = profiles.activeProfile {
                        // Not rebuilt when the profile's libraries change (that would close Settings);
                        // screens reload from the new content filter instead.
                        MainTabView(client: client, sections: session.sections, profile: profile)
                            .id("\(client.machineIdentifier)|\(profile.id)")
                            .transition(.opacity)
                    } else {
                        ProfilePickerView(client: client, sections: session.sections)
                            .transition(.opacity)
                    }
                }
            }
        }
        // «مين يشاهد؟» ↔ Home cross-fade (~0.4 s).
        .animation(.easeInOut(duration: 0.4), value: profiles.activeProfile?.id)
        .task { await session.bootstrap() }
    }
}

struct ErrorView: View {
    let message: String
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.yellow)
            Text(message)
                .multilineTextAlignment(.center)
            VStack(spacing: 12) {
                Button("إعادة المحاولة") { Task { await session.retry() } }
                    .buttonStyle(.borderedProminent)
                if session.servers.count > 1 {
                    Button("اختيار خادم آخر") { session.chooseAnotherServer() }
                }
                Button("تسجيل الخروج", role: .destructive) { session.signOut() }
            }
        }
        .padding(32)
    }
}

struct MainTabView: View {
    let client: PlexServerClient
    let sections: [PlexDirectory]
    let profile: UserProfile

    @Environment(ProfileStore.self) private var store
    @State private var newSections: [PlexDirectory] = []
    /// «حلقة جديدة» / «موسم جديد» of the shows the profile follows.
    @State private var news = ShowNews()
    /// The libraries pinned to the sidebar (same choice as the Apple TV, synced with the profile).
    @State private var sidebar: SidebarPrefs
    @State private var selection: TabID = .home

    init(client: PlexServerClient, sections: [PlexDirectory], profile: UserProfile) {
        self.client = client
        self.sections = sections
        self.profile = profile
        _sidebar = State(initialValue: SidebarPrefs(profileID: profile.id))
    }

    enum TabID: Hashable { case home, myList, search, downloads, settings, library(String), more }

    var body: some View {
        let filter = ContentFilter(profile: profile, sections: sections)
        tabs(filter)
        .environment(\.contentFilter, filter)
        .environment(news)
        .environment(sidebar)
        .task {
            AppSessionClient.current = client
            checkForNewLibraries()
            news.refresh(client: client, store: store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .plexPlaybackDidEnd)) { _ in news.refresh(client: client, store: store) }
        .onReceive(NotificationCenter.default.publisher(for: .myListDidChange)) { _ in news.refresh(client: client, store: store) }
        .onReceive(NotificationCenter.default.publisher(for: .localLibraryDidChange)) { _ in news.refresh(client: client, store: store) }
        .onReceive(NotificationCenter.default.publisher(for: .profileDataDidChangeRemotely)) { _ in news.refresh(client: client, store: store) }
        .alert(newSections.count > 1 ? "فيه مكتبات جديدة" : "فيه مكتبة جديدة",
               isPresented: Binding(get: { !newSections.isEmpty }, set: { if !$0 { newSections = [] } })) {
            Button("إضافة") { acknowledge(enable: true) }
            Button("لا", role: .cancel) { acknowledge(enable: false) }
        } message: {
            Text("«\(newSections.map { ArabicFormat.isolated($0.title) }.joined(separator: "»، «"))» — تبي تضيفها لمكتباتك؟")
        }
    }

    /// Tab bar on the iPhone; on the iPad (iPadOS 18+) it also opens as a sidebar, with the
    /// pinned libraries under «المكتبات» and the rest under «المزيد», like the Apple TV.
    @ViewBuilder
    private func tabs(_ filter: ContentFilter) -> some View {
        if #available(iOS 18.0, *) {
            let pinned = sidebar.pinned(from: filter.scopes)
            let rest = filter.scopes.filter { scope in !pinned.contains { $0.id == scope.id } }
            TabView(selection: $selection) {
                Tab("الرئيسية", systemImage: "house.fill", value: TabID.home) { HomeView(client: client) }
                Tab("قائمتي", systemImage: "plus.rectangle.on.rectangle", value: TabID.myList) { MyListView(client: client) }
                Tab("بحث", systemImage: "magnifyingglass", value: TabID.search) { SearchView(client: client) }
                Tab("التنزيلات", systemImage: "arrow.down.circle", value: TabID.downloads) { DownloadsView(client: client) }
                Tab("الإعدادات", systemImage: "gearshape.fill", value: TabID.settings) {
                    SettingsView(client: client, sections: sections)
                }
                if !filter.scopes.isEmpty {
                    TabSection("المكتبات") {
                        ForEach(pinned) { scope in
                            Tab(scope.title, systemImage: scope.icon, value: TabID.library(scope.id)) {
                                BrowseStack(client: client) { LibraryGridView(client: client, scope: scope) }
                            }
                        }
                        if !rest.isEmpty {
                            Tab("المزيد", systemImage: "ellipsis.circle", value: TabID.more) {
                                MoreLibrariesView(client: client, scopes: rest)
                            }
                        }
                    }
                    // The iPhone's tab bar keeps its five; libraries are in Settings there.
                    .defaultVisibility(.hidden, for: .tabBar)
                }
            }
            .tabViewStyle(.sidebarAdaptable)
        } else {
            TabView {
                HomeView(client: client)
                    .tabItem { Label("الرئيسية", systemImage: "house.fill") }
                MyListView(client: client)
                    .tabItem { Label("قائمتي", systemImage: "plus.rectangle.on.rectangle") }
                SearchView(client: client)
                    .tabItem { Label("بحث", systemImage: "magnifyingglass") }
                DownloadsView(client: client)
                    .tabItem { Label("التنزيلات", systemImage: "arrow.down.circle") }
                SettingsView(client: client, sections: sections)
                    .tabItem { Label("الإعدادات", systemImage: "gearshape.fill") }
            }
        }
    }

    /// Libraries added to the server since the profile last looked start locked; ask once.
    private func checkForNewLibraries() {
        let unknown = sections.filter { !profile.knownSections.contains($0.key) }
        guard !unknown.isEmpty else { return }
        if profile.isKids {
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

/// «المزيد»: the libraries not pinned to the sidebar.
struct MoreLibrariesView: View {
    let client: PlexServerClient
    let scopes: [LibraryScope]
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        BrowseStack(client: client) {
            List(scopes) { scope in
                NavigationLink(value: scope) { Label(scope.title, systemImage: scope.icon) }
            }
            .readableColumn(Metrics(sizeClass))
            .navigationTitle("المزيد")
        }
    }
}

/// Navigation stack used by every tab: items open their details page. Every push is by value
/// (a page opened with `isPresented` can't push values itself), so a tab that opens pages from
/// code passes its own `path`.
struct BrowseStack<Content: View>: View {
    let client: PlexServerClient
    var path: Binding<NavigationPath>?
    @ViewBuilder let content: () -> Content

    init(client: PlexServerClient, path: Binding<NavigationPath>? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.client = client
        self.path = path
        self.content = content
    }

    @State private var ownPath = NavigationPath()

    var body: some View {
        NavigationStack(path: path ?? $ownPath) {
            content()
                .navigationDestination(for: PlexItem.self) { item in
                    DetailView(client: client, entry: item)
                }
                .navigationDestination(for: LibraryScope.self) { scope in
                    LibraryGridView(client: client, scope: scope)
                }
        }
    }
}
