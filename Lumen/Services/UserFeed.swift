import Foundation

/// Home content built from the active profile's own history (never from Plex's shared onDeck).
@MainActor
enum UserFeed {
    /// In-progress items, then the next episode of shows the profile is following; newest first.
    static func continueWatching(store: ProfileStore, client: PlexServerClient, filter: ContentFilter,
                                 limit: Int = 20) async -> [PlexItem] {
        let states = store.activeStates
        let inProgress = states
            .filter { !$0.watched && $0.offsetMs > 10_000 && ($0.progress ?? 0) < 0.95 }
            .sorted { $0.lastViewedAt > $1.lastViewedAt }
            .prefix(limit)
        let showsInProgress = Set(inProgress.compactMap(\.showKey))

        // Latest watched episode of each other show → its next unwatched episode.
        var latest: [String: MediaState] = [:]
        for state in states where state.watched && state.type == "episode" {
            guard let show = state.showKey, !showsInProgress.contains(show) else { continue }
            if let current = latest[show] {
                let newer = state.lastViewedAt > current.lastViewedAt
                    || (state.lastViewedAt == current.lastViewedAt && (state.sortIndex ?? 0) > (current.sortIndex ?? 0))
                if newer { latest[show] = state }
            } else {
                latest[show] = state
            }
        }
        let following = latest.values.sorted { $0.lastViewedAt > $1.lastViewedAt }.prefix(12)

        var found: [(Date, PlexItem)] = []
        await withTaskGroup(of: (Date, PlexItem?).self) { group in
            for state in inProgress {
                group.addTask { (state.lastViewedAt, await client.item(state.ratingKey)) }
            }
            for state in following {
                guard let show = state.showKey else { continue }
                group.addTask { (state.lastViewedAt, await client.nextUnwatched(showKey: show, after: state.ratingKey)) }
            }
            for await (date, item) in group { if let item { found.append((date, item)) } }
        }
        var seen = Set<String>()
        let ordered = found.sorted { $0.0 > $1.0 }.map(\.1).filter { seen.insert($0.ratingKey).inserted }
        return Array(await filter.resolve(ordered, client: client).prefix(limit))
    }

    /// "قائمتي", newest first.
    static func myList(store: ProfileStore, client: PlexServerClient, filter: ContentFilter) async -> [PlexItem] {
        let entries = Array(store.myList.prefix(60))
        var items: [Int: PlexItem] = [:]
        await withTaskGroup(of: (Int, PlexItem?).self) { group in
            for (i, entry) in entries.enumerated() {
                group.addTask { (i, await client.item(entry.ratingKey)) }
            }
            for await (i, item) in group { if let item { items[i] = item } }
        }
        let ordered = items.sorted { $0.key < $1.key }.map(\.value)
        return await filter.resolve(ordered, client: client)
    }

    /// Genre → weight from what the profile watched (recent viewing counts more).
    static func genreAffinity(store: ProfileStore) -> [String: Double] {
        var weights: [String: Double] = [:]
        let now = Date()
        for state in store.activeStates where state.watched || state.offsetMs > 60_000 {
            let days = max(0, now.timeIntervalSince(state.lastViewedAt) / 86_400)
            let weight = 1 / (1 + days / 30)
            for genre in state.genres { weights[genre.lowercased(), default: 0] += weight }
        }
        return weights
    }

    nonisolated static func score(_ item: PlexItem, affinity: [String: Double]) -> Double {
        item.genres.reduce(0) { $0 + (affinity[$1.tag.lowercased()] ?? 0) }
    }
}

/// First run with profiles: copies what was already watched in Lumen (Plex progress, watched
/// marks and watchlist of the shared account) to the default profile.
enum ProfileMigration {
    @MainActor
    static func run(client: PlexServerClient, sections: [PlexDirectory], store: ProfileStore, into profileID: String) async {
        var imported: [ProfileStore.ImportedState] = []
        await withTaskGroup(of: [PlexItem].self) { group in
            for section in sections {
                group.addTask { await client.importableHistory(section: section) }
            }
            for await items in group {
                for item in items {
                    let watched = (item.viewCount ?? 0) > 0
                    let date = item.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date.distantPast
                    imported.append(.init(info: item.mediaInfo, offsetMs: watched ? 0 : (item.viewOffset ?? 0),
                                          watched: watched, lastViewedAt: date))
                }
            }
        }
        let watchlist = await client.importableWatchlist().map(\.mediaInfo)
        store.importExisting(imported, myList: watchlist, into: profileID)
    }
}
