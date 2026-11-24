import Foundation

/// Seasons and every episode of a show in two parallel requests (`children` + `allLeaves`)
/// instead of one request per season, so the episode list appears right away.
/// Shared by the Apple TV and iPhone details pages.
struct ShowEpisodes {
    var seasons: [PlexItem]
    var bySeason: [String: [PlexItem]]
    /// Episode the Play button starts: `preferred`, else in progress, else first unwatched, else the first.
    var playTarget: PlexItem?

    static func load(client: PlexServerClient, showKey: String, preferred: PlexItem?) async -> ShowEpisodes {
        async let seasonsTask = client.children(showKey)
        async let leavesTask = client.allLeaves(showKey)
        let seasons = ((try? await seasonsTask) ?? []).filter(\.isSeason).uniqued()
        let leaves = (await leavesTask).uniqued()
        var bySeason: [String: [PlexItem]] = [:]
        for episode in leaves {
            bySeason[episode.parentRatingKey ?? "", default: []].append(episode)
        }
        let target = preferred
            ?? next(in: leaves)
        return ShowEpisodes(seasons: seasons, bySeason: bySeason, playTarget: target)
    }

    /// In progress, else the first unwatched, else the first; specials (season 0, which Plex
    /// may list first) only after the regular episodes.
    static func next(in leaves: [PlexItem]) -> PlexItem? {
        let ordered = leaves.filter { $0.parentIndex != 0 } + leaves.filter { $0.parentIndex == 0 }
        return ordered.first { $0.progress != nil && !$0.isWatched }
            ?? ordered.first { !$0.isWatched }
            ?? ordered.first
    }
}
