import Foundation

struct PlaybackPlan {
    let url: URL
    let isTranscode: Bool
    let sessionID: String
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recentlyAdded, title, year, rating, unwatched

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyAdded: return "أضيف مؤخراً"
        case .title: return "الاسم"
        case .year: return "السنة"
        case .rating: return "التقييم"
        case .unwatched: return "غير مُشاهد"
        }
    }

    var query: [(String, String)] {
        switch self {
        case .recentlyAdded: return [("sort", "addedAt:desc")]
        case .title: return [("sort", "titleSort")]
        case .year: return [("sort", "year:desc")]
        case .rating: return [("sort", "audienceRating:desc")]
        // Filtered on the device with the profile's own watched marks (Plex's are shared).
        case .unwatched: return [("sort", "addedAt:desc")]
        }
    }
}

/// Talks to one Plex Media Server over the connection chosen at sign-in.
final class PlexServerClient: Sendable {
    let name: String
    let machineIdentifier: String
    let baseURL: String
    let token: String
    /// plex.tv account token (watchlist lives on plex.tv, not on the server).
    let accountToken: String
    let isLocal: Bool
    /// The active profile's progress and watched marks, applied to every item the server returns.
    let userState: UserStateSnapshot
    private let metadataCache = MetadataCache()

    init(resource: PlexResource, connection: PlexConnection, accountToken: String, userState: UserStateSnapshot) {
        name = resource.name
        machineIdentifier = resource.clientIdentifier
        baseURL = connection.uri
        token = resource.accessToken ?? accountToken
        self.accountToken = accountToken
        isLocal = connection.local
        self.userState = userState
    }

    /// From the server saved at the last launch (no plex.tv lookup, no connection probing).
    init(cached: CachedServer, token: String, accountToken: String, userState: UserStateSnapshot) {
        name = cached.name
        machineIdentifier = cached.id
        baseURL = cached.uri
        self.token = token
        self.accountToken = accountToken
        isLocal = cached.isLocal
        self.userState = userState
    }

    /// Quick reachability check of this connection.
    func isReachable() async -> Bool {
        guard let url = url("/identity") else { return false }
        return (try? await PlexHTTP.data(for: PlexHTTP.request(url, token: token), session: PlexHTTP.probeSession)) != nil
    }

    // MARK: URLs

    func url(_ path: String, _ query: [(String, String)] = [], includeToken: Bool = false) -> URL? {
        var q = query
        if includeToken { q.append(("X-Plex-Token", token)) }
        return PlexHTTP.url(base: baseURL, path: path, query: q)
    }

