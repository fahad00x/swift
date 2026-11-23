import Foundation
import Observation

// Infuse-style on-device library: every movie, show, season and episode of the server's video
// libraries is kept in a local database (one JSON file per library in Application Support).
// Browsing reads only from it; the server is asked for playback, full details and the
// background sync, which fetches only libraries whose content changed, and only the items
// updated since the last sync.

/// One library as stored on the device. Items are kept as Plex sent them (Plex's shared
/// progress values are replaced by the active profile's when read, like every response).
struct LocalSection: Codable {
    var key: String
    var type: String
    /// Plex's `contentChangedAt` for the library at the last sync (unchanged = nothing to fetch).
    var contentChangedAt: Int?
    /// Newest `updatedAt` seen, the starting point of the next incremental sync.
    var highWater: Int
    var items: [PlexItem]
    var seasons: [PlexItem]
    var episodes: [PlexItem]
}

/// Lookup tables built from the stored libraries.
private struct LibraryIndex {
    var sections: [String: LocalSection] = [:]
    var byKey: [String: PlexItem] = [:]
    /// show → seasons, season → episodes (in order).
    var children: [String: [PlexItem]] = [:]
    /// show → every episode (in order).
    var leaves: [String: [PlexItem]] = [:]
    /// show → newest episode `addedAt` (so a show with a new episode counts as recently added).
    var latestAdded: [String: Int] = [:]
    /// show → newest episode air date ("yyyy-MM-dd").
    var latestAired: [String: String] = [:]

    init() {}

    init(sections: [String: LocalSection]) {
        self.sections = sections
        for section in sections.values {
            for item in section.items { byKey[item.ratingKey] = item }
            for season in section.seasons {
                byKey[season.ratingKey] = season
                if let show = season.parentRatingKey { children[show, default: []].append(season) }
            }
            for episode in section.episodes {
                byKey[episode.ratingKey] = episode
                if let season = episode.parentRatingKey { children[season, default: []].append(episode) }
                guard let show = episode.grandparentRatingKey else { continue }
                leaves[show, default: []].append(episode)
                if let added = episode.addedAt { latestAdded[show] = max(latestAdded[show] ?? 0, added) }
                if let aired = episode.originallyAvailableAt, aired > (latestAired[show] ?? "") { latestAired[show] = aired }
            }
        }
        for key in children.keys { children[key]?.sort { ($0.index ?? 0) < ($1.index ?? 0) } }
        for key in leaves.keys {
            leaves[key]?.sort { (($0.parentIndex ?? 0), ($0.index ?? 0)) < (($1.parentIndex ?? 0), ($1.index ?? 0)) }
        }
    }

    func addedKey(_ item: PlexItem) -> Int {
        max(item.addedAt ?? 0, latestAdded[item.ratingKey] ?? 0)
    }
}

