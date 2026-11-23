import Foundation

/// One slide of the home hero carousel.
struct FeaturedItem: Identifiable, Equatable, Codable {
    enum Reason: String, Codable {
        case resume, upNext, newEpisode, newSeason, recentlyAdded
    }

    let reason: Reason
    /// Movie or show metadata: artwork, logo, summary, genres.
    let display: PlexItem
    /// What the Play button starts (movie or episode). nil for a show → resolved lazily.
    let playable: PlexItem?

    var id: String { display.ratingKey }

    static func == (lhs: FeaturedItem, rhs: FeaturedItem) -> Bool {
        lhs.id == rhs.id && lhs.playable?.ratingKey == rhs.playable?.ratingKey
            && lhs.playable?.viewOffset == rhs.playable?.viewOffset
    }

    var eyebrow: String {
        let base: String
        switch reason {
        case .resume: base = "لم تكمله"
        case .upNext: base = "الحلقة التالية"
        case .newEpisode: base = "حلقة جديدة"
        case .newSeason: base = "موسم جديد"
        case .recentlyAdded: base = "أضيف مؤخراً"
        }
        if let code = playable?.episodeCode { return "\(base) · \(code)" }
        return base
    }
}

enum FeaturedBuilder {
    /// Picks up to `limit` slides: what you're watching first, then new arrivals across libraries.
    static func build(client: PlexServerClient, onDeck: [PlexItem], recent: [[PlexItem]], limit: Int = 8) async -> [FeaturedItem] {
        struct Candidate {
            let reason: FeaturedItem.Reason
            let displayKey: String
            let playable: PlexItem?
        }

        var candidates: [Candidate] = []
        var seen = Set<String>()
        func add(_ reason: FeaturedItem.Reason, _ key: String?, _ playable: PlexItem?) {
            guard let key, seen.insert(key).inserted else { return }
            candidates.append(Candidate(reason: reason, displayKey: key, playable: playable))
        }

        for item in onDeck.prefix(3) {
            let reason: FeaturedItem.Reason = item.progress != nil ? .resume : .upNext
            if item.isEpisode {
                add(reason, item.grandparentRatingKey, item)
            } else if item.type == "movie" {
                add(.resume, item.ratingKey, item)
            }
        }

        // Round-robin across libraries so one library doesn't take every slide.
        let longest = recent.map(\.count).max() ?? 0
        outer: for i in 0..<longest {
            for list in recent where i < list.count {
                let item = list[i]
                switch item.type {
                case "movie" where !item.isWatched: add(.recentlyAdded, item.ratingKey, item)
                case "show": add(.recentlyAdded, item.ratingKey, nil)
                case "season": add(.newSeason, item.parentRatingKey, nil)
                case "episode": add(.newEpisode, item.grandparentRatingKey, item)
                default: break
                }
                // A few spares in case some have no artwork.
                if candidates.count >= limit + 4 { break outer }
            }
        }

        // Full metadata gives us the clear logo, genres, content rating and stream info (HDR/DV).
        let resolved = await withTaskGroup(of: (Int, FeaturedItem?).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    guard let display = try? await client.metadata(candidate.displayKey),
                          display.backdropPath != nil
                    else { return (index, nil) }
                    var playable = candidate.playable
                    if let p = playable {
                        playable = p.ratingKey == display.ratingKey ? display : ((try? await client.metadata(p.ratingKey)) ?? p)
                    }
                    return (index, FeaturedItem(reason: candidate.reason, display: display, playable: playable))
                }
            }
            var out: [(Int, FeaturedItem?)] = []
            for await result in group { out.append(result) }
            return out
        }
        return Array(resolved.sorted { $0.0 < $1.0 }.compactMap(\.1).prefix(limit))
    }
}
