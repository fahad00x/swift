import Foundation

// Rating a show or movie («نوع لا يناسبني / أعجبني / من النوع الذي أحبه!»): kept with the profile
// (iCloud), so every profile has its own; it shapes the profile's taste (`UserFeed.taste`). Sent to
// the Plex server too only when the account's own profile turned it on in Settings.

extension PlexItem {
    /// What a rating belongs to: an episode's or season's show, else the item itself.
    var ratingKeyForRating: String {
        if isEpisode { return grandparentRatingKey ?? ratingKey }
        if isSeason { return parentRatingKey ?? ratingKey }
        return ratingKey
    }
}

@MainActor
enum TitleRatings {
    static func rating(of item: PlexItem, store: ProfileStore) -> TitleRating? {
        store.rating(of: item.ratingKeyForRating)
    }

    /// Chooses `rating`, or clears it when it is the one already chosen (a second tap).
    static func toggle(_ rating: TitleRating, for item: PlexItem, client: PlexServerClient, store: ProfileStore) {
        let key = item.ratingKeyForRating
        let new: TitleRating? = store.rating(of: key) == rating ? nil : rating
        store.setRating(new, for: key)
        if new == .dislike { NotificationCenter.default.post(name: .plexPlaybackDidEnd, object: nil) }
        if store.activeProfile?.isOwner == true, store.activeProfile?.settings?.ratingsToPlex == true {
            Task { await client.rate(key, rating: new?.plexValue) }
        }
    }
}

extension PlexServerClient {
    /// The account's rating out of 10 on the server (Plex: 2 thumbs down, 8 up, 10 love);
    /// nil clears it.
    func rate(_ ratingKey: String, rating: Int?) async {
        guard let url = url("/:/rate", [("key", ratingKey), ("identifier", "com.plexapp.plugins.library"),
                                         ("rating", "\(rating ?? -1)")]) else { return }
        _ = try? await PlexHTTP.data(for: PlexHTTP.request(url, method: "PUT", token: token))
    }
}