actor LocalLibrary {
    static let shared = LocalLibrary()

    private var serverID: String?
    private var index = LibraryIndex()
    private var loadTask: Task<Void, Never>?

    private static let root: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLibrary", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func directory(_ server: String) -> URL {
        let dir = root.appendingPathComponent(server, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Loading

    /// Loads the server's stored libraries from disk (off the actor); reads answer nil until then.
    func open(server: String) async {
        if serverID == server { await loadTask?.value; return }
        serverID = server
        index = LibraryIndex()
        let task = Task.detached(priority: .userInitiated) { () -> [String: LocalSection] in
            let dir = Self.directory(server)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            var out: [String: LocalSection] = [:]
            let decoder = JSONDecoder()
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let section = try? decoder.decode(LocalSection.self, from: data) else { continue }
                out[section.key] = section
            }
            return out
        }
        let wait = Task {
            let sections = await task.value
            await self.install(sections, server: server)
        }
        loadTask = wait
        await wait.value
    }

    private func install(_ sections: [String: LocalSection], server: String) async {
        guard serverID == server else { return }
        let built = await Task.detached(priority: .userInitiated) { LibraryIndex(sections: sections) }.value
        guard serverID == server else { return }
        index = built
    }

    private func ready(_ server: String) -> Bool { serverID == server && !index.sections.isEmpty }

    // MARK: Writing (from the sync)

    func section(server: String, key: String) -> LocalSection? {
        guard serverID == server else { return nil }
        return index.sections[key]
    }

    func store(_ section: LocalSection, server: String) async {
        guard serverID == server else { return }
        var sections = index.sections
        sections[section.key] = section
        let built = await Task.detached(priority: .utility) { LibraryIndex(sections: sections) }.value
        guard serverID == server else { return }
        index = built
        let file = Self.directory(server).appendingPathComponent("\(section.key).json")
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(section) { try? data.write(to: file, options: .atomic) }
        }
    }

    /// Drops libraries that no longer exist on the server.
    func prune(server: String, keeping keys: Set<String>) {
        guard serverID == server else { return }
        let gone = index.sections.keys.filter { !keys.contains($0) }
        guard !gone.isEmpty else { return }
        var sections = index.sections
        for key in gone {
            sections[key] = nil
            try? FileManager.default.removeItem(at: Self.directory(server).appendingPathComponent("\(key).json"))
        }
        index = LibraryIndex(sections: sections)
    }

    // MARK: Reading (nil = not on the device yet: the caller asks the server)

    func hasSection(server: String, key: String) -> Bool {
        serverID == server && index.sections[key] != nil
    }

    func item(server: String, key: String) -> PlexItem? {
        guard serverID == server else { return nil }
        return index.byKey[key]
    }

    func items(server: String, section: String, sort: LibrarySort, start: Int, size: Int) -> (items: [PlexItem], total: Int)? {
        guard serverID == server, let stored = index.sections[section] else { return nil }
        let sorted = Self.sorted(stored.items, by: sort, index: index)
        let lower = min(start, sorted.count)
        let upper = min(lower + max(size, 0), sorted.count)
        return (Array(sorted[lower..<upper]), sorted.count)
    }

    func recentlyAdded(server: String, section: String, limit: Int) -> [PlexItem]? {
        guard serverID == server, let stored = index.sections[section] else { return nil }
        return Array(Self.sorted(stored.items, by: .recentlyAdded, index: index).prefix(limit))
    }

    /// Seasons of a show, or episodes of a season.
    func children(server: String, of key: String) -> [PlexItem]? {
        guard ready(server), let parent = index.byKey[key], parent.isShow || parent.isSeason else { return nil }
        return index.children[key] ?? []
    }

    func leaves(server: String, show: String) -> [PlexItem]? {
        guard ready(server), index.byKey[show]?.isShow == true else { return nil }
        return index.leaves[show] ?? []
    }

    /// Newest episode air date of a show ("yyyy-MM-dd").
    func latestAired(server: String, show: String) -> String? {
        guard serverID == server else { return nil }
        return index.latestAired[show]
    }

    /// Titles matching `query` (movies and shows first, then episodes), nil before the first sync.
    func search(server: String, query: String, sections keys: Set<String>?, limit: Int = 60) -> [PlexItem]? {
        guard ready(server) else { return nil }
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        func matches(_ text: String?) -> Bool {
            guard let text else { return false }
            return text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(q)
        }
        var titles: [PlexItem] = []
        var episodes: [PlexItem] = []
        for section in index.sections.values where keys?.contains(section.key) ?? true {
            titles += section.items.filter { matches($0.title) }
            if episodes.count < limit { episodes += section.episodes.filter { matches($0.title) }.prefix(limit) }
        }
        titles.sort { ($0.title.count, $0.title) < ($1.title.count, $1.title) }
        return Array((titles + episodes).prefix(limit))
    }

    private static func sorted(_ items: [PlexItem], by sort: LibrarySort, index: LibraryIndex) -> [PlexItem] {
        switch sort {
        case .recentlyAdded, .unwatched:
            return items.sorted { index.addedKey($0) > index.addedKey($1) }
        case .title:
            return items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .year:
            return items.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .rating:
            return items.sorted { ($0.audienceRating ?? $0.rating ?? 0) > ($1.audienceRating ?? $1.rating ?? 0) }
        }
    }
}

// MARK: - Sync

/// Background sync of the local library, with progress for the UI.
@MainActor
@Observable
final class LibrarySync {
    static let shared = LibrarySync()

