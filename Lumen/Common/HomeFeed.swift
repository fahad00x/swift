import CryptoKit
import Foundation

/// Everything on Home for the active profile, built from its own history and the libraries it
/// may see. Shared by the Apple TV and iPhone apps.
struct HomeFeed: Codable {
    struct Row: Identifiable, Codable {
        let id: String
        let title: String
        let items: [PlexItem]
        var ranked = false
    }

    var featured: [FeaturedItem] = []
    var continueWatching: [PlexItem] = []
    /// ratingKey → clear logo path, for the Continue Watching cards.
    var continueLogos: [String: String] = [:]
    var myList: [PlexItem] = []
    var rows: [Row] = []

    var isEmpty: Bool { featured.isEmpty && continueWatching.isEmpty && myList.isEmpty && rows.isEmpty }

    /// Stale-while-revalidate: shows the feed built from the responses saved on disk right away
    /// (when `showCached`), then rebuilds it from the server and shows that. A refresh that comes
    /// back empty (offline, server down) keeps what's on screen.
    /// `current` is what's on screen now (for a refresh without the cached step).
    @MainActor
    static func loadCacheFirst(client: PlexServerClient, store: ProfileStore, filter: ContentFilter,
                               showCached: Bool, current: HomeFeed? = nil, apply: (HomeFeed) -> Void) async {
        var shown = current
        if showCached {
            // 1) The Home screen exactly as it was last shown (hero, Continue Watching, rows).
            var cached = saved(client: client, store: store)
            // 2) Otherwise rebuild what's possible from the saved server responses.
            if cached == nil || cached!.isEmpty {
                cached = await PlexResponseCache.$policy.withValue(.cacheOnly) {
                    await load(client: client, store: store, filter: filter)
                }
            }
            if let cached, !cached.isEmpty {
                apply(cached)
                shown = cached
            }
        }
        var fresh = await load(client: client, store: store, filter: filter)
        guard !fresh.isEmpty else { return }
        // A partial refresh (slow or dropped connection) never wipes the suggestions on screen.
        if fresh.featured.isEmpty, let previous = shown?.featured, !previous.isEmpty {
            fresh.featured = previous
        }
        apply(fresh)
        fresh.save(client: client, store: store)
    }

    // MARK: Saved snapshot (per server and profile)

