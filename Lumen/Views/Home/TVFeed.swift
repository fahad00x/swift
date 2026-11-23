import SwiftUI

// Apple TV Home and library pages: the banner slides and the rows, per profile and per library.
// Plex is only the data source. Everything personal (Continue Watching, recently watched,
// "because you watched", genre rows, the banner's priorities) comes from the active profile's
// own MediaState, never from Plex's history of the shared account, so one profile never sees
// another's recommendations. Generic server hubs (recently added, top rated…) are merged in.

/// One banner slide.
struct BannerItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case newEpisodes
        case newSeason(Int)
        case recentlyAdded(thisWeek: Bool)
        case topRated
    }

    let kind: Kind
    /// Movie or show, with full metadata (logo, genres, summary, ratings, streams).
    let display: PlexItem
    /// Library the title is in (for «الأعلى تقييمًا في …»).
    let libraryTitle: String

    var id: String { display.ratingKey }

    static func == (lhs: BannerItem, rhs: BannerItem) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind
    }

    /// Small label above the logo.
    var label: String {
        switch kind {
        case .newEpisodes: return "جديد"
        case .newSeason: return "موسم جديد"
        case .recentlyAdded(let thisWeek): return thisWeek ? "أضيف هذا الأسبوع" : "جديد"
        case .topRated: return "الأعلى تقييمًا"
        }
    }

    /// Bold line under the description.
    var highlight: String? {
        switch kind {
        case .newEpisodes: return "حلقات جديدة متوفرة الآن"
        case .newSeason(let n): return "الموسم \(ArabicFormat.digits(n)) متوفر الآن"
        case .recentlyAdded: return nil
        case .topRated: return "الأعلى تقييمًا في " + ArabicFormat.isolated(libraryTitle)
        }
    }
}

/// Navigation to a plain listing (a collection, a playlist, a category of a library).
struct BrowseRoute: Hashable {
    let title: String
    let path: String
    var query: [String: String] = [:]
}

@MainActor
enum TVFeed {
    // MARK: Banner

