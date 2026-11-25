import SwiftUI

extension Array where Element == PlexItem {
    /// The same title from several libraries (4K and 1080p copies share Plex's guid) once per
    /// row: the copy the profile started, else the one it watched, else the best quality.
    /// Keeps the first copy's place. Titles Plex hasn't matched are never merged.
    @MainActor
    func mergingCopies(_ store: ProfileStore) -> [PlexItem] {
        var order: [String] = []
        var best: [String: PlexItem] = [:]
        for item in uniqued() {
            let key = item.copyKey ?? item.ratingKey
            guard let current = best[key] else {
                order.append(key)
                best[key] = item
                continue
            }
            if current.copyRank(store).lexicographicallyPrecedes(item.copyRank(store)) {
                best[key] = item
            }
        }
        return order.compactMap { best[$0] }
    }
}

private extension PlexItem {
    var copyKey: String? {
        guard ["movie", "show", "season", "episode"].contains(type),
              let guid, guid.hasPrefix("plex://") else { return nil }
        return guid
    }

    /// Compared in order: started, watched (episodes for a show), resolution.
    @MainActor
    func copyRank(_ store: ProfileStore) -> [Int] {
        let started = store.progress(of: self) != nil ? 1 : 0
        let watched = isShow || isSeason
            ? store.watchedEpisodeCount(under: ratingKey)
            : (store.state(for: ratingKey)?.watched == true ? 1 : 0)
        let resolution = media.map { media -> Int in
            guard let value = media.videoResolution?.lowercased() else { return 0 }
            return value == "4k" ? 2160 : (Int(value) ?? 1)
        }.max() ?? 0
        return [started, watched, resolution]
    }
}
