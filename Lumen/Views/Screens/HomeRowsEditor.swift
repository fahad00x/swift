import SwiftUI

/// Settings → المستخدم → «صفوف الرئيسية» (or a library's «مقترح»): the profile's rows in order. Each row: move up or
/// down (it then keeps its place), fixed / dynamic, remove; removed rows can come back; and new
/// rows: a library's newest titles, one of its genres, a collection, or «قائمتي».
struct HomeRowsEditor: View {
    let client: PlexServerClient
    var target: RowsTarget = .home
    /// The library, for `.library` (its rows are added from it only).
    var scope: LibraryScope?

    @Environment(ProfileStore.self) private var store
    @Environment(\.contentFilter) private var filter
    @State private var catalog = HomeRowCatalog.shared
    @State private var choosing: ChoiceList?
    @State private var confirmReset = false

    private var layout: [HomeRowConfig]? { target.layout(store.activeProfile?.settings) }
    /// What Home / the library built, without an added row that's gone from the arrangement
    /// (removed or reset, still on the page until it reloads).
    private var current: [HomeRowInfo] {
        let kept = Set((layout ?? []).filter { $0.custom != nil }.map(\.id))
        return catalog.rows(of: target).filter { !$0.id.hasPrefix("custom-") || kept.contains($0.id) }
    }
    private var entries: [HomeRowConfig] { HomeLayout.entries(current: current, layout: layout) }
    private var isHome: Bool { target == .home }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 40) {
                Text(isHome ? "صفوف الرئيسية" : "مقترح \(scope?.title ?? "")")
                    .font(.system(size: 52, weight: .bold))
                    .padding(.horizontal, 24)

                SettingsCard(footer: "📌 ثابت: يبقى في مكانه، والمحتوى داخله يتغيّر. ✨ ديناميكي: التطبيق يختار هل يظهر ووين. نقل الصف يخليه ثابت.") {
                    ForEach(entries.filter { !$0.hidden }) { entry in
                        SettingsRow(name(entry), detail: entry.custom != nil ? "صف أضفته" : nil,
                                    value: entry.pinned ? "📌 ثابت" : "✨ ديناميكي", arrow: true) { actions(for: entry) }
                    }
                }

                SettingsCard {
                    SettingsRow("إضافة صف", detail: isHome ? "أضيف مؤخراً، نوع، مجموعة، أو قائمتي" : "أضيف مؤخراً، نوع، أو مجموعة",
                                arrow: true) { chooseKind() }
                    if layout != nil {
                        SettingsRow("إرجاع الترتيب الأصلي", destructive: true) { confirmReset = true }
                    }
                }

                let removed = entries.filter(\.hidden)
                if !removed.isEmpty {
                    SettingsCard("محذوفة من الرئيسية") {
                        ForEach(removed) { entry in
                            SettingsRow(name(entry), value: "إرجاع") { change { HomeLayout.restoring(entry.id, current: current, layout: $0) } }
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
            Button("إرجاع", role: .destructive) { store.updateSettings { target.set(nil, in: &$0) } }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text(isHome ? "ترجع الرئيسية مثل ما يبنيها التطبيق، وتنحذف الصفوف اللي أضفتها."
                        : "يرجع «مقترح» مثل ما يبنيه التطبيق، وتنحذف الصفوف اللي أضفتها.")
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
        store.updateSettings { target.set(edit(target.layout($0)), in: &$0) }
    }

    // MARK: One row

    private func actions(for entry: HomeRowConfig) {
        let shown = entries.filter { !$0.hidden }
        let at = shown.firstIndex { $0.id == entry.id } ?? 0
        var options: [(String, () -> Void)] = []
        if at > 0 {
            options.append(("نقل لأعلى", { change { HomeLayout.moving(entry.id, by: -1, current: current, layout: $0) } }))
        }
        if at < shown.count - 1 {
            options.append(("نقل لأسفل", { change { HomeLayout.moving(entry.id, by: 1, current: current, layout: $0) } }))
        }
        options.append(entry.pinned
            ? ("خلّه ديناميكي ✨", { change { HomeLayout.settingPinned(entry.id, false, current: current, layout: $0) } })
            : ("تثبيت في مكانه 📌", { change { HomeLayout.settingPinned(entry.id, true, current: current, layout: $0) } }))
        options.append(("حذف من الرئيسية", { remove(entry) }))
        choosing = ChoiceList(title: name(entry), options: options.map(\.0), selected: nil) { options[$0].1() }
    }

    private func remove(_ entry: HomeRowConfig) {
        // «قائمتي» on Home is its own setting.
        if entry.id == "mylist" { store.updateSettings { $0.myListOnHome = false } }
        change { HomeLayout.hiding(entry.id, current: current, layout: $0) }
    }

    // MARK: Adding

    private func chooseKind() {
        var kinds: [(String, () -> Void)] = [
            ("أضيف مؤخراً\(isHome ? " في مكتبة" : "")", { chooseLibrary { add(recent: $0) } }),
            ("نوع\(isHome ? " من مكتبة" : "") (كوميديا، رعب…)", { chooseLibrary { chooseGenre(in: $0) } }),
            ("مجموعة", { chooseLibrary { chooseCollection(in: $0) } }),
        ]
        if isHome, store.activeProfile?.settings?.myListOnHome != true {
            kinds.append(("قائمتي", {
                store.updateSettings { $0.myListOnHome = true }
                change { HomeLayout.restoring("mylist", current: current, layout: $0) }
            }))
        }
        choosing = ChoiceList(title: "إضافة صف", options: kinds.map(\.0), selected: nil) { kinds[$0].1() }
    }

    /// The next list once this one has closed.
    private func next(_ list: ChoiceList) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { choosing = list }
    }

    private func chooseLibrary(then: @escaping (PlexDirectory) -> Void) {
        // A library's own rows come from it.
        if let scope, !isHome { return then(scope.section) }
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
        change { HomeLayout.adding(row, current: current, layout: $0) }
    }
}
