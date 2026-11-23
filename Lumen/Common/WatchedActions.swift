import Foundation

/// «تحديد كمشاهَد» for the active profile only (nothing is sent to Plex).
@MainActor
enum WatchedActions {
    /// Marks a movie / episode, or every episode of a show or season.
    static func setWatched(_ target: PlexItem, _ watched: Bool, client: PlexServerClient, store: ProfileStore) async {
        let infos: [MediaInfo]
        if target.isShow {
            infos = await client.allLeaves(target.ratingKey).map(\.mediaInfo)
        } else if target.isSeason {
            infos = ((try? await client.children(target.ratingKey)) ?? []).filter(\.isEpisode).map(\.mediaInfo)
        } else {
            infos = [target.mediaInfo]
        }
        store.setWatched(infos, watched: watched)
        NotificationCenter.default.post(name: .plexPlaybackDidEnd, object: nil)
    }
}