    /// 6–8 slides for the profile, in priority order: new episodes / seasons of shows it
    /// watches, then recently added titles matching its top genres, then top-rated titles it
    /// hasn't watched. Finished titles are skipped.
    static func banner(client: PlexServerClient, store: ProfileStore, filter: ContentFilter,
                       sections: [PlexDirectory], limit: Int = 8) async -> [BannerItem] {
        struct Candidate {
            let kind: BannerItem.Kind
            let item: PlexItem
            let library: String
        }

        // Shows this profile watches → highest season it reached.
        var watchedShows: [String: Int] = [:]
        for state in store.activeStates where state.type == "episode" && (state.watched || state.offsetMs > 60_000) {
            guard let show = state.showKey else { continue }
            watchedShows[show] = max(watchedShows[show] ?? 0, (state.sortIndex ?? 0) / 10_000)
        }
        let affinity = UserFeed.genreAffinity(store: store)

        let lists: [(index: Int, section: PlexDirectory, recent: [PlexItem], top: [PlexItem])] =
            await withTaskGroup(of: (Int, PlexDirectory, [PlexItem], [PlexItem]).self) { group in
                for (i, section) in sections.enumerated() {
                    group.addTask {
                        async let recent = client.recentlyAdded(section: section, limit: 60)
                        async let top = client.items(section: section, sort: .rating, start: 0, size: 40)
                        return (i, section, (try? await recent) ?? [], (try? await top)?.items ?? [])
                    }
                }
                var out: [(index: Int, section: PlexDirectory, recent: [PlexItem], top: [PlexItem])] = []
                for await r in group { out.append((r.0, r.1, r.2, r.3)) }
                return out.sorted { $0.index < $1.index }
            }

        let now = Date().timeIntervalSince1970
        func recent(_ item: PlexItem, days: Double) -> Bool {
            let stamp = max(item.addedAt ?? 0, item.updatedAt ?? 0)
            return stamp > 0 && now - Double(stamp) < days * 86_400
        }
        func finished(_ item: PlexItem) -> Bool { !store.isUnwatched(item) }

        var newForYou: [Candidate] = []
        var matching: [(Double, Candidate)] = []
        var otherRecent: [Candidate] = []
        var topRated: [Candidate] = []
        for list in lists {
            for item in list.recent where item.isShow || item.type == "movie" {
                guard !finished(item) else { continue }
                if item.isShow, let reached = watchedShows[item.ratingKey] {
                    guard recent(item, days: 45) else { continue }
                    if let seasons = item.childCount, reached > 0, seasons > reached {
                        newForYou.append(Candidate(kind: .newSeason(seasons), item: item, library: list.section.title))
                    } else {
                        newForYou.append(Candidate(kind: .newEpisodes, item: item, library: list.section.title))
                    }
                } else if store.progress(of: item) == nil {
                    let candidate = Candidate(kind: .recentlyAdded(thisWeek: recent(item, days: 7)), item: item,
                                              library: list.section.title)
                    let score = UserFeed.score(item, affinity: affinity)
                    if score > 0 { matching.append((score, candidate)) } else { otherRecent.append(candidate) }
                }
            }
            for item in list.top where !finished(item) && watchedShows[item.ratingKey] == nil {
                topRated.append(Candidate(kind: .topRated, item: item, library: list.section.title))
            }
        }
        // A new profile has no genres yet: recent titles count as matching.
        let recentPicks = affinity.isEmpty ? otherRecent : matching.sorted { $0.0 > $1.0 }.map(\.1)
        var ordered: [Candidate] = []
        var seen = Set<String>()
        for c in newForYou + recentPicks + topRated + (affinity.isEmpty ? [] : otherRecent)
        where seen.insert(c.item.ratingKey).inserted {
            ordered.append(c)
        }

        // Only what the profile may see (libraries, kids ratings).
        let allowed = Set(await filter.resolve(ordered.prefix(limit * 3).map(\.item), client: client).map(\.ratingKey))
        let picks = Array(ordered.filter { allowed.contains($0.item.ratingKey) }.prefix(limit + 4))

        // Full metadata: clear logo, genres, ratings, summary, streams.
        let resolved: [(Int, BannerItem)] = await withTaskGroup(of: (Int, BannerItem?).self) { group in
            for (i, c) in picks.enumerated() {
                group.addTask {
                    guard let full = try? await client.metadata(c.item.ratingKey), full.backdropPath != nil else { return (i, nil) }
                    return (i, BannerItem(kind: c.kind, display: full, libraryTitle: c.library))
                }
            }
            var out: [(Int, BannerItem)] = []
            for await (i, item) in group { if let item { out.append((i, item)) } }
            return out
        }
        return Array(resolved.sorted { $0.0 < $1.0 }.map(\.1).prefix(limit))
    }

    // MARK: Rows

