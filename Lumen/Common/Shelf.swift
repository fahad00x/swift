import CoreGraphics
import Foundation

// A row of cards (Apple TV Home and library pages; the iPhone / iPad library «مقترح» builds the
// same rows from `TVFeed`, so a profile's arrangement means the same rows on every device).

enum CardKind {
    /// 2:3 poster, ~6.3 across the screen.
    case poster
    /// 16:9 Continue Watching card (episode still / movie art), title below it.
    case landscape

    var size: CGSize {
        switch self {
        case .poster: return CGSize(width: 260, height: 390)
        case .landscape: return CGSize(width: 440, height: 248)
        }
    }

    static let cornerRadius: CGFloat = 13
    static let spacing: CGFloat = 40
    /// Side margin of rows, grids and banners (the sidebar is hidden while closed).
    static let inset: CGFloat = 80
}

struct Shelf: Identifiable {
    let id: String
    let title: String
    let kind: CardKind
    let items: [PlexItem]
    /// Top 10 style: large rank numbers on the cards.
    var ranked = false
    /// ratingKey → clear logo path.
    var logos: [String: String] = [:]
    /// Optional second header line in smaller grey (the library, «جديد هذا الأسبوع»…).
    var subtitle: String?
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
