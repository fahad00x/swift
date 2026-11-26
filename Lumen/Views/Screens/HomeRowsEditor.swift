import SwiftUI

/// Settings → المستخدم → «صفوف الرئيسية»: the profile's Home rows in order. Each row: move up or
/// down (it then keeps its place), fixed / dynamic, remove; removed rows can come back; and new
/// rows: a library's newest titles, one of its genres, a collection, or «قائمتي».
struct HomeRowsEditor: View {
    let client: PlexServerClient

    @Environment(ProfileStore.self) private var store
    @Environment(\.contentFilter) private var filter
    @State private var catalog = HomeRowCatalog.shared
    @State private var choosing: ChoiceList?
    @State private var confirmReset = false

    private var layout: [HomeRowConfig]? { store.activeProfile?.settings?.homeRows }
    private var entries: [HomeRowConfig] { HomeLayout.entries(current: catalog.rows, layout: layout) }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 40) {
                Text("صفوف الرئيسية")
                    .font(.system(size: 52, weight: .bold))
                    .padding(.horizontal, 24)

                SettingsCard(footer: "📌 ثابت: يبقى في مكانه، والمحتوى داخله يتغيّر. ✨ ديناميكي: التطبيق يختار هل يظهر ووين. نقل الصف يخليه ثابت.") {
                    ForEach(entries.filter { !$0.hidden }) { entry in
                        SettingsRow(name(entry), detail: entry.custom != nil ? "صف أضفته" : nil,
                                    value: entry.pinned ? "📌 ثابت" : "✨ ديناميكي", arrow: true) { actions(for: entry) }
                    }
                }

                SettingsCard {
                    SettingsRow("إضافة صف", detail: "أضيف مؤخراً، نوع، مجموعة، أو قائمتي", arrow: true) { chooseKind() }
                    if layout != nil {
                        SettingsRow("إرجاع الترتيب الأصلي", destructive: true) { confirmReset = true }
                    }
                }

                let removed = entries.filter(\.hidden)
                if !removed.isEmpty {
                    SettingsCard("محذوفة من الرئيسية") {
                        ForEach(removed) { entry in
                            SettingsRow(name(entry), value: "إرجاع") { change { HomeLayout.restoring(entry.id, current: catalog.rows, layout: $0) } }
                        }
                    }
                }
            }
            .padding(.vertical, 60)
            .padding(.horizontal, CardKind.inset + 24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .background(Color(white: 0.07).ignoresSafeArea())
        .fullScreenCover(item: $choosing) { ChoicePanel(list: $0) }
        .alert("إرجاع الترتيب الأصلي؟", isPresented: $confirmReset) {
            Button("إرجاع", role: .destructive) { store.updateSettings { $0.homeRows = nil } }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("ترجع الرئيسية مثل ما يبنيها التطبيق، وتنحذف الصفوف اللي أضفتها.")
        }
    }

    private func name(_ entry: HomeRowConfig) -> String {
        entry.title ?? Self.defaultTitle(entry.id)
    }

    static func defaultTitle(_ id: String) -> String {
        switch id {
        case "continue": return "متابعة المشاهدة"
        case "mylist": return "قائمتي"
        case "because": return "لأنك شاهدت…"
        case "watched": return "شوهدت مؤخرًا"
        default: return id
        }
    }

    private func change(_ edit: ([HomeRowConfig]?) -> [HomeRowConfig]) {
        store.updateSettings { $0.homeRows = edit($0.homeRows) }
    }

    // MARK: One row

    private func actions(for entry: HomeRowConfig) {
        let shown = entries.filter { !$0.hidden }
        let at = shown.firstIndex { $0.id == entry.id } ?? 0
        var options: [(String, () -> Void)] = []
        if at > 0 {
            options.append(("نقل لأعلى", { change { HomeLayout.moving(entry.id, by: -1, current: catalog.rows, layout: $0) } }))
        }
        if at < shown.count - 1 {
            options.append(("نقل لأسفل", { change { HomeLayout.moving(entry.id, by: 1, current: catalog.rows, layout: $0) } }))
        }
        options.append(entry.pinned
            ? ("خلّه ديناميكي ✨", { change { HomeLayout.settingPinned(entry.id, false, current: catalog.rows, layout: $0) } })
            : ("تثبيت في مكانه 📌", { change { HomeLayout.settingPinned(entry.id, true, current: catalog.rows, layout: $0) } }))
        options.append(("حذف من الرئيسية", { remove(entry) }))
        choosing = ChoiceList(title: name(entry), options: options.map(\.0), selected: nil) { options[$0].1() }
    }

    private func remove(_ entry: HomeRowConfig) {
        // «قائمتي» on Home is its own setting.
        if entry.id == "mylist" { store.updateSettings { $0.myListOnHome = false } }
        change { HomeLayout.hiding(entry.id, current: catalog.rows, layout: $0) }
    }

    // MARK: Adding

    private func chooseKind() {
        var kinds: [(String, () -> Void)] = [
            ("أضيف مؤخراً في مكتبة", { chooseLibrary { add(recent: $0) } }),
            ("نوع من مكتبة (كوميديا، رعب…)", { chooseLibrary { chooseGenre(in: $0) } }),
            ("مجموعة", { chooseLibrary { chooseCollection(in: $0) } }),
        ]
        if store.activeProfile?.settings?.myListOnHome != true {
            kinds.append(("قائمتي", {
                store.updateSettings { $0.myListOnHome = true }
                change { HomeLayout.restoring("mylist", current: catalog.rows, layout: $0) }
            }))
        }
        choosing = ChoiceList(title: "إضافة صف", options: kinds.map(\.0), selected: nil) { kinds[$0].1() }
    }

    /// The next list once this one has closed.
    private func next(_ list: ChoiceList) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { choosing = list }
    }

    private func chooseLibrary(then: @escaping (PlexDirectory) -> Void) {
        let libraries = filter.sections.filter(\.isVideoLibrary)
        guard !libraries.isEmpty else { return }
        next(ChoiceList(title: "من أي مكتبة؟", options: libraries.map(\.title), selected: nil) { then(libraries[$0]) })
    }

    private func chooseGenre(in section: PlexDirectory) {
        Task {
            let genres = await client.genreDirectories(section: section.key)
            guard !genres.isEmpty else { return }
            next(ChoiceList(title: "أي نوع؟", options: genres.map { ArabicFormat.genre($0.title) }, selected: nil) { index in
                let genre = genres[index]
                add(HomeRowConfig(id: "custom-\(UUID().uuidString)",
                                  title: "\(ArabicFormat.genre(genre.title)) في \(ArabicFormat.isolated(section.title))",
                                  custom: CustomHomeRow(kind: .genre, section: section.key, genre: genre.key)))
            })
        }
    }

    private func chooseCollection(in section: PlexDirectory) {
        Task {
            let collections = await client.collections(section: section.key)
            guard !collections.isEmpty else { return }
            next(ChoiceList(title: "أي مجموعة؟", options: collections.map(\.title), selected: nil) { index in
                let collection = collections[index]
                add(HomeRowConfig(id: "custom-\(UUID().uuidString)", title: collection.title,
                                  custom: CustomHomeRow(kind: .collection, section: section.key, collection: collection.ratingKey)))
            })
        }
    }

    private func add(recent section: PlexDirectory) {
        add(HomeRowConfig(id: "custom-\(UUID().uuidString)",
                          title: "أضيف مؤخراً في \(ArabicFormat.isolated(section.title))",
                          custom: CustomHomeRow(kind: .recent, section: section.key)))
    }

    private func add(_ row: HomeRowConfig) {
        change { HomeLayout.adding(row, current: catalog.rows, layout: $0) }
    }
}
