import Foundation

/// «If you liked this anime…»: AniList's community recommendations (https://anilist.co), for
/// related titles. Plex has no «similar» for most anime, and its other groups (voice actors,
/// big Kometa lists) come back alphabetical.
///
/// One small request the first time an anime's page is opened, then kept on the device (asked
/// again after a month). Nothing is asked of the Plex server. Offline, slow or rate limited:
/// nothing is returned and the caller falls back to Plex and to matching genres.
actor AnimeRecommendations {
    static let shared = AnimeRecommendations()

    private struct Entry: Codable {
        /// Each recommended anime's names (romaji, English, synonyms), best rated first.
        var names: [[String]]
        var checked: Date
    }

    private var entries: [String: Entry] = [:]
    private var loaded = false

    private static let endpoint = URL(string: "https://graphql.anilist.co")!
    private static let refreshAfter: TimeInterval = 30 * 86_400
    private static let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("AnimeRecommendations.json")
    }()

    /// The recommended anime that are in `library`, best rated first.
    func matches(for item: PlexItem, in library: [PlexItem]) async -> [PlexItem] {
        guard let names = await recommendedNames(for: item), !names.isEmpty else { return [] }
        // Every name a library title is known by: its own, the app's anime list, AniList's.
        let aliases = await AnimeTitles.shared.aliasesByKey()
        var byName: [String: PlexItem] = [:]
        for candidate in library where candidate.ratingKey != item.ratingKey {
            var known = [candidate.title, candidate.originalTitle].compactMap { $0 }
            known += AnimeNames.shared.names(of: candidate)
            known += aliases[AnimeTitles.key(for: candidate)] ?? []
            for name in known {
                let key = Self.normalized(name)
                if !key.isEmpty, byName[key] == nil { byName[key] = candidate }
            }
        }
        var found: [PlexItem] = []
        var seen = Set<String>()
        for recommendation in names {
            guard let match = recommendation.lazy.compactMap({ byName[Self.normalized($0)] }).first,
                  seen.insert(match.ratingKey).inserted else { continue }
            found.append(match)
        }
        return found
    }

    private static func normalized(_ name: String) -> String {
        SearchText.normalize(name).replacingOccurrences(of: " ", with: "")
    }

    // MARK: Cache

    private func recommendedNames(for item: PlexItem) async -> [[String]]? {
        load()
        let key = AnimeTitles.key(for: item)
        if let entry = entries[key], Date().timeIntervalSince(entry.checked) < Self.refreshAfter {
            return entry.names
        }
        let known = await AnimeTitles.shared.anilistID(for: item)
        guard let names = await Self.lookup(item, anilistID: known) else { return entries[key]?.names }
        entries[key] = Entry(names: names, checked: Date())
        save()
        return names
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.file),
              let stored = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = stored
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }

    // MARK: AniList

    private struct Response: Decodable {
        struct Body: Decodable {
            struct Page: Decodable { let media: [AnimeTitles.Media] }
            let Page: Page?
            let Media: AnimeTitles.Media?
        }
        let data: Body?
    }

    /// nil: no answer (offline, rate limited, error), try again next time. Empty: AniList has
    /// no such anime, or no recommendations for it.
    private static func lookup(_ item: PlexItem, anilistID: Int?) async -> [[String]]? {
        let fields = """
        id idMal title { romaji english native } synonyms seasonYear startDate { year }
        recommendations(perPage: 20, sort: RATING_DESC) { nodes { mediaRecommendation {
          id idMal title { romaji english native } synonyms seasonYear startDate { year } } } }
        """
        let query: String
        let variables: [String: Any]
        if let anilistID {
            query = "query ($id: Int) { Media(id: $id, type: ANIME) { \(fields) } }"
            variables = ["id": anilistID]
        } else {
            query = "query ($s: String) { Page(perPage: 5) { media(search: $s, type: ANIME) { \(fields) } } }"
            variables = ["s": AnimeTitles.searchName(item)]
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // The page waits for its related row: give up quickly.
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = (try? JSONDecoder().decode(Response.self, from: data))?.data else { return nil }
        let media: AnimeTitles.Media?
        if anilistID != nil {
            media = body.Media
        } else {
            media = AnimeTitles.bestMatch(for: item, in: body.Page?.media ?? [])
        }
        guard let media else { return [] }
        return (media.recommendations?.nodes ?? []).compactMap { node in
            guard let recommended = node.mediaRecommendation else { return nil }
            let names = recommended.names + [recommended.title.native].compactMap { $0 }
            return names.isEmpty ? nil : names
        }
    }
}
