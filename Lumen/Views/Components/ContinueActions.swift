import SwiftUI

/// «إزالة من متابعة المشاهدة»: hidden until watched again, or with its history deleted too.
@MainActor
enum ContinueActions {
    static func key(_ item: PlexItem) -> String {
        item.isEpisode ? (item.grandparentRatingKey ?? item.ratingKey) : item.ratingKey
    }

    /// When something was last removed (its row then focuses the next card).
    private(set) static var removedAt = Date.distantPast

    static func remove(_ key: String, deletingHistory: Bool, store: ProfileStore) {
        removedAt = Date()
        if deletingHistory { store.clearHistory(of: key) } else { store.hideFromContinue(key) }
        NotificationCenter.default.post(name: .plexPlaybackDidEnd, object: nil)
    }
}

/// Asks whether the history goes too.
struct RemoveFromContinueDialog: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let key: String

    @Environment(ProfileStore.self) private var store

    func body(content: Content) -> some View {
        content.alert("إزالة «\(ArabicFormat.isolated(title))» من متابعة المشاهدة؟", isPresented: $isPresented) {
            Button("إزالة فقط") { ContinueActions.remove(key, deletingHistory: false, store: store) }
            Button("إزالة وحذف السجل", role: .destructive) { ContinueActions.remove(key, deletingHistory: true, store: store) }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("«إزالة فقط» تُبقي ما شاهدته، ويرجع إذا شاهدت منه شيئًا. «حذف السجل» يرجّعه كأنك ما شاهدته.")
        }
    }
}

/// Long press on a Continue Watching poster.
struct ContinueCardMenu: ViewModifier {
    let item: PlexItem
    let client: PlexServerClient

    @Environment(ProfileStore.self) private var store
    @State private var asking = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button(item.isEpisode ? "تحديد الحلقة كمُشاهَدة" : "تحديد كمُشاهَد", systemImage: "checkmark.circle") {
                    Task { await WatchedActions.setWatched(item, true, client: client, store: store) }
                }
                Button("إزالة من متابعة المشاهدة", systemImage: "minus.circle", role: .destructive) { asking = true }
            }
            .modifier(RemoveFromContinueDialog(isPresented: $asking, title: item.cardTitle, key: ContinueActions.key(item)))
    }
}

extension [Shelf] {
    /// The Continue Watching row as the profile wants it: without what it removed, with every
    /// show that has something new (the row itself looks at the latest ones only), in its order.
    /// `section`: a library's page (nil: Home).
    @MainActor
    func shown(to store: ProfileStore, news: ShowNews?, filter: ContentFilter, section: String? = nil) -> [Shelf] {
        var out = self
        let at = out.firstIndex { $0.id == "continue" }
        var items = at.map { out[$0].items } ?? []
        let there = Set(items.map(ContinueActions.key))
        let missing = (news?.info ?? [:]).filter { $0.value.badge != nil && !there.contains($0.key) }
            .sorted { $0.value.newest > $1.value.newest }.compactMap(\.value.episode)
            .filter { filter.allows($0) && (section == nil || $0.librarySectionID == section) }
        items = (items + missing).filter { !store.isHiddenFromContinue(ContinueActions.key($0)) }
        if store.activeProfile?.settings?.continueNewFirst == true {
            let new = items.filter { news?.of($0)?.badge != nil }
                .sorted { (news?.of($0)?.newest ?? 0) > (news?.of($1)?.newest ?? 0) }
            items = new + items.filter { news?.of($0)?.badge == nil }
        }
        guard let at else {
            if !items.isEmpty { out.insert(Shelf(id: "continue", title: "متابعة المشاهدة", kind: .poster, items: items), at: 0) }
            return out
        }
        let shelf = out[at]
        if items.isEmpty {
            out.remove(at: at)
        } else {
            out[at] = Shelf(id: shelf.id, title: shelf.title, kind: shelf.kind, items: items, ranked: shelf.ranked,
                            logos: shelf.logos, subtitle: shelf.subtitle)
        }
        return out
    }
}
