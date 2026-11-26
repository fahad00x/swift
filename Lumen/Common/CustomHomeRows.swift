import Foundation
import Observation

/// What fills the rows a profile added to Home (`CustomHomeRow`): a library's newest titles,
/// one of its genres, a collection, or what a saved «فلترة» matches. Only what the profile may
/// see (`ContentFilter`).
@MainActor
enum CustomHomeRows {
    struct Content {
        let id: String
        let title: String
        let items: [PlexItem]
    }

    /// Titles in a row.
    static let rowSize = 20

    /// `exclude`: titles already on Home's own rows (a saved filter's row doesn't repeat them).
    static func load(_ layout: [HomeRowConfig]?, client: PlexServerClient, filter: ContentFilter,
                     store: ProfileStore, exclude: Set<String> = []) async -> [Content] {
        let added = (layout ?? []).filter { !$0.hidden && $0.custom != nil }
        guard !added.isEmpty else { return [] }
        let found = await withTaskGroup(of: (Int, [PlexItem]).self) { group in
            for (index, entry) in added.enumerated() {
                group.addTask {
                    guard let row = entry.custom else { return (index, []) }
                    return (index, await items(of: row, client: client, filter: filter, store: store))
                }
            }
            var out: [Int: [PlexItem]] = [:]
            for await (index, items) in group { out[index] = items }
            return out
        }
        // In Home's order, so a title goes to the first row that has it.
        var taken = exclude
        let affinity = UserFeed.genreAffinity(store: store)
        var out: [Content] = []
        for (index, entry) in added.enumerated() {
            var items = found[index] ?? []
            if entry.custom?.kind == .filter {
                items = RowRotation.batch(items, row: entry.id, store: store, affinity: affinity,
                                          exclude: taken, size: rowSize)
                taken.formUnion(items.map(\.ratingKey))
            }
            guard !items.isEmpty else { continue }
            out.append(Content(id: entry.id, title: entry.title ?? "", items: items))
        }
        return out
    }

    private static func items(of row: CustomHomeRow, client: PlexServerClient, filter: ContentFilter,
                              store: ProfileStore) async -> [PlexItem] {
        if row.kind == .filter {
            guard let id = row.scope, let criteria = row.criteria,
                  let scope = filter.scopes.first(where: { $0.id == id }) else { return [] }
            // The filter tab's own reading of the library, without its page.
            let model = LibraryFilterModel()
            model.criteria = criteria
            await model.load(client: client, scope: scope, filter: filter, store: store)
            await model.settled()
            return model.results
        }
        guard let section = filter.sections.first(where: { $0.key == row.section }) else { return [] }
        let found: [PlexItem]
        switch row.kind {
        case .recent:
            found = (try? await client.recentlyAdded(section: section, limit: 30)) ?? []
        case .genre:
            guard let genre = row.genre else { return [] }
            found = await client.items(section: section.key, type: section.type, genre: genre)
        case .collection:
            guard let collection = row.collection else { return [] }
            found = await client.collectionItems(collection)
        case .filter:
            return []
        }
        return Array(await filter.resolve(found, client: client).prefix(30))
    }
}

/// Which titles of a saved filter's row show today: what the profile hasn't started first,
/// then a mix of rating and taste with a pinch of chance that changes every day (the same
/// all day long, and different for every row).
enum RowRotation {
    @MainActor
    static func batch(_ items: [PlexItem], row: String, store: ProfileStore, affinity: [String: Double],
                      exclude: Set<String>, size: Int, day: Date = Date()) -> [PlexItem] {
        var touched = Set<String>()
        for state in store.activeStates where state.watched || state.offsetMs > 10_000 {
            touched.insert(state.showKey ?? state.ratingKey)
        }
        let pool = items.filter { !exclude.contains($0.ratingKey) }
        let tastes = pool.map { UserFeed.score($0, affinity: affinity) }
        let bestTaste = max(tastes.max() ?? 0, 0.0001)
        let today = day.formatted(.iso8601.year().month().day())
        let ranked = zip(pool, tastes).map { item, taste -> (PlexItem, Bool, Double) in
            let rating = min(max((item.ratingDisplay?.value ?? 0) / 10, 0), 1)
            let chance = Self.chance("\(row)|\(today)|\(item.ratingKey)")
            return (item, touched.contains(item.ratingKey), 0.4 * rating + 0.3 * taste / bestTaste + 0.6 * chance)
        }
        return ranked.sorted { a, b in a.1 != b.1 ? !a.1 : a.2 > b.2 }.prefix(size).map(\.0)
    }

    /// 0…1, the same for the same text on every launch and device (FNV-1a).
    static func chance(_ text: String) -> Double {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Double(hash % 1_000_000) / 1_000_000
    }
}

/// The rows Home built last (before the profile's arrangement), for «صفوف الرئيسية».
@MainActor
@Observable
final class HomeRowCatalog {
    static let shared = HomeRowCatalog()
    var rows: [HomeRowInfo] = []
}
