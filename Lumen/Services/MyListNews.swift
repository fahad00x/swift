import Foundation

/// New episodes of the shows on «قائمتي»: unwatched, added in the last two weeks, of a show the
/// profile started (or added since it put the show on the list). Specials don't count.
@MainActor
@Observable
final class MyListNews {
    /// Show → how many.
    private(set) var counts: [String: Int] = [:]
    @ObservationIgnored private var work: Task<Void, Never>?

    static let window: TimeInterval = 14 * 86_400

    func refresh(client: PlexServerClient, store: ProfileStore) {
        work?.cancel()
        work = Task {
            // Several changes at once (a library refresh, a playback's end): one look.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let started = Set(store.activeStates.filter { $0.watched || $0.offsetMs > 10_000 }.compactMap(\.showKey))
            let shows = store.myList.filter { $0.type == "show" }
            let oldest = Date().addingTimeInterval(-Self.window).timeIntervalSince1970
            var found: [String: Int] = [:]
            await withTaskGroup(of: (String, Int).self) { group in
                for (i, entry) in shows.enumerated() {
                    if i >= 6, let (key, count) = await group.next() { found[key] = count }
                    let since = started.contains(entry.ratingKey) ? oldest : max(oldest, entry.addedAt.timeIntervalSince1970)
                    group.addTask {
                        let new = await client.allLeaves(entry.ratingKey).filter {
                            $0.parentIndex != 0 && !$0.isWatched && Double($0.addedAt ?? 0) >= since
                        }
                        return (entry.ratingKey, new.count)
                    }
                }
                for await (key, count) in group { found[key] = count }
            }
            guard !Task.isCancelled else { return }
            counts = found.filter { $0.value > 0 }
        }
    }

    static func title(_ count: Int) -> String {
        switch count {
        case 1: return "حلقة جديدة"
        case 2: return "حلقتان جديدتان"
        case 3...10: return "\(ArabicFormat.digits(count)) حلقات جديدة"
        default: return "\(ArabicFormat.digits(count)) حلقة جديدة"
        }
    }
}
