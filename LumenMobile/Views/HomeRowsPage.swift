import SwiftUI

/// Settings → المستخدم → «صفوف الرئيسية» (iPhone / iPad): the profile's Home rows, the same
/// arrangement as on the Apple TV. Drag to reorder (the row then keeps its place), 📌 / ✨ to
/// fix it or let the app place it, swipe to remove; removed rows come back from their section;
/// new rows: a library's newest titles, one of its genres, a collection, or «قائمتي».
struct HomeRowsPage: View {
    let client: PlexServerClient

    @Environment(ProfileStore.self) private var store
    @Environment(\.contentFilter) private var filter
    @State private var catalog = HomeRowCatalog.shared
    @State private var confirmReset = false
    @State private var picking: Picking?
    /// Always editing (drag handles and ⊖); a binding so ⊖ can reveal its delete button.
    @State private var editMode: EditMode = .active

    /// A list to choose a genre or a collection from (read from the server).
    private enum Picking: Identifiable {
        case genre(PlexDirectory)
        case collection(PlexDirectory)
        var id: String {
            switch self {
            case .genre(let s): return "genre-\(s.key)"
            case .collection(let s): return "collection-\(s.key)"
            }
        }
    }

    private var layout: [HomeRowConfig]? { store.activeProfile?.settings?.homeRows }

    /// What Home built, without an added row that's gone from the arrangement.
    private var current: [HomeRowInfo] {
        let kept = Set((layout ?? []).filter { $0.custom != nil }.map(\.id))
        return catalog.rows.filter { !$0.id.hasPrefix("custom-") || kept.contains($0.id) }
    }

    private var entries: [HomeRowConfig] { HomeLayout.entries(current: current, layout: layout) }
    private var libraries: [PlexDirectory] { filter.sections.filter(\.isVideoLibrary) }