    /// Rows for Home (`section` nil: every enabled library) or one library: Plex's hubs in the
    /// server's order with Arabic titles, merged with the profile's own rows.
    static func rows(client: PlexServerClient, store: ProfileStore, filter: ContentFilter,
                     section: PlexDirectory?) async -> [Shelf] {
        let scope = section.flatMap { s in filter.scopes.first { $0.section.key == s.key } }
        let sectionTitles = Dictionary(filter.sections.map { ($0.key, $0.title) }, uniquingKeysWith: { a, _ in a })

        async let hubsTask = client.hubs(section: section?.key)
        async let continueTask = UserFeed.continueWatching(store: store, client: client, filter: filter)
        async let watchedTask = recentlyWatched(store: store, client: client, filter: filter)
        async let becauseTask = becauseYouWatched(store: store, client: client, filter: filter, section: section)

        func inSection(_ items: [PlexItem]) -> [PlexItem] {
            guard let section else { return items }
            return items.filter { $0.librarySectionID == nil || $0.librarySectionID == section.key }
        }

        // Generic server hubs (not the shared account's history).
        var serverRows: [Shelf] = []
        for hub in await hubsTask where !isPersonal(hub) {
            let browsable = hub.items.filter { ["movie", "show", "season", "episode", "collection", "playlist"].contains($0.type) }
            guard !browsable.isEmpty else { continue }
            let plain = browsable.filter { $0.type != "collection" && $0.type != "playlist" }
            // Collections / playlists with artwork only (no grey placeholders).
            let containers = browsable.filter { ($0.type == "collection" || $0.type == "playlist") && $0.posterPath != nil }
            let visible = await filter.resolve(plain, client: client, scope: scope)
            let items = visible + containers
            guard !items.isEmpty else { continue }
            // Second header line on Home: the library, when the title doesn't name it already.
            let rowTitle = title(for: hub, sectionTitles: sectionTitles)
            let library = section == nil
                ? items.lazy.compactMap { $0.librarySectionID.flatMap { sectionTitles[$0] } }.first
                : nil
            let subtitle = library.flatMap { rowTitle.contains($0) ? nil : ArabicFormat.isolated($0) }
            serverRows.append(Shelf(id: "hub-\(hub.hubIdentifier)", title: rowTitle,
                                    kind: .poster, items: items, subtitle: subtitle))
        }

        // The profile's own rows.
        let continueItems = inSection(await continueTask)
        let watched = inSection(await watchedTask)
        let because = await becauseTask
        let pool = serverRows.flatMap(\.items)
        let genreRows = genreRows(store: store, pool: pool)

        var rows: [Shelf] = []
        if !continueItems.isEmpty {
            // Portrait posters like every row, with the progress bar on the poster.
            rows.append(Shelf(id: "continue", title: "متابعة المشاهدة", kind: .poster, items: continueItems))
        }
        rows += serverRows.prefix(2)
        if let because { rows.append(because) }
        var rest = Array(serverRows.dropFirst(2))
        // One genre row after every two server rows.
        for row in genreRows {
            let take = min(2, rest.count)
            rows += rest.prefix(take)
            rest.removeFirst(take)
            rows.append(row)
        }
        rows += rest
        if !watched.isEmpty {
            rows.append(Shelf(id: "watched", title: "شوهدت مؤخرًا", kind: .poster, items: watched))
        }
        var seen = Set<String>()
        return rows.filter { seen.insert($0.id).inserted }
    }

    /// Hubs built from the shared Plex account's history (it belongs to whoever watched on
    /// it): replaced by the profile's own rows.
    private static func isPersonal(_ hub: PlexHub) -> Bool {
        let id = (hub.hubIdentifier + " " + (hub.context ?? "")).lowercased()
        return ["continue", "ondeck", "inprogress", "recentlyviewed", "rediscover", "watchlist", "becauseyou", "because"]
            .contains { id.contains($0) }
    }

    /// Arabic title for a Plex hub.
    static func title(for hub: PlexHub, sectionTitles: [String: String]) -> String {
        let id = (hub.hubIdentifier + " " + (hub.context ?? "")).lowercased()
        let library = hub.items.lazy.compactMap { $0.librarySectionID.flatMap { sectionTitles[$0] } }.first
        if id.contains("recentlyaired") || id.contains("recentepisodes") || (id.contains("recent") && hub.type == "episode") {
            return "حلقات نزلت مؤخرًا"
        }
        if id.contains("playlist") { return "قوائم التشغيل الأخيرة" }
        if id.contains("recentlyreleased") { return "صدر مؤخرًا" }
        if id.contains("recentlyadded") || id.contains(".recent") {
            return library.map { "أضيف مؤخرًا في " + ArabicFormat.isolated($0) } ?? "أضيف مؤخرًا"
        }
        if id.contains("toprated") || id.contains("highlyrated") || id.contains("topunwatched") { return "الأعلى تقييمًا" }
        if id.contains("startwatching") || id.contains("unwatched") { return "ابدأ المشاهدة" }
        if id.contains("recentlyviewed") { return "حلقات شوهدت مؤخرًا" }
        if id.contains("rediscover") { return "أعد الاكتشاف" }
        if id.contains("collection") { return "المجموعات" }
        if id.contains("genre") {
            // "More in Action" / "Action".
            var name = hub.title
            for prefix in ["More in ", "More "] where name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
            return "المزيد في " + ArabicFormat.isolated(ArabicFormat.genre(name))
        }
        return ArabicFormat.isolated(hub.title)
    }

