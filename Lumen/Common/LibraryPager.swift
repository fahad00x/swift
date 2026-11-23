import Foundation

/// One page of a library grid. Shared by the Apple TV and iPhone apps.
struct LibraryPage {
    var items: [PlexItem]
    /// Position in the server listing after this page.
    var nextOffset: Int
    var exhausted: Bool
    /// Known only when nothing is filtered on the device (or the end was reached).
    var total: Int?
}

enum LibraryPager {
    static let pageSize = 60

    /// Anime split, kids ratings and the profile's own «unwatched» are filtered on the device.
    static func filtersOnDevice(_ scope: LibraryScope, filter: ContentFilter, sort: LibrarySort) -> Bool {
        scope.kind != .all || filter.isKids || sort == .unwatched
    }

    /// nil when the server (or, under `.cacheOnly`, the disk) has nothing for it.
    static func page(client: PlexServerClient, scope: LibraryScope, filter: ContentFilter,
                     sort: LibrarySort, from offset: Int, shown: Int) async -> LibraryPage? {
        guard filtersOnDevice(scope, filter: filter, sort: sort) else {
            guard let page = try? await client.items(section: scope.section, sort: sort, start: offset, size: pageSize) else { return nil }
            let next = offset + page.items.count
            return LibraryPage(items: page.items, nextOffset: next,
                               exhausted: page.items.isEmpty || next >= page.total, total: page.total)
        }
        // Walk the library in bigger pages until a screenful of matching items is found.
        var found: [PlexItem] = []
        var next = offset
        var exhausted = false
        var gotAny = false
        while found.count < pageSize && !exhausted {
            guard let page = try? await client.items(section: scope.section, sort: sort, start: next, size: 200) else { break }
            gotAny = true
            next += page.items.count
            exhausted = page.items.isEmpty || next >= page.total
            var visible = await filter.resolve(page.items, client: client, scope: scope)
            if sort == .unwatched { visible = visible.filter { !$0.isWatched } }
            found += visible
        }
        guard gotAny else { return nil }
        return LibraryPage(items: found, nextOffset: next, exhausted: exhausted,
                           total: exhausted ? shown + found.count : nil)
    }
}
