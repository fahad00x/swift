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

    var body: some View {
        let filter = ContentFilter(profile: profile, sections: sections)
        TabView {
            HomeView(client: client)
                .tabItem { Label("الرئيسية", systemImage: "house.fill") }
            MyListView(client: client)
                .tabItem { Label("قائمتي", systemImage: "plus.rectangle.on.rectangle") }
            SearchView(client: client)
                .tabItem { Label("بحث", systemImage: "magnifyingglass") }
            SettingsView(client: client, sections: sections)
                .tabItem { Label("الإعدادات", systemImage: "gearshape.fill") }
        }
        .environment(\.contentFilter, filter)
        .task { checkForNewLibraries() }
        .alert(newSections.count > 1 ? "فيه مكتبات جديدة" : "فيه مكتبة جديدة",
               isPresented: Binding(get: { !newSections.isEmpty }, set: { if !$0 { newSections = [] } })) {
            Button("إضافة") { acknowledge(enable: true) }
            Button("لا", role: .cancel) { acknowledge(enable: false) }
        } message: {
            Text("«\(newSections.map { ArabicFormat.isolated($0.title) }.joined(separator: "»، «"))» — تبي تضيفها لمكتباتك؟")
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

/// Navigation stack used by every tab: items open their details page.
struct BrowseStack<Content: View>: View {
    let client: PlexServerClient
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
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
