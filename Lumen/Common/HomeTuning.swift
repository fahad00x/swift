import Foundation

/// Every number that shapes Home, in one place, so tuning is a one-line change.
/// The hidden screen in Settings (tap «الإصدار» five times) shows what these produce.
enum HomeTuning {
    // MARK: Taste (genre affinity)

    /// Progress (ms) before an unfinished item counts towards the profile's taste.
    static let tasteMinOffsetMs = 60_000
    /// «نوع لا يناسبني»: taken off each of the title's genres (at least; more for a recent one).
    static let dislikedGenrePenalty = 0.5
    /// A liked / loved title the profile hasn't watched: per genre, before its rating factor.
    static let ratedUnwatchedWeight = 0.5
    /// Recency: weight = 1 / (1 + days / recencyDays).
    static let recencyDays = 30.0
    /// Show engagement: min(cap, 1 + ln(1 + watched episodes) / divisor).
    static let showEngagementCap = 2.0
    static let showEngagementDivisor = 3.0
    /// A finished movie counts a bit more than one that is only started.
    static let finishedMovieEngagement = 1.2
    /// An abandoned title: nothing finished and untouched for `abandonedAfterDays` —
    /// a movie stopped before `abandonedMovieProgress`, or a show with a single unfinished episode.
    static let abandonedEngagement = 0.4
    static let abandonedMovieProgress = 0.25
    static let abandonedAfterDays = 3.0
    /// Titles without genres in the profile's data (episodes: Plex keeps genres on the show)
    /// get them from the server; the most recent ones first, at most this many per build.
    static let tasteMetadataLookups = 40
}
