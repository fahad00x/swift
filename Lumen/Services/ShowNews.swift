import Foundation

/// `ShowNewsRule` for the shows on «قائمتي» and the ones the profile is following.
@MainActor
@Observable
final class ShowNews {
    struct Info: Equatable, Sendable {
        var badge: ShowNewsRule.Badge?
        var progress: Double?
        var newest: TimeInterval
        /// The oldest unwatched episode.
        var episode: PlexItem?

        var title: String? {
            switch badge {
            case .episode: return "حلقة جديدة"
            case .season: return "موسم جديد"
            case nil: return nil
            }
        }
    }

    /// By show.
    private(set) var info: [String: Info] = [:]
    @ObservationIgnored private var work: Task<Void, Never>?

    /// The show of an item (an episode's own, a show itself).
    static func key(_ item: PlexItem) -> String? {
        item.isShow ? item.ratingKey : (item.isEpisode ? item.grandparentRatingKey : nil)
    }

    func of(_ item: PlexItem) -> Info? { Self.key(item).flatMap { info[$0] } }

    /// Shows of «قائمتي» with something new.
    func count(in store: ProfileStore) -> Int {
        store.myList.filter { info[$0.ratingKey]?.badge != nil }.count
    }

    func refresh(client: PlexServerClient, store: ProfileStore) {
        work?.cancel()
        work = Task {
            // Several changes at once (a library refresh, a playback's end): one look.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let touched = store.activeStates.filter { $0.type == "episode" && ($0.watched || $0.offsetMs > 10_000) }
            let byShow = Dictionary(grouping: touched.filter { $0.showKey != nil }, by: { $0.showKey! })
            // Not started: nothing to say about it. The most recently watched ones.
            let listed = Set(store.myList.filter { $0.type == "show" }.map(\.ratingKey))
            let recent = byShow.mapValues { $0.map(\.lastViewedAt).max() ?? .distantPast }
                .sorted { $0.value > $1.value }.prefix(60).map(\.key)
            let shows = Set(recent).union(listed).filter { byShow[$0] != nil }

            var found: [String: Info] = [:]
            await withTaskGroup(of: (String, Info).self) { group in
                for (i, show) in shows.enumerated() {
                    if i >= 4, let (key, value) = await group.next() { found[key] = value }
                    let states = Dictionary((byShow[show] ?? []).map { ($0.ratingKey, $0) }, uniquingKeysWith: { a, _ in a })
                    group.addTask { (show, await Self.look(at: show, states: states, client: client)) }
                }
                for await (key, value) in group { found[key] = value }
            }
            guard !Task.isCancelled, info != found else { return }
            info = found
        }
    }

    nonisolated private static func look(at show: String, states: [String: MediaState], client: PlexServerClient) async -> Info {
        let episodes = await client.allLeaves(show).filter { $0.parentIndex != 0 }
            .sorted { (($0.parentIndex ?? 0), ($0.index ?? 0)) < (($1.parentIndex ?? 0), ($1.index ?? 0)) }
        let rule = ShowNewsRule(episodes.map { episode in
            let state = states[episode.ratingKey]
            let watched = state?.watched ?? false
            let started = !watched && (state?.offsetMs ?? 0) > 10_000
            let duration = (state?.durationMs ?? 0) > 0 ? state!.durationMs : (episode.duration ?? 0)
            return .init(season: episode.parentIndex ?? 0, index: episode.index ?? 0, added: Double(episode.addedAt ?? 0),
                         watched: watched,
                         progress: started ? (duration > 0 ? min(1, Double(state!.offsetMs) / Double(duration)) : 0.02) : nil,
                         lastViewed: state?.lastViewedAt)
        })
        return Info(badge: rule.badge, progress: rule.progress, newest: rule.newest, episode: rule.next.map { episodes[$0] })
    }
}