    @MainActor
    private static func snapshotURL(client: PlexServerClient, store: ProfileStore) -> URL? {
        guard let profile = store.activeProfile else { return nil }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomeSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A different library selection / kids mode / genre focus means a different Home.
        let signature = SHA256.hash(data: Data(profile.contentSignature.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(client.machineIdentifier)-\(profile.id)-\(signature).json")
    }

    /// The last Home shown for this server and profile, with the profile's current progress.
    @MainActor
    static func saved(client: PlexServerClient, store: ProfileStore) -> HomeFeed? {
        guard let url = snapshotURL(client: client, store: store),
              let data = try? Data(contentsOf: url),
              let feed = try? JSONDecoder().decode(HomeFeed.self, from: data) else { return nil }
        return feed.overlaid(client.userState)
    }

    @MainActor
    func save(client: PlexServerClient, store: ProfileStore) {
        guard let url = Self.snapshotURL(client: client, store: store) else { return }
        let feed = self
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(feed) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Re-applies the active profile's progress / watched marks to every item.
    func overlaid(_ state: UserStateSnapshot) -> HomeFeed {
        var copy = self
        copy.featured = featured.map {
            FeaturedItem(reason: $0.reason, display: $0.display.applying(state), playable: $0.playable?.applying(state))
        }
        copy.continueWatching = continueWatching.map { $0.applying(state) }
        copy.myList = myList.map { $0.applying(state) }
        copy.rows = rows.map { Row(id: $0.id, title: $0.title, items: $0.items.map { $0.applying(state) }, ranked: $0.ranked) }
        return copy
    }

    @MainActor
    static func load(client: PlexServerClient, store: ProfileStore, filter: ContentFilter) async -> HomeFeed {
        let librarySections = filter.sections
        let perSection: [String: SectionData] = await withTaskGroup(of: SectionData.self) { group in
            for section in librarySections {
                // Split / kids libraries lose items to filtering: fetch more.
                let generous = filter.isSplit(section.key) || filter.isKids || !filter.focusGenres.isEmpty
                group.addTask {
                    #if os(tvOS)
                    let recent = (try? await client.recentlyAdded(section: section, limit: generous ? 90 : 30)) ?? []
                    return SectionData(section: section, recent: recent, topRated: [], sample: [])
                    #else
                    async let recent = client.recentlyAdded(section: section, limit: generous ? 90 : 30)
                    async let top = client.items(section: section, sort: .rating, start: 0, size: generous ? 80 : 30)
                    // A sample of the library to discover its main genres.
                    async let sample = client.items(section: section, sort: .recentlyAdded, start: 0, size: 250)
                    return SectionData(section: section,
                                       recent: (try? await recent) ?? [],
                                       topRated: (try? await top)?.items ?? [],
                                       sample: (try? await sample)?.items ?? [])
                    #endif
                }
            }
            var out: [String: SectionData] = [:]
            for await result in group { out[result.section.key] = result }
            return out
        }

        async let continueTask = UserFeed.continueWatching(store: store, client: client, filter: filter)
        async let listTask = UserFeed.myList(store: store, client: client, filter: filter)
        let affinity = UserFeed.genreAffinity(store: store)

        // «أضيف مؤخراً في …» per enabled library / anime scope, in tab order.
        var recentByScope: [(LibraryScope, [PlexItem])] = []
        for scope in filter.scopes {
            guard let data = perSection[scope.section.key] else { continue }
            var items = await filter.resolve(data.recent, client: client, scope: scope)
            if !filter.focusGenres.isEmpty {
                // Focus genres first, the rest after.
                let focused = await filter.resolve(items, client: client, scope: scope, focusedOnly: true)
                let keys = Set(focused.map(\.ratingKey))
                items = focused + items.filter { !keys.contains($0.ratingKey) }
            }
            recentByScope.append((scope, Array(items.prefix(24))))
        }

        #if os(tvOS)
        // Apple TV Home: Continue Watching, then «أضيف مؤخراً» per library (all from the device).
        let tvRows = recentByScope.filter { !$0.1.isEmpty }.map { scope, items in
            Row(id: "recent-\(scope.id)", title: "أضيف مؤخراً في \(scope.rowName)", items: items)
        }
        return HomeFeed(featured: [], continueWatching: await continueTask, continueLogos: [:],
                        myList: await listTask, rows: tvRows)
        #else
        let focusOnly = !filter.focusGenres.isEmpty
        let sample = await filter.resolve(perSection.values.flatMap(\.sample), client: client, focusedOnly: focusOnly)
        let topCandidates = await filter.resolve(perSection.values.flatMap(\.topRated), client: client, focusedOnly: focusOnly)

        let deck = await continueTask
        let list = await listTask

        // Hero suggestions: new arrivals the profile hasn't watched, closest to its taste first.
        var heroLists = recentByScope.map { _, items in
            items.filter { !$0.isWatched }.enumerated()
                .sorted { a, b in
                    let sa = UserFeed.score(a.element, affinity: affinity), sb = UserFeed.score(b.element, affinity: affinity)
                    return sa != sb ? sa > sb : a.offset < b.offset
                }
                .map(\.element)
        }
        if focusOnly {
            var focused: [[PlexItem]] = []
            for (index, (scope, _)) in recentByScope.enumerated() {
                focused.append(await filter.resolve(heroLists[index], client: client, scope: scope, focusedOnly: true))
            }
            if focused.contains(where: { !$0.isEmpty }) { heroLists = focused }
        }
        let newFeatured = await FeaturedBuilder.build(client: client, onDeck: deck, recent: heroLists)
        let logos = await Self.logos(for: deck, known: newFeatured, client: client)

        var rows: [Row] = []
        let top = Self.topRated(topCandidates, affinity: affinity)
        if top.count >= 3 {
            rows.append(Row(id: "top", title: "الأعلى تقييماً لك", items: top, ranked: true))
        }
        rows += recentByScope.filter { !$0.1.isEmpty }.map { scope, items in
            Row(id: "recent-\(scope.id)", title: "أضيف مؤخراً في \(scope.rowName)", items: items)
        }
        rows += Self.genreRows(sample, focus: filter.focusGenres, affinity: affinity)

        return HomeFeed(featured: newFeatured, continueWatching: deck, continueLogos: logos, myList: list, rows: rows)
        #endif
    }

    private struct SectionData {
        let section: PlexDirectory
        let recent: [PlexItem]
        let topRated: [PlexItem]
        let sample: [PlexItem]
    }

    /// Top 10 the profile hasn't watched, by Plex rating nudged towards the profile's taste.
    private static func topRated(_ items: [PlexItem], affinity: [String: Double]) -> [PlexItem] {
        let maxAffinity = max(affinity.values.max() ?? 0, 1)
        var seen = Set<String>()
        let rated = items.compactMap { item -> (PlexItem, Double)? in
            guard !item.isWatched, seen.insert(item.ratingKey).inserted,
                  let score = item.audienceRating ?? item.rating, score > 0 else { return nil }
            let taste = UserFeed.score(item, affinity: affinity) / maxAffinity
            return (item, score + min(taste, 2))
        }
        return Array(rated.sorted { $0.1 > $1.1 }.map(\.0).prefix(10))
    }

    /// One row per main genre (the focus genres when chosen), the profile's favourites first.
    private static func genreRows(_ sample: [PlexItem], focus: Set<String>, affinity: [String: Double],
                                  maxRows: Int = 6, minItems: Int = 6) -> [Row] {
        var counts: [String: Int] = [:]
        for item in sample {
            for genre in Set(item.genres.map(\.tag)) { counts[genre, default: 0] += 1 }
        }
        let eligible = counts.filter { genre, count in
            focus.isEmpty ? count >= minItems : (focus.contains(genre.lowercased()) && count >= 3)
        }
        let topGenres = eligible
            .sorted { a, b in
                let wa = affinity[a.key.lowercased()] ?? 0, wb = affinity[b.key.lowercased()] ?? 0
                if wa != wb { return wa > wb }
                return a.value != b.value ? a.value > b.value : a.key < b.key
            }
            .prefix(maxRows)
            .map(\.key)
        return topGenres.map { genre in
            var seen = Set<String>()
            let items = sample.filter { item in
                item.genres.contains { $0.tag == genre } && seen.insert(item.ratingKey).inserted
            }
            return Row(id: "genre-\(genre)", title: ArabicFormat.genre(genre), items: Array(items.prefix(20)))
        }
    }

    /// Clear logos for the Continue Watching cards (the show's logo for episodes).
    private static func logos(for deck: [PlexItem], known: [FeaturedItem], client: PlexServerClient) async -> [String: String] {
        var byOwner: [String: String] = [:]
        for f in known { if let logo = f.display.clearLogoPath { byOwner[f.display.ratingKey] = logo } }
        let owners = Set(deck.map { $0.grandparentRatingKey ?? $0.ratingKey }).subtracting(byOwner.keys)
        await withTaskGroup(of: (String, String?).self) { group in
            for key in owners {
                group.addTask { (key, await client.cachedMetadata(key)?.clearLogoPath) }
            }
            for await (key, logo) in group { if let logo { byOwner[key] = logo } }
        }
        var result: [String: String] = [:]
        for item in deck {
            if let logo = byOwner[item.grandparentRatingKey ?? item.ratingKey] { result[item.ratingKey] = logo }
        }
        return result
    }
}