    private(set) var isSyncing = false
    /// 0…1 while syncing.
    private(set) var progress: Double = 0
    private(set) var message = ""
    /// The first sync of this server is still running (nothing on the device yet).
    private(set) var isFirstSync = false
    private(set) var lastSync: Date?

    private var task: Task<Void, Never>?

    /// Starts a sync unless one ran recently (`force` ignores that).
    func start(client: PlexServerClient, force: Bool = false) {
        if isSyncing { return }
        if !force, let lastSync, Date().timeIntervalSince(lastSync) < 600 { return }
        task = Task { await run(client: client) }
    }

    private func run(client: PlexServerClient) async {
        isSyncing = true
        progress = 0
        message = "جارٍ مزامنة المكتبة…"
        defer { isSyncing = false; isFirstSync = false; lastSync = Date() }

        let server = client.machineIdentifier
        let library = LocalLibrary.shared
        await library.open(server: server)

        guard let stamps = try? await Self.sectionStamps(client) else { return }
        let video = stamps.filter { $0.type == "movie" || $0.type == "show" }
        await library.prune(server: server, keeping: Set(video.map(\.key)))

        var anyStored = false
        for stamp in video {
            if await library.hasSection(server: server, key: stamp.key) { anyStored = true }
        }
        isFirstSync = !anyStored

        var changed = false
        for (i, stamp) in video.enumerated() {
            let base = Double(i) / Double(max(video.count, 1))
            let span = 1 / Double(max(video.count, 1))
            message = "مزامنة «\(stamp.title)»…"
            progress = base
            let existing = await library.section(server: server, key: stamp.key)
            if let existing, let c = stamp.contentChangedAt, existing.contentChangedAt == c { continue }
            let report: @Sendable (Double) -> Void = { fraction in
                Task { @MainActor in LibrarySync.shared.progress = base + span * min(fraction, 1) }
            }
            guard let fresh = try? await Self.sync(client: client, stamp: stamp, existing: existing, report: report) else { continue }
            await library.store(fresh, server: server)
            changed = true
        }
        progress = 1
        message = ""
        if changed {
            NotificationCenter.default.post(name: .localLibraryDidChange, object: nil)
        }
        await prefetchArtwork(client: client)
    }

    /// Posters of the newest titles of every library, so the first screens draw from disk.
    private func prefetchArtwork(client: PlexServerClient) async {
        let server = client.machineIdentifier
        var urls: [URL] = []
        for stamp in (try? await Self.sectionStamps(client)) ?? [] {
            let items = await LocalLibrary.shared.recentlyAdded(server: server, section: stamp.key, limit: 40) ?? []
            urls += items.compactMap { client.posterURL($0) }
        }
        await ImageLoader.shared.prefetch(urls)
    }

    // MARK: Server requests (off the main actor)

    struct SectionStamp: Decodable {
        let key: String
        let type: String
        let title: String
        let contentChangedAt: Int?

