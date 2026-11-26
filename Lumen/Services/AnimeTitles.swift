import Foundation

/// Other titles of the anime that aren't in the app's own list (`AnimeNames`), from AniList (https://anilist.co): the Japanese
/// title in Latin letters («Shingeki no Kyojin»), the English one («Attack on Titan») and short
/// names («AOT», «SNK»), so search finds an anime by any of them. AniList also gives the
/// MyAnimeList id, kept with the titles.
///
/// Each anime is looked up once, in the background after a library download, ten per request
/// with a pause between requests (about thirty a minute), and the answer is kept on the device. Nothing is asked of the
/// Plex server. An anime AniList doesn't know is asked again after a month.
actor AnimeTitles {
    static let shared = AnimeTitles()

    struct Entry: Codable {
        var anilistID: Int?
        var malID: Int?
        var titles: [String]
        var checked: Date
    }

    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var prepared: [String: [SearchField]]?
    private var running = false

    private static let endpoint = URL(string: "https://graphql.anilist.co")!
    private static let batchSize = 10
    /// AniList allows 30 lookups a minute and counts each title of a request.
    private static let pause: Duration = .seconds(21)
    private static let retryAfter: TimeInterval = 30 * 86_400

    private static let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("AnimeTitles.json")
    }()

    /// The same title on every server: Plex's own guid when there is one.
    static func key(for item: PlexItem) -> String { item.guid ?? item.ratingKey }

    /// The AniList id found for an anime (only those whose names weren't in the app already).
    func anilistID(for item: PlexItem) -> Int? {
        load()
        return entries[Self.key(for: item)]?.anilistID
    }

    /// AniList's other titles of each anime looked up, by `key(for:)`.
    func aliasesByKey() -> [String: [String]] {
        load()
        return entries.compactMapValues { $0.titles.isEmpty ? nil : $0.titles }
    }

    /// Titles by `key(for:)`, ready for `SmartSearch`.
    func aliases() -> [String: [SearchField]] {
        load()
        if let prepared { return prepared }
        var out: [String: [SearchField]] = [:]
        for (key, entry) in entries where !entry.titles.isEmpty {
            out[key] = entry.titles.compactMap(SearchField.init)
        }
        prepared = out
        return out
    }

    /// Looks up the anime not looked up yet (stops quietly when offline or rate limited).
    func refresh(_ items: [PlexItem]) async {
        load()
        guard !running else { return }
        running = true
        defer { running = false }
        var seen = Set<String>()
        let pending = items.filter { item in
            let key = Self.key(for: item)
            guard seen.insert(key).inserted else { return false }
            // Its names are in the app already.
            guard AnimeNames.shared.names(of: item).isEmpty else { return false }
            guard let entry = entries[key] else { return true }
            return entry.anilistID == nil && Date().timeIntervalSince(entry.checked) > Self.retryAfter
        }
        var start = 0
        while start < pending.count {
            if Task.isCancelled { return }
            let batch = Array(pending[start..<min(start + Self.batchSize, pending.count)])
            start += batch.count
            var answer = await Self.lookup(batch)
            // Too many in a minute (another device on the network): waits, a few times.
            for _ in 0..<3 {
                guard case .limited(let seconds) = answer else { break }
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
                answer = await Self.lookup(batch)
            }
            guard case .found(let found) = answer else { return }
            for (item, entry) in zip(batch, found) { entries[Self.key(for: item)] = entry }
            prepared = nil
            save()
            if start < pending.count { try? await Task.sleep(for: Self.pause) }
        }
    }

    // MARK: Storage

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

    private struct Response: Decodable { let data: [String: Page?]? }
    struct Page: Decodable { let media: [Media] }
    struct Media: Decodable {
        struct Title: Decodable { let romaji: String?; let english: String?; let native: String? }
        struct FuzzyDate: Decodable { let year: Int? }
        let id: Int
        let idMal: Int?
        let title: Title
        let synonyms: [String]?
        let seasonYear: Int?
        let startDate: FuzzyDate?
        /// Only asked for by `AnimeRecommendations`.
        let recommendations: Recommendations?

        struct Recommendations: Decodable {
            struct Node: Decodable { let mediaRecommendation: Media? }
            let nodes: [Node]
        }

        var year: Int? { seasonYear ?? startDate?.year }
        var names: [String] {
            [title.romaji, title.english].compactMap { $0 } + (synonyms ?? [])
        }
    }

    private enum Answer { case found([Entry]), limited(seconds: Int), failed }

    /// One request for a batch: an entry per item (empty titles when not found).
    private static func lookup(_ items: [PlexItem]) async -> Answer {
        var variables: [String: String] = [:]
        var parts: [String] = []
        var declarations: [String] = []
        for (i, item) in items.enumerated() {
            variables["s\(i)"] = searchName(item)
            declarations.append("$s\(i): String")
            parts.append("""
            a\(i): Page(perPage: 6) { media(search: $s\(i), type: ANIME) {
              id idMal title { romaji english native } synonyms seasonYear startDate { year } } }
            """)
        }
        let query = "query (\(declarations.joined(separator: ", "))) {\n\(parts.joined(separator: "\n"))\n}"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = ["query": query, "variables": variables]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let result = try? await URLSession.shared.data(for: request) else { return .failed }
        let (data, response) = result
        if let http = response as? HTTPURLResponse, http.statusCode == 429 {
            let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) } ?? 60
            return .limited(seconds: min(max(wait, 5), 120) + 1)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let pages = decoded.data else { return .failed }
        let now = Date()
        return .found(items.enumerated().map { (i, item) -> Entry in
            let candidates = pages["a\(i)"]??.media ?? []
            guard let media = bestMatch(for: item, in: candidates) else {
                return Entry(anilistID: nil, malID: nil, titles: [], checked: now)
            }
            let own = Set([item.title, item.originalTitle].compactMap { $0 }.map(SearchText.normalize))
            var titles: [String] = []
            for name in media.names {
                let normalized = SearchText.normalize(name)
                guard !normalized.isEmpty, !own.contains(normalized),
                      !titles.contains(where: { SearchText.normalize($0) == normalized }) else { continue }
                titles.append(name)
            }
            return Entry(anilistID: media.id, malID: media.idMal, titles: titles, checked: now)
        })
    }

    /// The name to search AniList with (an Arabic title won't be found there).
    static func searchName(_ item: PlexItem) -> String {
        if SearchText.isArabic(item.title), let original = item.originalTitle { return original }
        return item.title
    }

    /// Only a confident match: a name equal (or one or two letters off) to the item's title or
    /// original title, and a year no more than one off when both are known.
    /// `alsoKnownAs`: other names of the title (the app's anime list), matched like its own.
    static func bestMatch(for item: PlexItem, in candidates: [Media], alsoKnownAs: [String] = []) -> Media? {
        let own = ([item.title, item.originalTitle].compactMap { $0 } + alsoKnownAs)
            .map { SearchText.scalars(SearchText.normalize($0).replacingOccurrences(of: " ", with: "")) }
            .filter { !$0.isEmpty }
        guard !own.isEmpty else { return nil }
        var best: (media: Media, exact: Bool, yearGap: Int)?
        for media in candidates {
            var exact = false
            var close = false
            let names = (media.names + [media.title.native].compactMap { $0 })
                .map { SearchText.scalars(SearchText.normalize($0).replacingOccurrences(of: " ", with: "")) }
            for name in names where !name.isEmpty {
                for mine in own {
                    if name == mine { exact = true }
                    else if mine.count >= 6 {
                        let limit = SearchText.tolerance(mine.count)
                        if SearchText.distance(mine, name, limit: limit) <= limit { close = true }
                    }
                }
            }
            guard exact || close else { continue }
            let gap = (item.year != nil && media.year != nil) ? abs(item.year! - media.year!) : 0
            if gap > 1 && !exact { continue }
            if let current = best {
                let better = (exact && !current.exact) || (exact == current.exact && gap < current.yearGap)
                if !better { continue }
            }
            best = (media, exact, gap)
        }
        return best?.media
    }
}
