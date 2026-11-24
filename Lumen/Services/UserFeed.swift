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

    /// Genres of titles whose own data has none (episodes: Plex keeps genres on the show),
    /// learned from the server by `taste(store:client:)` and reused by the synchronous version.
    private static var learnedGenres: [String: [String]] = [:]

    /// Genre → weight (see `taste(store:)`), for callers that can't wait for the server.
    static func genreAffinity(store: ProfileStore) -> [String: Double] {
        taste(store: store).weights
    }

    /// `taste(store:)` after asking the server for the genres of the most recent titles that
    /// have none (cached per session and on disk).
    static func taste(store: ProfileStore, client: PlexServerClient) async -> TasteProfile {
        let missing = taste(store: store).titles
            .filter { $0.genres.isEmpty && learnedGenres[$0.key] == nil }
            .sorted { $0.lastViewedAt > $1.lastViewedAt }
            .prefix(HomeTuning.tasteMetadataLookups)
            .map(\.key)
        if !missing.isEmpty {
            let found: [(String, [String])] = await withTaskGroup(of: (String, [String]).self) { group in
                for key in missing {
                    group.addTask {
                        let item = await client.cachedMetadata(key)
                        return (key, item?.genres.map { $0.tag.lowercased() } ?? [])
                    }
                }
                var out: [(String, [String])] = []
                for await result in group { out.append(result) }
                return out
            }
            for (key, genres) in found where !genres.isEmpty { learnedGenres[key] = genres }
        }
        return taste(store: store)
    }

    /// Genre → weight from what the profile watched, one entry per title (movie or show):
    /// recency × engagement. Episodes count towards their show.
    static func taste(store: ProfileStore) -> TasteProfile {
        struct Group {
            var type: String
            var genres: Set<String> = []
            var lastViewedAt = Date.distantPast
            var watched = 0
            var touched = 0
            var bestProgress = 0.0
        }

        var groups: [String: Group] = [:]
        for state in store.activeStates where state.watched || state.offsetMs > HomeTuning.tasteMinOffsetMs {
            let isEpisode = state.type == "episode"
            let key = isEpisode ? (state.showKey ?? state.ratingKey) : state.ratingKey
            var group = groups[key] ?? Group(type: isEpisode ? "show" : state.type)
            group.genres.formUnion(state.genres.map { $0.lowercased() })
            group.lastViewedAt = max(group.lastViewedAt, state.lastViewedAt)
            group.touched += 1
            if state.watched { group.watched += 1 }
            group.bestProgress = max(group.bestProgress, state.watched ? 1 : (state.progress ?? 0))
            groups[key] = group
        }

        let now = Date()
        var titles: [TasteProfile.Title] = []
        var weights: [String: Double] = [:]
        for (key, group) in groups {
            let genres = group.genres.isEmpty ? Set(learnedGenres[key] ?? []) : group.genres
            let days = max(0, now.timeIntervalSince(group.lastViewedAt) / 86_400)
            let recency = 1 / (1 + days / HomeTuning.recencyDays)
            let stale = days > HomeTuning.abandonedAfterDays
            let abandoned: Bool
            let engagement: Double
            if group.type == "show" {
                abandoned = stale && group.watched == 0 && group.touched <= 1
                engagement = abandoned
                    ? HomeTuning.abandonedEngagement
                    : min(HomeTuning.showEngagementCap,
                          1 + log(1 + Double(group.watched)) / HomeTuning.showEngagementDivisor)
            } else {
                abandoned = stale && group.watched == 0 && group.bestProgress < HomeTuning.abandonedMovieProgress
                engagement = group.watched > 0
                    ? HomeTuning.finishedMovieEngagement
                    : (abandoned ? HomeTuning.abandonedEngagement : 1)
            }
            let title = TasteProfile.Title(key: key, type: group.type, genres: genres.sorted(),
                                           lastViewedAt: group.lastViewedAt, watchedCount: group.watched,
                                           abandoned: abandoned, recency: recency, engagement: engagement)
            titles.append(title)
            for genre in genres { weights[genre, default: 0] += title.weight }
        }
        titles.sort { $0.weight != $1.weight ? $0.weight > $1.weight : $0.key < $1.key }
        return TasteProfile(titles: titles, weights: weights)
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