    /// Server-side resized artwork so the TV never downloads full-size images.
    /// - Parameter png: keep transparency (needed for clear logos; the default output is JPEG).
    func imageURL(_ path: String?, width: Int, height: Int, png: Bool = false) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        var q: [(String, String)] = [
            ("width", "\(width)"), ("height", "\(height)"),
            ("minSize", "1"), ("upscale", "1"), ("url", path),
        ]
        if png { q.append(("format", "png")) }
        return url("/photo/:/transcode", q, includeToken: true)
    }

    // MARK: Requests

    /// - Parameter raw: keep Plex's own progress values (only for the one-time import).
    /// Every GET goes through here: saved to disk after each successful fetch, and answered from
    /// disk when the caller runs under `PlexResponseCache.policy == .cacheOnly`.
    private func container(_ path: String, _ query: [(String, String)] = [], raw: Bool = false) async throws -> MediaContainer {
        guard let url = url(path, query) else { throw PlexError.invalidURL }
        let data: Data
        if PlexResponseCache.policy == .cacheOnly && !raw {
            guard let saved = PlexResponseCache.read(server: machineIdentifier, path: path, query: query) else {
                throw PlexError.notCached
            }
            data = saved
        } else {
            data = try await PlexHTTP.data(for: PlexHTTP.request(url, token: token))
        }
        var c = try JSONDecoder().decode(MediaContainerResponse.self, from: data).mediaContainer
        if PlexResponseCache.policy == .network && !raw {
            PlexResponseCache.write(data, server: machineIdentifier, path: path, query: query)
        }
        guard !raw else { return c }
        let state = userState
        c.metadata = c.metadata.map { $0.applying(state) }
        c.hubs = c.hubs.map { hub in
            var hub = hub
            hub.items = hub.items.map { $0.applying(state) }
            return hub
        }
        return c
    }

    private func fire(_ path: String, _ query: [(String, String)] = [], method: String = "GET") async {
        guard let url = url(path, query) else { return }
        _ = try? await PlexHTTP.data(for: PlexHTTP.request(url, method: method, token: token))
    }

    func sections() async throws -> [PlexDirectory] {
        try await container("/library/sections").directories.filter(\.isVideoLibrary)
    }

    // MARK: On-device library (read first; the server only when it isn't synced yet)

    private var local: LocalLibrary { LocalLibrary.shared }

    private func applied(_ items: [PlexItem]) -> [PlexItem] {
        let state = userState
        return items.map { $0.applying(state) }
    }

    /// Poster at the size every card uses (the background sync prefetches the same URLs).
    func posterURL(_ item: PlexItem) -> URL? {
        imageURL(item.posterPath, width: ArtworkSize.posterWidth, height: ArtworkSize.posterHeight)
    }

    /// The item as stored on the device (lightweight, instant), else its full metadata.
    func item(_ ratingKey: String) async -> PlexItem? {
        if let stored = await local.item(server: machineIdentifier, key: ratingKey) { return stored.applying(userState) }
        return try? await metadata(ratingKey)
    }

    /// Newest episode air date of a show ("yyyy-MM-dd"), from the device.
    func latestAired(show ratingKey: String) async -> String? {
        await local.latestAired(server: machineIdentifier, show: ratingKey)
    }

    func recentlyAdded(section: PlexDirectory, limit: Int = 24) async throws -> [PlexItem] {
        if let stored = await local.recentlyAdded(server: machineIdentifier, section: section.key, limit: limit) {
            return applied(stored)
        }
        return try await container("/library/sections/\(section.key)/recentlyAdded",
                            [("X-Plex-Container-Start", "0"), ("X-Plex-Container-Size", "\(limit)")]).metadata
    }

    func items(section: PlexDirectory, sort: LibrarySort, start: Int, size: Int) async throws -> (items: [PlexItem], total: Int) {
        if let stored = await local.items(server: machineIdentifier, section: section.key, sort: sort, start: start, size: size) {
            return (applied(stored.items), stored.total)
        }
        var q = sort.query
        q += [("X-Plex-Container-Start", "\(start)"), ("X-Plex-Container-Size", "\(size)")]
        let c = try await container("/library/sections/\(section.key)/all", q)
        return (c.metadata, c.totalSize ?? c.size ?? c.metadata.count)
    }

    func metadata(_ ratingKey: String) async throws -> PlexItem {
        let c: MediaContainer
        do {
            c = try await container("/library/metadata/\(ratingKey)", [("includeMarkers", "1"), ("includeChapters", "1"), ("includeGuids", "1")])
        } catch {
            // Not saved yet: the synced copy shows the page instantly; the server fills in the rest.
            if PlexResponseCache.policy == .cacheOnly,
               let stored = await local.item(server: machineIdentifier, key: ratingKey) {
                return stored.applying(userState)
            }
            throw error
        }
        guard let item = c.metadata.first else { throw PlexError.invalidResponse }
        await metadataCache.store(item)
        return item
    }

    /// Metadata for content filtering (genres, country, labels, rating, library), cached for the session.
    func cachedMetadata(_ ratingKey: String) async -> PlexItem? {
        if let cached = await metadataCache.item(ratingKey) { return cached }
        if let stored = await local.item(server: machineIdentifier, key: ratingKey) { return stored.applying(userState) }
        return try? await metadata(ratingKey)
    }

    /// Every episode of a show, in order.
    func allLeaves(_ showKey: String) async -> [PlexItem] {
        if let stored = await local.leaves(server: machineIdentifier, show: showKey) { return applied(stored) }
        let fetched = ((try? await container("/library/metadata/\(showKey)/allLeaves").metadata) ?? []).filter(\.isEpisode)
        // Cached on the device: the show opens instantly next time.
        if !fetched.isEmpty { await local.cache(server: machineIdentifier, show: showKey, episodes: fetched) }
        return fetched
    }

    /// First episode after `episodeKey` that the active profile hasn't watched.
    func nextUnwatched(showKey: String, after episodeKey: String) async -> PlexItem? {
        let all = await allLeaves(showKey)
        guard let index = all.firstIndex(where: { $0.ratingKey == episodeKey }) else { return nil }
        return all[(index + 1)...].first { !$0.isWatched }
    }

    // MARK: Hubs and browsing (Apple TV rows, collections, playlists, categories)

    /// Plex's hubs: Home (`section` nil) or one library, in the server's order.
    func hubs(section: String?, count: Int = 20) async -> [PlexHub] {
        let path = section.map { "/hubs/sections/\($0)" } ?? "/hubs"
        let c = try? await container(path, [("count", "\(count)"), ("includeLibraryPlaylists", "1")])
        return (c?.hubs ?? []).filter { !$0.items.isEmpty }
    }

    /// Any listing as items (collections, playlists, a collection's or playlist's contents,
    /// a filtered library), paged.
    func listing(_ path: String, _ query: [(String, String)] = [], start: Int = 0, size: Int = 120) async -> [PlexItem] {
        let q = query + [("X-Plex-Container-Start", "\(start)"), ("X-Plex-Container-Size", "\(size)")]
        return (try? await container(path, q).metadata) ?? []
    }

    /// A library's categories (genres) with the key to filter by.
    func genreDirectories(section: String) async -> [PlexDirectory] {
        ((try? await container("/library/sections/\(section)/genre").directories) ?? []).filter { !$0.title.isEmpty }
    }

    /// Genre names used in a library.
    func genres(section: PlexDirectory) async -> [String] {
        ((try? await container("/library/sections/\(section.key)/genre").directories) ?? []).map(\.title).filter { !$0.isEmpty }
    }

    func children(_ ratingKey: String) async throws -> [PlexItem] {
        if let stored = await local.children(server: machineIdentifier, of: ratingKey) { return applied(stored) }
        let fetched = try await container("/library/metadata/\(ratingKey)/children").metadata
        if fetched.contains(where: \.isSeason) {
            await local.cache(server: machineIdentifier, show: ratingKey, seasons: fetched.filter(\.isSeason))
        }
        return fetched
    }

    /// Next episode in the show after `episode` (crosses season boundaries).
    func nextEpisode(after episode: PlexItem) async -> PlexItem? {
        guard episode.isEpisode, let showKey = episode.grandparentRatingKey else { return nil }
        let all = await allLeaves(showKey)
        guard let index = all.firstIndex(where: { $0.ratingKey == episode.ratingKey }),
              index + 1 < all.count
        else { return nil }
        return all[index + 1]
    }

    /// "More like this" from the server's related hubs.
    func related(_ ratingKey: String) async -> [PlexItem] {
        guard let hubs = try? await container("/library/metadata/\(ratingKey)/related").hubs else { return [] }
        var seen = Set<String>([ratingKey])
        return hubs.flatMap(\.items).filter {
            ($0.type == "movie" || $0.type == "show") && seen.insert($0.ratingKey).inserted
        }
    }

    /// Artwork choices of a movie / show (Plex "arts": the selected background and the
    /// agents' alternatives), as paths for `imageURL`. Selected first.
    func artworks(_ ratingKey: String) async -> [String] {
        guard let url = url("/library/metadata/\(ratingKey)/arts"),
              let data = try? await PlexHTTP.data(for: PlexHTTP.request(url, token: token)) else { return [] }
        struct Response: Decodable {
            struct Container: Decodable { let Metadata: [Art]? }
            struct Art: Decodable { let key: String?; let selected: Bool? }
            let MediaContainer: Container
        }
        guard let arts = (try? JSONDecoder().decode(Response.self, from: data))?.MediaContainer.Metadata else { return [] }
        let ordered = arts.filter { $0.selected == true } + arts.filter { $0.selected != true }
        return ordered.compactMap(\.key).filter { !$0.isEmpty }
    }

    /// Trailers and extras attached to a movie or show.
    func extras(_ ratingKey: String) async -> [PlexItem] {
        let items = (try? await container("/library/metadata/\(ratingKey)/extras").metadata) ?? []
        return items.filter { $0.primaryPart?.key != nil }
    }

    /// Episode to start a show with: in progress, else first unwatched, else the first one.
    func episodeToPlay(showKey: String) async -> PlexItem? {
        let all = await allLeaves(showKey)
        guard !all.isEmpty else { return nil }
        return all.first { $0.progress != nil && !$0.isWatched } ?? all.first { !$0.isWatched } ?? all.first
    }

    // MARK: One-time import of the data that existed before profiles

    /// Raw Plex progress (in progress + watched items) of a library, with Plex's shared values.
    func importableHistory(section: PlexDirectory) async -> [PlexItem] {
        let type = section.type == "show" ? "4" : "1"
        var out: [PlexItem] = []
        var start = 0
        let size = 500
        while true {
            guard let c = try? await container("/library/sections/\(section.key)/all",
                                               [("type", type), ("X-Plex-Container-Start", "\(start)"),
                                                ("X-Plex-Container-Size", "\(size)")], raw: true)
            else { break }
            out += c.metadata.filter { ($0.viewCount ?? 0) > 0 || ($0.viewOffset ?? 0) > 0 }
            start += c.metadata.count
            let total = c.totalSize ?? c.size ?? 0
            if c.metadata.isEmpty || start >= total { break }
        }
        return out
    }

    private static let discover = "https://discover.provider.plex.tv"

    /// Items of the account's Plex watchlist that exist on this server.
    func importableWatchlist() async -> [PlexItem] {
        guard let url = PlexHTTP.url(base: Self.discover, path: "/library/sections/watchlist/all",
                                     query: [("X-Plex-Container-Start", "0"), ("X-Plex-Container-Size", "200")]),
              let remote = try? await PlexHTTP.decode(MediaContainerResponse.self,
                                                      from: PlexHTTP.request(url, token: accountToken)).mediaContainer.metadata
        else { return [] }
        var found: [PlexItem] = []
        for item in remote {
            guard let guid = item.guid,
                  let local = try? await container("/library/all", [("guid", guid)]).metadata.first
            else { continue }
            found.append(local)
        }
        return found
    }

    func search(_ query: String) async throws -> [PlexItem] {
        if let stored = await local.search(server: machineIdentifier, query: query, sections: nil) {
            return applied(stored)
        }
        let hubs = try await container("/hubs/search", [("query", query), ("limit", "30")]).hubs
        return hubs
            .filter { ["movie", "show", "episode"].contains($0.type) }
            .flatMap(\.items)
    }

    // MARK: Playback

    /// - Parameter nativeEngine: true for the MPV engine, which plays every container/codec
    ///   itself, so the original file is streamed untouched unless bandwidth limits apply.
    func playbackPlan(for item: PlexItem, forceTranscode: Bool, maxBitrateKbps: Int, nativeEngine: Bool = false) -> PlaybackPlan? {
        guard let media = item.media.first, let part = media.parts.first, let partKey = part.key else { return nil }
        let session = UUID().uuidString

        // AVPlayer natively plays MP4/MOV with H.264/HEVC and common Apple-supported audio.
        let container = (part.container ?? media.container ?? "").lowercased()
        let video = (media.videoCodec ?? "").lowercased()
        let audio = (media.audioCodec ?? "").lowercased()
        let withinBitrate = (media.bitrate ?? 0) <= maxBitrateKbps
        let canDirectPlay = nativeEngine ? withinBitrate : ["mp4", "m4v", "mov"].contains(container)
            && ["h264", "hevc", "h265"].contains(video)
            && ["aac", "ac3", "eac3", "alac", "mp3"].contains(audio)
            && withinBitrate

        if canDirectPlay && !forceTranscode, let url = directURL(partKey: partKey) {
            return PlaybackPlan(url: url, isTranscode: false, sessionID: session)
        }

        // Otherwise let Plex remux (direct stream) or transcode to HLS.
        let resolution = maxBitrateKbps >= 20_000 ? "3840x2160" : (maxBitrateKbps >= 8_000 ? "1920x1080" : "1280x720")
        var q: [(String, String)] = [
            ("path", "/library/metadata/\(item.ratingKey)"),
            ("mediaIndex", "0"), ("partIndex", "0"),
            ("protocol", "hls"), ("fastSeek", "1"), ("copyts", "1"),
            ("directPlay", "0"), ("directStream", "1"), ("directStreamAudio", "1"),
            ("videoQuality", "100"), ("maxVideoBitrate", "\(maxBitrateKbps)"),
            ("videoResolution", resolution),
            ("subtitles", "auto"), ("subtitleSize", "100"), ("audioBoost", "100"),
            ("location", isLocal ? "lan" : "wan"),
            ("session", session), ("X-Plex-Session-Identifier", session),
            ("X-Plex-Client-Profile-Extra",
             "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264,hevc&audioCodec=aac,ac3,eac3)"),
        ]
        q += PlexClientInfo.queryItems
        guard let url = url("/video/:/transcode/universal/start.m3u8", q, includeToken: true) else { return nil }
        return PlaybackPlan(url: url, isTranscode: true, sessionID: session)
    }

    func directURL(partKey: String) -> URL? {
        url(partKey, PlexClientInfo.queryItems, includeToken: true)
    }

    /// The only update Lumen sends Plex: the playback timeline the server needs while streaming.
    /// Nothing is ever marked as watched on the server (watched marks are per profile, in Lumen):
    /// the reported time is capped below the server's "played" threshold so Plex never
    /// auto-marks the item for the shared account.
    func reportTimeline(item: PlexItem, state: String, timeMs: Int, durationMs: Int, sessionID: String) async {
        let timeMs = durationMs > 0 ? min(timeMs, Int(Double(durationMs) * 0.7)) : timeMs
        await fire("/:/timeline", [
            ("ratingKey", item.ratingKey),
            ("key", "/library/metadata/\(item.ratingKey)"),
            ("state", state),
            ("time", "\(timeMs)"),
            ("duration", "\(durationMs)"),
            ("X-Plex-Session-Identifier", sessionID),
        ])
    }

    func stopTranscode(sessionID: String) async {
        await fire("/video/:/transcode/universal/stop", [("session", sessionID)])
    }
}

/// Pixel size of the poster artwork requested from Plex's photo transcoder.
enum ArtworkSize {
    #if os(tvOS)
    // 2× the 260 × 390 pt Apple TV poster card.
    static let posterWidth = 520
    static let posterHeight = 780
    #else
    static let posterWidth = 360
    static let posterHeight = 540
    #endif
}

/// Session cache of full metadata (used by content filters, e.g. a show's genres for its episodes).
private actor MetadataCache {
    private var items: [String: PlexItem] = [:]

    func item(_ key: String) -> PlexItem? { items[key] }

    func store(_ item: PlexItem) {
        if items.count > 2000 { items.removeAll() }
        items[item.ratingKey] = item
    }
}
