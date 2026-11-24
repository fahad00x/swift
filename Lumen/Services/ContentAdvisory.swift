import Foundation

/// What a title contains (nudity, violence, language…), from TMDB: its keywords plus the
/// rating boards' reasons (movie release dates / TV content ratings). Needs a TMDB API key
/// in Info.plist (`TMDBAPIKey`): empty in the repo, written into the generated (git-ignored)
/// Info.plist by the TestFlight workflow from the `TMDB_API_KEY` secret. Without one (local
/// builds) it returns nothing and the app shows only the age rating's meaning.
/// Results are cached on the device (TMDB data rarely changes).
actor ContentAdvisory {
    static let shared = ContentAdvisory()

    /// A key was built in.
    nonisolated static var isEnabled: Bool { apiKey != nil }

    private nonisolated static let apiKey: String? = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "TMDBAPIKey") as? String else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }()

    private static let storeKey = "contentAdvisory.v1"
    /// "movie/603" → flag names ([] = looked up, nothing found).
    private var cache: [String: [String]]
    private var inFlight: [String: Task<[ContentFlag]?, Never>] = [:]
    private let session: URLSession

    init() {
        cache = UserDefaults.standard.dictionary(forKey: Self.storeKey) as? [String: [String]] ?? [:]
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
    }

    /// Flags for a movie or show (nil: unknown — no key, no TMDB id, or the lookup failed).
    func flags(for item: PlexItem) async -> [ContentFlag]? {
        guard let key = Self.apiKey, let ref = Self.reference(for: item) else { return nil }
        if let cached = cache[ref] { return cached.compactMap(ContentFlag.init(rawValue:)) }
        if let task = inFlight[ref] { return await task.value }
        let session = self.session
        let task = Task<[ContentFlag]?, Never> {
            await Self.fetch(ref: ref, key: key, session: session)
        }
        inFlight[ref] = task
        let result = await task.value
        inFlight[ref] = nil
        if let result {
            cache[ref] = result.map(\.rawValue)
            UserDefaults.standard.set(cache, forKey: Self.storeKey)
        }
        return result
    }

    /// "movie/603" / "tv/1399" from the item's external ids (Plex `includeGuids`).
    private static func reference(for item: PlexItem) -> String? {
        guard let tmdb = item.guids.first(where: { $0.hasPrefix("tmdb://") })?.dropFirst("tmdb://".count),
              !tmdb.isEmpty else { return nil }
        return (item.isShow ? "tv/" : "movie/") + tmdb
    }

    private static func fetch(ref: String, key: String, session: URLSession) async -> [ContentFlag]? {
        let isTV = ref.hasPrefix("tv/")
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(ref)")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "append_to_response", value: isTV ? "keywords,content_ratings" : "keywords,release_dates"),
        ]
        guard let url = components.url,
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var terms: [String] = []
        // Keywords: movies under "keywords", shows under "results".
        if let keywords = json["keywords"] as? [String: Any] {
            let list = (keywords["keywords"] ?? keywords["results"]) as? [[String: Any]] ?? []
            terms += list.compactMap { $0["name"] as? String }
        }
        // Rating reasons («Violence», «Sexual Content», «Language»…).
        if isTV, let ratings = (json["content_ratings"] as? [String: Any])?["results"] as? [[String: Any]] {
            for rating in ratings { terms += rating["descriptors"] as? [String] ?? [] }
        }
        if !isTV, let countries = (json["release_dates"] as? [String: Any])?["results"] as? [[String: Any]] {
            for country in countries {
                for release in country["release_dates"] as? [[String: Any]] ?? [] {
                    terms += release["descriptors"] as? [String] ?? []
                }
            }
        }
        return ContentFlag.detect(in: terms)
    }
}
