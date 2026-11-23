import Foundation

/// Intro / recap / credits timestamps from the community databases Infuse also uses
/// (IntroDB.app, then TheIntroDB.org), looked up by the show's IMDb / TMDB / TVDB id from Plex
/// plus season and episode. Free, no API key. Only these ids and numbers are sent.
enum OnlineSkipSegments {
    struct Query: Hashable {
        var imdb: String?
        var tmdb: String?
        var tvdb: String?
        var season: Int?
        var episode: Int?
        var durationMs: Int
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        return URLSession(configuration: config)
    }()

    private static let cache = Cache()

    /// `show` is the episode's show (with its guids); nil for a movie.
    static func query(for item: PlexItem, show: PlexItem?) -> Query? {
        guard let source = item.isEpisode ? show : item else { return nil }
        let q = Query(imdb: source.externalID("imdb"), tmdb: source.externalID("tmdb"), tvdb: source.externalID("tvdb"),
                      season: item.isEpisode ? item.parentIndex : nil,
                      episode: item.isEpisode ? item.index : nil,
                      durationMs: item.duration ?? 0)
        if item.isEpisode, q.season == nil || q.episode == nil { return nil }
        if q.imdb == nil, q.tmdb == nil, q.tvdb == nil { return nil }
        return q
    }

    /// IntroDB first, TheIntroDB fills in missing kinds.
    static func fetch(_ q: Query) async -> [SkipSegment] {
        if let cached = await cache.get(q) { return cached }
        async let first = introDB(q)
        async let second = theIntroDB(q)
        let (a, b) = await (first, second)
        let result = SkipSegmentFinder.merge(a, b).filter { valid($0, durationMs: q.durationMs) }
        await cache.set(q, result)
        return result
    }

    private static func valid(_ s: SkipSegment, durationMs: Int) -> Bool {
        guard s.endMs > s.startMs else { return false }
        return durationMs <= 0 || s.startMs < durationMs
    }

    private static func segment(_ kind: SkipSegment.Kind, startMs: Double?, endMs: Double?, durationMs: Int) -> SkipSegment? {
        let start = Int(startMs ?? 0)
        let end = endMs.map { Int($0) } ?? (durationMs > 0 ? durationMs : start + 1000)
        guard end > start else { return nil }
        return SkipSegment(kind: kind, startMs: start, endMs: end, source: .online)
    }

    // MARK: IntroDB.app — GET https://api.introdb.app/segments?imdb_id=tt…&season=1&episode=1

    private struct IntroDBRange: Decodable {
        let start_ms: Double?
        let end_ms: Double?
    }

    private struct IntroDBResponse: Decodable {
        let intro: IntroDBRange?
        let recap: IntroDBRange?
        let outro: IntroDBRange?
    }

    private static func introDB(_ q: Query) async -> [SkipSegment] {
        guard let imdb = q.imdb else { return [] }
        var items = [URLQueryItem(name: "imdb_id", value: imdb)]
        if let season = q.season, let episode = q.episode {
            items += [URLQueryItem(name: "season", value: "\(season)"), URLQueryItem(name: "episode", value: "\(episode)")]
        }
        guard let response: IntroDBResponse = await get("https://api.introdb.app/segments", items) else { return [] }
        var out: [SkipSegment] = []
        if let r = response.recap, let s = segment(.recap, startMs: r.start_ms, endMs: r.end_ms, durationMs: q.durationMs) { out.append(s) }
        if let r = response.intro, let s = segment(.intro, startMs: r.start_ms, endMs: r.end_ms, durationMs: q.durationMs) { out.append(s) }
        if let r = response.outro, let s = segment(.credits, startMs: r.start_ms, endMs: r.end_ms, durationMs: q.durationMs) { out.append(s) }
        return out
    }

    // MARK: TheIntroDB.org — GET https://api.theintrodb.org/v4/media?tvdb_id=…&season=1&episode=1

    private struct TIDBRange: Decodable {
        let start_ms: Double?
        let end_ms: Double?
    }

    private struct TIDBResponse: Decodable {
        let intro: [TIDBRange]?
        let recap: [TIDBRange]?
        let credits: [TIDBRange]?
    }

    private static func theIntroDB(_ q: Query) async -> [SkipSegment] {
        var items: [URLQueryItem] = []
        if let tvdb = q.tvdb { items.append(URLQueryItem(name: "tvdb_id", value: tvdb)) }
        if let tmdb = q.tmdb { items.append(URLQueryItem(name: "tmdb_id", value: tmdb)) }
        if let imdb = q.imdb { items.append(URLQueryItem(name: "imdb_id", value: imdb)) }
        if let season = q.season, let episode = q.episode {
            items += [URLQueryItem(name: "season", value: "\(season)"), URLQueryItem(name: "episode", value: "\(episode)")]
        }
        guard let response: TIDBResponse = await get("https://api.theintrodb.org/v4/media", items) else { return [] }
        var out: [SkipSegment] = []
        if let r = response.recap?.first, let s = segment(.recap, startMs: r.start_ms, endMs: r.end_ms, durationMs: q.durationMs) { out.append(s) }
        if let r = response.intro?.first, let s = segment(.intro, startMs: r.start_ms, endMs: r.end_ms, durationMs: q.durationMs) { out.append(s) }
        if let r = response.credits?.first, let s = segment(.credits, startMs: r.start_ms, endMs: r.end_ms, durationMs: q.durationMs) { out.append(s) }
        return out
    }

    private static func get<T: Decodable>(_ base: String, _ items: [URLQueryItem]) async -> T? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("\(PlexClientInfo.product)/\(PlexClientInfo.version)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private actor Cache {
        private var values: [Query: [SkipSegment]] = [:]
        func get(_ q: Query) -> [SkipSegment]? { values[q] }
        func set(_ q: Query, _ v: [SkipSegment]) { values[q] = v }
    }
}
