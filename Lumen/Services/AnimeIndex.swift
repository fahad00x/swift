import Foundation

/// Rating and anime genres (إيسيكاي، شونين…) of anime series by their TVDB / TMDB / IMDb id,
/// from a file in the app (scripts/build_anime_index.py): no server needed.
/// Contains information from the anime-offline-database (github.com/manami-project), made
/// available under the Open Database License (ODbL) 1.0.
struct AnimeIndex: Sendable {
    struct Entry: Sendable {
        /// nil: not rated yet.
        let score: Double?
        let genres: Set<String>
    }

    private let byID: [String: Entry]
    let genres: [String]
    /// Ratings are MyAnimeList's own (else the median of several sites, close to it).
    let officialMAL: Bool

    /// Read once, off the main thread.
    static let shared = Task.detached(priority: .userInitiated) { AnimeIndex.read() }

    /// The entry of a Plex title ("tvdb://72025", …).
    func entry(_ item: PlexItem) -> Entry? {
        for kind in ["tvdb://", "tmdb://", "imdb://"] {
            for guid in item.guids where guid.hasPrefix(kind) {
                if let entry = byID[guid] { return entry }
            }
        }
        return nil
    }

    private static func read() -> AnimeIndex {
        guard let url = Bundle.main.url(forResource: "AnimeIndex", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let names = json["genres"] as? [String] else {
            return AnimeIndex(byID: [:], genres: [], officialMAL: false)
        }
        var byID: [String: Entry] = [:]
        for kind in ["tvdb", "tmdb", "imdb"] {
            for (id, value) in (json[kind] as? [String: [Any]]) ?? [:] {
                guard value.count == 2, let score = value[0] as? Double, let tags = value[1] as? [Int] else { continue }
                byID["\(kind)://\(id)"] = Entry(score: score > 0 ? score : nil,
                                                genres: Set(tags.filter(names.indices.contains).map { names[$0] }))
            }
        }
        return AnimeIndex(byID: byID, genres: names, officialMAL: json["official"] as? Bool ?? false)
    }
}
