import SwiftUI

/// «قائمتي»: everything the profile added with «إضافة إلى قائمتي» (movies and shows).
struct MyListView: View {
    let client: PlexServerClient

    @Environment(ProfileStore.self) private var store
    @Environment(\.contentFilter) private var filter
    @State private var items: [PlexItem] = []
    @State private var loaded = false

    /// Removing an item from the list hides it right away, before the reload.
    private var visible: [PlexItem] { items.filter { store.isOnMyList($0.ratingKey) } }

    var body: some View {
        BrowseStack(client: client) {
            ScrollView {
                if loaded && visible.isEmpty {
                    ContentUnavailableView("قائمتي فاضية", systemImage: "plus.circle",
                                           description: Text("اضغط «+» في صفحة أي فيلم أو مسلسل، أو اضغط مطوّلاً على ملصقه، لإضافته هنا."))
                        .padding(.top, 80)
                }
                PosterGrid(items: visible, client: client)
                    .padding(.vertical, 8)
            }
            .overlay { if !loaded { ProgressView() } }
            .refreshable { await load(cached: false) }
            .navigationTitle("قائمتي")
        }
        .task { await load(cached: true) }
        .onReceive(NotificationCenter.default.publisher(for: .myListDidChange)) { _ in
            Task { await load(cached: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryShouldRefresh)) { _ in
            Task { await load(cached: false) }
        }
    }

    /// Saved copy first (instant), then the server.
    private func load(cached: Bool) async {
        if cached && items.isEmpty {
            let saved = await PlexResponseCache.$policy.withValue(.cacheOnly) {
                await UserFeed.myList(store: store, client: client, filter: filter)
            }
            if !saved.isEmpty { items = saved; loaded = true }
        }
        let fresh = await UserFeed.myList(store: store, client: client, filter: filter)
        if !fresh.isEmpty || store.myList.isEmpty { items = fresh }
        loaded = true
    }
}

/// Settings → «المكتبات»: browse each library, and choose which ones this profile sees.
struct LibrariesSettingsView: View {
    let client: PlexServerClient
    let sections: [PlexDirectory]

    @Environment(ProfileStore.self) private var store
    @Environment(\.contentFilter) private var filter

    var body: some View {
        List {
            Section("تصفّح") {
                if filter.scopes.isEmpty {
                    Text("لا توجد مكتبات ظاهرة").foregroundStyle(.secondary)
                }
                ForEach(filter.scopes) { scope in
                    NavigationLink(value: scope) {
                        Label(scope.title, systemImage: scope.icon)
                    }
                }
            }
            Section {
                NavigationLink {
                    LibrariesPage(client: client, sections: sections, scopes: scopesBinding)
                } label: {
                    LabeledContent("إظهار وإخفاء المكتبات",
                                   value: "\(ArabicFormat.digits(filter.scopes.count)) ظاهرة")
                }
            } footer: {
                Text("المكتبات المخفية تختفي من الرئيسية والبحث ومتابعة المشاهدة لهذا المستخدم فقط.")
            }
        }
        .navigationTitle("المكتبات")
    }

    /// Saves straight to the active profile.
    private var scopesBinding: Binding<[String]> {
        Binding {
            store.activeProfile?.scopes ?? []
        } set: { scopes in
            guard var profile = store.activeProfile else { return }
            profile.scopes = scopes
            store.update(profile)
        }
    }
}
