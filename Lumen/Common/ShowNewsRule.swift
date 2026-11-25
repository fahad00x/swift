import Foundation

/// What a show's poster says: «حلقة جديدة» / «موسم جديد» only when the profile had finished
/// everything out and something came after; a bar while it's in the middle of an episode.
struct ShowNewsRule {
    struct Episode {
        var season: Int
        var index: Int
        var added: TimeInterval
        var watched: Bool
        /// 0…1 of an unwatched episode that was started.
        var progress: Double?
        var lastViewed: Date?
    }

    enum Badge: Equatable { case episode, season }

    var badge: Badge?
    var progress: Double?
    /// When the newest episode came (the badge's order).
    var newest: TimeInterval = 0
    /// Place of the oldest unwatched episode among the regular ones, in order.
    var next: Int?

    static let window: TimeInterval = 7 * 86_400

    /// `episodes`: the regular ones (no specials), in order.
    init(_ episodes: [Episode], now: Date = Date()) {
        // Stopped in its last moments: done.
        func done(_ e: Episode) -> Bool { e.watched || (e.progress ?? 0) >= 0.95 }
        // In the middle of an episode: its bar and nothing else.
        if let current = episodes.filter({ !done($0) && $0.progress != nil })
            .max(by: { ($0.lastViewed ?? .distantPast) < ($1.lastViewed ?? .distantPast) }) {
            progress = current.progress
            next = episodes.firstIndex { !done($0) }
            return
        }
        let finished = episodes.filter(done)
        // Never started, or nothing left.
        guard !finished.isEmpty, let first = episodes.firstIndex(where: { !done($0) }) else { return }
        next = first
        let left = episodes.filter { !done($0) }
        // Everything left came after the last one was watched: it was all finished then. (No
        // real date: marked on Plex by hand, nothing can be said.)
        guard let last = finished.compactMap(\.lastViewed).max()?.timeIntervalSince1970, last > 86_400,
              left.allSatisfy({ $0.added > last }) else { return }
        newest = left.map(\.added).max() ?? 0
        guard now.timeIntervalSince1970 - newest < Self.window else { return }
        badge = episodes[first].season > (finished.map(\.season).max() ?? 0) ? .season : .episode
    }
}
