import Foundation
import Observation

/// What fills the rows a profile added to Home (`CustomHomeRow`): a library's newest titles,
/// one of its genres, or a collection. Only what the profile may see (`ContentFilter`).
enum CustomHomeRows {
    struct Content {
        let id: String
        let title: String
        let items: [PlexItem]
    }

    static func load(_ layout: [HomeRowConfig]?, client: PlexServerClient, filter: ContentFilter) async -> [Content] {
        let added = (layout ?? []).filter { !$0.hidden && $0.custom != nil }
        guard !added.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, Content?).self) { group in
            for (index, entry) in added.enumerated() {
                group.addTask {
                    guard let row = entry.custom else { return (index, nil) }
                    let items = await items(of: row, client: client, filter: filter)
                    guard !items.isEmpty else { return (index, nil) }
                    return (index, Content(id: entry.id, title: entry.title ?? "", items: items))
                }
            }
            var out: [(Int, Content)] = []
            for await (index, content) in group { if let content { out.append((index, content)) } }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func items(of row: CustomHomeRow, client: PlexServerClient, filter: ContentFilter) async -> [PlexItem] {
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
        }
        return Array(await filter.resolve(found, client: client).prefix(30))
    }
}

/// The rows Home built last (before the profile's arrangement), for «صفوف الرئيسية».
@MainActor
@Observable
final class HomeRowCatalog {
    static let shared = HomeRowCatalog()
    var rows: [HomeRowInfo] = []
}