    /// «شوهدت مؤخرًا»: the profile's latest finished movies and episodes.
    private static func recentlyWatched(store: ProfileStore, client: PlexServerClient,
                                        filter: ContentFilter) async -> [PlexItem] {
        let states = store.activeStates.filter(\.watched).sorted { $0.lastViewedAt > $1.lastViewedAt }
        var keys: [String] = []
        var shows = Set<String>()
        for state in states {
            // One card per show (its latest episode).
            if let show = state.showKey, !shows.insert(show).inserted { continue }
            keys.append(state.ratingKey)
            if keys.count >= 20 { break }
        }
        var found: [Int: PlexItem] = [:]
        await withTaskGroup(of: (Int, PlexItem?).self) { group in
            for (i, key) in keys.enumerated() { group.addTask { (i, await client.item(key)) } }
            for await (i, item) in group { if let item { found[i] = item } }
        }
        return await filter.resolve(found.sorted { $0.key < $1.key }.map(\.value), client: client)
    }

    /// «لأنك شاهدت <العنوان>»: related titles of the profile's latest watched movie / show.
    private static func becauseYouWatched(store: ProfileStore, client: PlexServerClient, filter: ContentFilter,
                                          section: PlexDirectory?) async -> Shelf? {
        let latest = store.activeStates
            .filter { $0.watched || $0.offsetMs > 600_000 }
            .filter { section == nil || $0.sectionKey == nil || $0.sectionKey == section?.key }
            .sorted { $0.lastViewedAt > $1.lastViewedAt }
            .first
        guard let latest else { return nil }
        let key = latest.showKey ?? latest.ratingKey
        guard let source = await client.item(key) else { return nil }
        let related = await client.related(key).filter { store.isUnwatched($0) && $0.ratingKey != key }
        let visible = await filter.resolve(related, client: client)
        guard visible.count >= 3 else { return nil }
        return Shelf(id: "because-\(key)", title: "لأنك شاهدت " + ArabicFormat.isolated(source.title),
                     kind: .poster, items: Array(visible.prefix(20)))
    }

    /// «المزيد في <النوع>» for the profile's top 2–3 genres, from the titles already on the page.
    private static func genreRows(store: ProfileStore, pool: [PlexItem]) -> [Shelf] {
        let affinity = UserFeed.genreAffinity(store: store)
        let top = affinity.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        var rows: [Shelf] = []
        var used = Set<String>()
        for genre in top {
            var seen = Set<String>()
            let items = pool.filter { item in
                (item.type == "movie" || item.isShow)
                    && item.genres.contains { $0.tag.lowercased() == genre }
                    && store.isUnwatched(item)
                    && seen.insert(item.ratingKey).inserted
            }
            guard items.count >= 4 else { continue }
            let name = items.first?.genres.first { $0.tag.lowercased() == genre }?.tag ?? genre
            guard used.insert(genre).inserted else { continue }
            rows.append(Shelf(id: "genre-\(genre)", title: "المزيد في " + ArabicFormat.isolated(ArabicFormat.genre(name)),
                              kind: .poster, items: Array(items.prefix(20))))
        }
        return rows
    }
}