        enum CodingKeys: String, CodingKey { case key, type, title, contentChangedAt }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = c.lenientString(forKey: .key) ?? ""
            type = c.lenientString(forKey: .type) ?? ""
            title = c.lenientString(forKey: .title) ?? ""
            contentChangedAt = c.lenientInt(forKey: .contentChangedAt)
        }
    }

    private struct StampResponse: Decodable {
        struct Container: Decodable {
            let directories: [SectionStamp]
            enum CodingKeys: String, CodingKey { case directories = "Directory" }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                directories = c.lossyArray(SectionStamp.self, forKey: .directories) ?? []
            }
        }
        let mediaContainer: Container
        enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    }

    nonisolated private static func sectionStamps(_ client: PlexServerClient) async throws -> [SectionStamp] {
        guard let url = client.url("/library/sections") else { throw PlexError.invalidURL }
        let data = try await PlexHTTP.data(for: PlexHTTP.request(url, token: client.token))
        return try JSONDecoder().decode(StampResponse.self, from: data).mediaContainer.directories
    }

    nonisolated private static func page(_ client: PlexServerClient, section: String, type: Int, start: Int, size: Int,
                                         extra: [(String, String)] = []) async throws -> MediaContainer {
        let q: [(String, String)] = [("type", "\(type)"), ("includeGuids", "1"),
                                     ("X-Plex-Container-Start", "\(start)"), ("X-Plex-Container-Size", "\(size)")] + extra
        guard let url = client.url("/library/sections/\(section)/all", q) else { throw PlexError.invalidURL }
        let data = try await PlexHTTP.data(for: PlexHTTP.request(url, token: client.token))
        return try JSONDecoder().decode(MediaContainerResponse.self, from: data).mediaContainer
    }

    nonisolated private static func count(_ client: PlexServerClient, section: String, type: Int) async throws -> Int {
        let c = try await page(client, section: section, type: type, start: 0, size: 0)
        return c.totalSize ?? c.size ?? 0
    }

    /// Every item of one type, in pages of 500.
    nonisolated private static func all(_ client: PlexServerClient, section: String, type: Int,
                                        extra: [(String, String)] = [], report: (Int, Int) -> Void = { _, _ in }) async throws -> [PlexItem] {
        var out: [PlexItem] = []
        var start = 0
        while true {
            try Task.checkCancellation()
            let c = try await page(client, section: section, type: type, start: start, size: 500, extra: extra)
            out += c.metadata
            start += c.metadata.count
            let total = c.totalSize ?? c.size ?? 0
            report(start, total)
            if c.metadata.isEmpty || start >= total { break }
        }
        return out
    }

    /// Full fetch the first time; then only items updated since the last sync, falling back to a
    /// full fetch of that type when the item count shows something was removed.
    nonisolated private static func sync(client: PlexServerClient, stamp: SectionStamp, existing: LocalSection?,
                                         report: @escaping @Sendable (Double) -> Void) async throws -> LocalSection {
        let key = stamp.key
        func merged(_ old: [PlexItem], type: Int, weight: (Double, Double)) async throws -> [PlexItem] {
            let progress: (Int, Int) -> Void = { done, total in
                report(weight.0 + weight.1 * (total > 0 ? Double(done) / Double(total) : 1))
            }
            guard let existing, !old.isEmpty else {
                return try await all(client, section: key, type: type, report: progress)
            }
            async let total = count(client, section: key, type: type)
            let changed = try await all(client, section: key, type: type,
                                        extra: [("updatedAt>>", "\(existing.highWater)")], report: progress)
            var byKey = Dictionary(old.map { ($0.ratingKey, $0) }, uniquingKeysWith: { _, b in b })
            for item in changed { byKey[item.ratingKey] = item }
            if byKey.count != (try await total) {
                return try await all(client, section: key, type: type, report: progress)
            }
            // Keep the previous order for stability; new items at the end.
            var seen = Set<String>()
            var out = old.compactMap { item -> PlexItem? in seen.insert(item.ratingKey).inserted ? byKey[item.ratingKey] : nil }
            out += changed.filter { seen.insert($0.ratingKey).inserted }
            return out
        }

        var section = LocalSection(key: key, type: stamp.type, contentChangedAt: stamp.contentChangedAt,
                                   highWater: existing?.highWater ?? 0, items: [], seasons: [], episodes: [])
        if stamp.type == "movie" {
            section.items = try await merged(existing?.items ?? [], type: 1, weight: (0, 1))
        } else {
            // Shows and seasons are few: always in full (their episode counts change).
            section.items = try await all(client, section: key, type: 2) { d, t in report(0.1 * (t > 0 ? Double(d) / Double(t) : 1)) }
            section.seasons = try await all(client, section: key, type: 3) { d, t in report(0.1 + 0.1 * (t > 0 ? Double(d) / Double(t) : 1)) }
            section.episodes = try await merged(existing?.episodes ?? [], type: 4, weight: (0.2, 0.8))
        }
        let newest = (section.items + section.seasons + section.episodes).compactMap { $0.updatedAt ?? $0.addedAt }.max() ?? 0
        section.highWater = max(section.highWater, newest)
        return section
    }
}

extension Notification.Name {
    /// The background sync stored new or changed items.
    static let localLibraryDidChange = Notification.Name("localLibraryDidChange")
}
