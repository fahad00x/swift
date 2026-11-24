import Foundation

/// How the active profile's viewing shapes Home: one entry per title it watched or started,
/// and the genre weights they add up to (built by `UserFeed.taste`).
struct TasteProfile: Sendable {
    struct Title: Identifiable, Sendable {
        /// Movie ratingKey, or the show's for episodes.
        let key: String
        /// "movie" or "show".
        let type: String
        /// Lowercased Plex genre tags.
        let genres: [String]
        let lastViewedAt: Date
        /// Finished episodes (show) or 0 / 1 (movie).
        let watchedCount: Int
        let abandoned: Bool
        let recency: Double
        let engagement: Double

        var weight: Double { recency * engagement }
        var id: String { key }
    }

    /// Strongest first.
    var titles: [Title] = []
    /// Lowercased genre tag → weight.
    var weights: [String: Double] = [:]
}