    var body: some View {
        let shown = entries.filter { !$0.hidden }
        let removed = entries.filter(\.hidden)
        List {
            Section {
                ForEach(shown) { entry in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name(entry))
                            if entry.custom != nil {
                                Text("صف أضفته").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            change { HomeLayout.settingPinned(entry.id, !entry.pinned, current: current, layout: $0) }
                        } label: {
                            Label(entry.pinned ? "ثابت" : "ديناميكي", systemImage: entry.pinned ? "pin.fill" : "sparkles")
                                .font(.callout)
                                .foregroundStyle(entry.pinned ? Color.orange : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .onMove { from, to in move(from: from, to: to, shown: shown) }
                .onDelete { offsets in offsets.map { shown[$0] }.forEach(remove) }
            } footer: {
                Text("📌 ثابت: يبقى في مكانه، والمحتوى داخله يتغيّر. ✨ ديناميكي: التطبيق يختار هل يظهر ووين. سحب الصف يخليه ثابت. نفس الترتيب في كل أجهزتك.")
            }

            Section {
                addMenu
                if layout != nil {
                    Button("إرجاع الترتيب الأصلي", role: .destructive) { confirmReset = true }
                }
            }

            if !removed.isEmpty {
                Section("محذوفة من الرئيسية") {
                    ForEach(removed) { entry in
                        Button {
                            restore(entry.id)
                        } label: {
                            HStack {
                                Text(name(entry)).foregroundStyle(.primary)
                                Spacer()
                                Label("إرجاع", systemImage: "plus.circle.fill").labelStyle(.iconOnly)
                            }
                        }
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("صفوف الرئيسية")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("إرجاع الترتيب الأصلي؟", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("إرجاع", role: .destructive) { store.updateSettings { $0.homeRows = nil } }
        } message: {
            Text("ترجع الرئيسية مثل ما يبنيها التطبيق في كل أجهزتك، وتنحذف الصفوف اللي أضفتها.")
        }
        .sheet(item: $picking) { pick in
            NavigationStack { picker(pick) }
                .presentationDetents([.medium, .large])
        }
    }

    private func name(_ entry: HomeRowConfig) -> String {
        if let title = entry.title { return title }
        switch entry.id {
        case "continue": return "متابعة المشاهدة"
        case "mylist": return "قائمتي"
        case "because": return "لأنك شاهدت…"
        case "watched": return "شوهدت مؤخرًا"
        case "top": return "الأعلى تقييماً لك"
        default: return entry.id
        }
    }

    private func change(_ edit: ([HomeRowConfig]?) -> [HomeRowConfig]) {
        store.updateSettings { $0.homeRows = edit($0.homeRows) }
    }

    /// A drag: one place at a time, so the row ends where it was dropped (and is fixed there).
    private func move(from: IndexSet, to: Int, shown: [HomeRowConfig]) {
        guard let source = from.first else { return }
        let target = to > source ? to - 1 : to
        guard target != source else { return }
        let id = shown[source].id
        let step = target > source ? 1 : -1
        let infos = current
        store.updateSettings { settings in
            var rows = settings.homeRows
            for _ in 0..<abs(target - source) {
                rows = HomeLayout.moving(id, by: step, current: infos, layout: rows)
            }
            settings.homeRows = rows
        }
    }

    private func remove(_ entry: HomeRowConfig) {
        // «قائمتي» on the Apple TV's Home is its own setting.
        if entry.id == "mylist" { store.updateSettings { $0.myListOnHome = false } }
        change { HomeLayout.hiding(entry.id, current: current, layout: $0) }
    }

    private func restore(_ id: String) {
        if id == "mylist" { store.updateSettings { $0.myListOnHome = true } }
        change { HomeLayout.restoring(id, current: current, layout: $0) }
    }

    // MARK: Adding

    private var addMenu: some View {
        Menu {
            Menu("أضيف مؤخراً في مكتبة") {
                ForEach(libraries, id: \.key) { section in
                    Button(section.title) {
                        add(HomeRowConfig(id: "custom-\(UUID().uuidString)",
                                          title: "أضيف مؤخراً في \(ArabicFormat.isolated(section.title))",
                                          custom: CustomHomeRow(kind: .recent, section: section.key)))
                    }
                }
            }
            Menu("نوع من مكتبة (كوميديا، رعب…)") {
                ForEach(libraries, id: \.key) { section in
                    Button(section.title) { picking = .genre(section) }
                }
            }
            Menu("مجموعة") {
                ForEach(libraries, id: \.key) { section in
                    Button(section.title) { picking = .collection(section) }
                }
            }
            if entries.contains(where: { $0.id == "mylist" && $0.hidden }) {
                Button("قائمتي") { restore("mylist") }
            }
        } label: {
            Label("إضافة صف", systemImage: "plus")
        }
    }

    private func add(_ row: HomeRowConfig) {
        change { HomeLayout.adding(row, current: current, layout: $0) }
    }

    @ViewBuilder
    private func picker(_ pick: Picking) -> some View {
        switch pick {
        case .genre(let section):
            ChoiceListPage(title: "أي نوع؟") {
                await client.genreDirectories(section: section.key).map { ($0.key, ArabicFormat.genre($0.title)) }
            } choose: { key, title in
                add(HomeRowConfig(id: "custom-\(UUID().uuidString)",
                                  title: "\(title) في \(ArabicFormat.isolated(section.title))",
                                  custom: CustomHomeRow(kind: .genre, section: section.key, genre: key)))
                picking = nil
            }
        case .collection(let section):
            ChoiceListPage(title: "أي مجموعة؟") {
                await client.collections(section: section.key).map { ($0.ratingKey, $0.title) }
            } choose: { key, title in
                add(HomeRowConfig(id: "custom-\(UUID().uuidString)", title: title,
                                  custom: CustomHomeRow(kind: .collection, section: section.key, collection: key)))
                picking = nil
            }
        }
    }
}

/// A list read from the server, one of it chosen.
private struct ChoiceListPage: View {
    let title: String
    let load: () async -> [(String, String)]
    let choose: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var options: [(String, String)]?

    var body: some View {
        Group {
            if let options {
                if options.isEmpty {
                    ContentUnavailableView("ما فيه شي هنا", systemImage: "tray")
                } else {
                    List(options, id: \.0) { option in
                        Button(option.1) { choose(option.0, option.1) }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } } }
        .task { if options == nil { options = await load() } }
    }
}
