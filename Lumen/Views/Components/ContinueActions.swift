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
    /// Without what the profile removed from its Continue Watching row.
    @MainActor
    func shown(to store: ProfileStore) -> [Shelf] {
        compactMap { shelf in
            guard shelf.id == "continue" else { return shelf }
            let items = shelf.items.filter { !store.isHiddenFromContinue(ContinueActions.key($0)) }
            guard !items.isEmpty else { return nil }
            return Shelf(id: shelf.id, title: shelf.title, kind: shelf.kind, items: items, ranked: shelf.ranked,
                         logos: shelf.logos, subtitle: shelf.subtitle)
        }
    }
}
