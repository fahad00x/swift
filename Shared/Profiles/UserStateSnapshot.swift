import Foundation

/// Thread-safe, read-only view of the active profile's progress and watched marks.
/// Networking code (off the main actor) reads it to overlay each item fetched from the
/// server, so every screen shows this profile's data instead of the shared Plex values.
final class UserStateSnapshot: @unchecked Sendable {
    struct Entry: Sendable {
        let offsetMs: Int
        let watched: Bool
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Show / season ratingKey → number of its episodes this profile watched.
    private var watchedChildren: [String: Int] = [:]

    func replace(with states: [MediaState]) {
        var newEntries: [String: Entry] = [:]
        var counts: [String: Int] = [:]
        newEntries.reserveCapacity(states.count)
        for state in states {
            newEntries[state.ratingKey] = Entry(offsetMs: state.offsetMs, watched: state.watched)
            guard state.watched, state.type == "episode" else { continue }
            if let show = state.showKey { counts[show, default: 0] += 1 }
            if let season = state.seasonKey { counts[season, default: 0] += 1 }
        }
        lock.withLock {
            entries = newEntries
            watchedChildren = counts
        }
    }

    func entry(for ratingKey: String) -> Entry? {
        lock.withLock { entries[ratingKey] }
    }

    func watchedCount(under parentKey: String) -> Int {
        lock.withLock { watchedChildren[parentKey] ?? 0 }
    }
}
