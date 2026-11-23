import Foundation
import Observation

// Infuse-style on-device library. Only the libraries enabled by a profile on this device are
// downloaded. Movies, shows and seasons of a library are kept in one small file (and in memory
// for browsing); the episodes of each show are in their own file, read only when that show is
// opened. Downloads are memory-safe: shows are fetched one at a time (two in parallel at most),
// written to disk and released; nothing ever holds a whole library's episodes.

/// One library as stored on the device. Items are kept as Plex sent them (Plex's shared
/// progress values are replaced by the active profile's when read, like every response).
struct LocalSection: Codable {
    var key: String
    var type: String
    var title: String
    /// Plex's `contentChangedAt` when the library was last complete (unchanged = nothing to fetch).
    var contentChangedAt: Int?
    /// Newest `updatedAt` seen, the starting point of the next incremental download.
    var highWater: Int
    /// Movies, or shows.
    var items: [PlexItem]
    var seasons: [PlexItem]
    /// show → episodes stored (compared with the show's `leafCount` to find changed shows).
    var episodeCounts: [String: Int]
    /// show → newest episode `addedAt`.
    var latestAdded: [String: Int]
    /// show → newest episode air date ("yyyy-MM-dd").
    var latestAired: [String: String]
    /// episode → show (which file holds it).
    var episodeShows: [String: String]
    /// Last time a profile on this device had the library enabled (hidden ones are purged later).
    var lastWanted: Date
    /// The first download finished (an interrupted one resumes where it stopped).
    var complete: Bool

    init(key: String, type: String, title: String) {
        self.key = key
        self.type = type
        self.title = title
        contentChangedAt = nil
        highWater = 0
        items = []
        seasons = []
        episodeCounts = [:]
        latestAdded = [:]
        latestAired = [:]
        episodeShows = [:]
        lastWanted = Date()
        complete = false
    }
}

/// Lookup tables over the stored libraries (no episodes: those stay on disk).
private struct LibraryIndex {
    var sections: [String: LocalSection] = [:]
    var byKey: [String: PlexItem] = [:]
    /// show → seasons (in order).
    var seasonsOf: [String: [PlexItem]] = [:]
    /// show → library key (where its episode file is).
    var showSection: [String: String] = [:]

    init() {}

    init(sections: [String: LocalSection]) {
        self.sections = sections
        for section in sections.values {
            for item in section.items where byKey[item.ratingKey] == nil {
                byKey[item.ratingKey] = item
                if item.isShow { showSection[item.ratingKey] = section.key }
            }
            for season in section.seasons where byKey[season.ratingKey] == nil {
                byKey[season.ratingKey] = season
                if let show = season.parentRatingKey { seasonsOf[show, default: []].append(season) }
            }
        }
        for key in seasonsOf.keys { seasonsOf[key]?.sort { ($0.index ?? 0) < ($1.index ?? 0) } }
    }

    func section(ofShow show: String) -> LocalSection? {
        showSection[show].flatMap { sections[$0] }
    }

    func addedKey(_ item: PlexItem) -> Int {
        max(item.addedAt ?? 0, section(ofShow: item.ratingKey)?.latestAdded[item.ratingKey] ?? 0)
    }
}

actor LocalLibrary {
    static let shared = LocalLibrary()

    private var serverID: String?
    private var index = LibraryIndex()
    private var loadTask: Task<Void, Never>?
    /// A few recently opened shows' episodes.
    private var episodeCache: [String: [PlexItem]] = [:]
    private var cacheOrder: [String] = []

    // MARK: Files

    private static let root: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLibrary", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func serverDirectory(_ server: String) -> URL {
        root.appendingPathComponent(server, isDirectory: true)
    }

    static func sectionDirectory(_ server: String, _ section: String) -> URL {
        serverDirectory(server).appendingPathComponent(section, isDirectory: true)
    }

    static func episodeFile(_ server: String, _ section: String, show: String) -> URL {
        sectionDirectory(server, section).appendingPathComponent("episodes", isDirectory: true)
            .appendingPathComponent("\(show).json")
    }

    static func writeEpisodes(_ episodes: [PlexItem], server: String, section: String, show: String) {
        let file = episodeFile(server, section, show: show)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(episodes) { try? data.write(to: file, options: .atomic) }
    }

    static func readEpisodes(server: String, section: String, show: String) -> [PlexItem]? {
        guard let data = try? Data(contentsOf: episodeFile(server, section, show: show)) else { return nil }
        return try? JSONDecoder().decode([PlexItem].self, from: data)
    }

    // MARK: Loading

    /// Loads the server's stored libraries from disk (off the actor); reads answer nil until then.
    func open(server: String) async {
        if serverID == server { await loadTask?.value; return }
        serverID = server
        index = LibraryIndex()
        episodeCache = [:]
        cacheOrder = []
        let read = Task.detached(priority: .utility) { () -> [String: LocalSection] in
            let fm = FileManager.default
            let dir = Self.serverDirectory(server)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var out: [String: LocalSection] = [:]
            let decoder = JSONDecoder()
            for entry in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                if entry.pathExtension == "json" {
                    // Earlier builds kept whole libraries (every episode) in one file.
                    try? fm.removeItem(at: entry)
                    continue
                }
                guard let data = try? Data(contentsOf: entry.appendingPathComponent("meta.json")),
                      let section = try? decoder.decode(LocalSection.self, from: data) else { continue }
                out[section.key] = section
            }
            return out
        }
        let wait = Task {
            let sections = await read.value
            await self.install(sections, server: server)
        }
        loadTask = wait
        await wait.value
    }

    private func install(_ sections: [String: LocalSection], server: String) async {
        guard serverID == server else { return }
        let built = await Task.detached(priority: .utility) { LibraryIndex(sections: sections) }.value
        guard serverID == server else { return }
        index = built
    }

    // MARK: Writing (from the download)

    func section(server: String, key: String) -> LocalSection? {
        guard serverID == server else { return nil }
        return index.sections[key]
    }

    var storedSectionKeys: [String] { Array(index.sections.keys) }

    func store(_ section: LocalSection, server: String, changedShows: [String] = []) async {
        guard serverID == server else { return }
        var sections = index.sections
        sections[section.key] = section
        let built = await Task.detached(priority: .utility) { LibraryIndex(sections: sections) }.value
        guard serverID == server else { return }
        index = built
        for show in changedShows { episodeCache[show] = nil }
        cacheOrder.removeAll { episodeCache[$0] == nil }
        let dir = Self.sectionDirectory(server, section.key)
        await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(section) {
                try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
            }
        }.value
    }

    /// Deletes a library's local copy.
    func remove(server: String, key: String) {
        guard serverID == server, index.sections[key] != nil else { return }
        var sections = index.sections
        sections[key] = nil
        index = LibraryIndex(sections: sections)
        episodeCache = [:]
        cacheOrder = []
        try? FileManager.default.removeItem(at: Self.sectionDirectory(server, key))
    }

    // MARK: Reading (nil = not on the device: the caller asks the server)

    func hasSection(server: String, key: String) -> Bool {
        serverID == server && index.sections[key] != nil
    }

    func item(server: String, key: String) -> PlexItem? {
        guard serverID == server else { return nil }
        if let item = index.byKey[key] { return item }
        // An episode: from its show's file.
        for section in index.sections.values {
            if let show = section.episodeShows[key] {
                return episodes(server: server, show: show)?.first { $0.ratingKey == key }
            }
        }
        return nil
    }

    func items(server: String, section: String, sort: LibrarySort, start: Int, size: Int) -> (items: [PlexItem], total: Int)? {
        guard serverID == server, let stored = index.sections[section], stored.complete || !stored.items.isEmpty else { return nil }
        let sorted = Self.sorted(stored.items.uniqued(), by: sort, index: index)
        let lower = min(start, sorted.count)
        let upper = min(lower + max(size, 0), sorted.count)
        return (Array(sorted[lower..<upper]), sorted.count)
    }

    func recentlyAdded(server: String, section: String, limit: Int) -> [PlexItem]? {
        guard serverID == server, let stored = index.sections[section], stored.complete else { return nil }
        return Array(Self.sorted(stored.items.uniqued(), by: .recentlyAdded, index: index).prefix(limit))
    }

    /// Seasons of a show, or episodes of a season.
    func children(server: String, of key: String) -> [PlexItem]? {
        guard serverID == server, let parent = index.byKey[key] else { return nil }
        if parent.isShow {
            guard index.section(ofShow: key)?.episodeCounts[key] != nil else { return nil }
            return index.seasonsOf[key] ?? []
        }
        guard parent.isSeason, let show = parent.parentRatingKey,
              let all = episodes(server: server, show: show) else { return nil }
        return all.filter { $0.parentRatingKey == key }.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
    }

    func leaves(server: String, show: String) -> [PlexItem]? {
        guard serverID == server, index.byKey[show]?.isShow == true else { return nil }
        return episodes(server: server, show: show)
    }

    /// Newest episode air date of a show ("yyyy-MM-dd").
    func latestAired(server: String, show: String) -> String? {
        guard serverID == server else { return nil }
        return index.section(ofShow: show)?.latestAired[show]
    }

    /// Movies and shows whose title matches `query`, nil before the first download.
    func search(server: String, query: String, sections keys: Set<String>?, limit: Int = 60) -> [PlexItem]? {
        guard serverID == server, index.sections.values.contains(where: \.complete) else { return nil }
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var titles: [PlexItem] = []
        for section in index.sections.values where keys?.contains(section.key) ?? true {
            titles += section.items.filter {
                $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(q)
            }
        }
        titles.sort { ($0.title.count, $0.title) < ($1.title.count, $1.title) }
        return Array(titles.uniqued().prefix(limit))
    }

    /// A show's episodes in order, from its file (a few shows are kept in memory).
    private func episodes(server: String, show: String) -> [PlexItem]? {
        if let cached = episodeCache[show] { return cached }
        guard let section = index.section(ofShow: show), section.episodeCounts[show] != nil,
              let stored = Self.readEpisodes(server: server, section: section.key, show: show) else { return nil }
        let sorted = stored.uniqued().sorted {
            (($0.parentIndex ?? 0), ($0.index ?? 0)) < (($1.parentIndex ?? 0), ($1.index ?? 0))
        }
        episodeCache[show] = sorted
        cacheOrder.removeAll { $0 == show }
        cacheOrder.append(show)
        while cacheOrder.count > 8 { episodeCache[cacheOrder.removeFirst()] = nil }
        return sorted
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

// MARK: - Download

/// Background download of the enabled libraries, with (throttled) progress for the UI.
@MainActor
@Observable
final class LibrarySync {
    static let shared = LibrarySync()

    private(set) var isSyncing = false
    /// 0…1 while downloading.
    private(set) var progress: Double = 0
    private(set) var message = ""
    /// A library is being downloaded for the first time (shows the progress pill).
    private(set) var isFirstSync = false
    private(set) var lastSync: Date?

    /// Hidden libraries keep their local copy this long (in case they're enabled again).
    private static let purgeAfter: TimeInterval = 7 * 86_400

    private var task: Task<Void, Never>?
    private var pendingRerun = false

    /// Starts a download unless one ran recently (`force` ignores that). A request while one is
    /// running (e.g. a library was just enabled) runs again right after it.
    func start(client: PlexServerClient, force: Bool = false) {
        if isSyncing {
            if force { pendingRerun = true }
            return
        }
        if !force, let lastSync, Date().timeIntervalSince(lastSync) < 600 { return }
        task = Task { await run(client: client) }
    }

    /// Libraries enabled by any profile on this device.
    static func wantedSections() -> Set<String> {
        Set(ProfileStore.shared.profiles.flatMap { $0.scopes.compactMap { ScopeID(raw: $0)?.sectionKey } })
    }

    private func run(client: PlexServerClient) async {
        isSyncing = true
        progress = 0
        message = ""
        defer {
            isSyncing = false
            isFirstSync = false
            lastSync = Date()
            if pendingRerun {
                pendingRerun = false
                start(client: client, force: true)
            }
        }

        let server = client.machineIdentifier
        let library = LocalLibrary.shared
        await library.open(server: server)

        let wanted = Self.wantedSections()
        guard !wanted.isEmpty, let stamps = try? await Self.sectionStamps(client) else { return }
        let onServer = Set(stamps.map(\.key))
        let video = stamps.filter { ($0.type == "movie" || $0.type == "show") && wanted.contains($0.key) }

        // Hidden libraries: no more refreshes; purged once hidden for a week (or gone from the server).
        for key in await library.storedSectionKeys where !wanted.contains(key) {
            let stored = await library.section(server: server, key: key)
            if !onServer.contains(key) || Date().timeIntervalSince(stored?.lastWanted ?? .distantPast) > Self.purgeAfter {
                await library.remove(server: server, key: key)
            }
        }

        var changed = false
        for (i, stamp) in video.enumerated() {
            let existing = await library.section(server: server, key: stamp.key)
            if let existing, existing.complete, let c = stamp.contentChangedAt, existing.contentChangedAt == c {
                if Date().timeIntervalSince(existing.lastWanted) > 86_400 {
                    var touched = existing
                    touched.lastWanted = Date()
                    await library.store(touched, server: server)
                }
                continue
            }
            isFirstSync = existing?.complete != true
            message = "تحميل المكتبة «\(stamp.title)»…"
            let base = Double(i) / Double(video.count)
            let span = 1 / Double(video.count)
            progress = base
            let report: @Sendable (Double) -> Void = { fraction in
                Task { @MainActor in
                    LibrarySync.shared.progress = base + span * min(max(fraction, 0), 1)
                }
            }
            do {
                try await Self.download(client: client, stamp: stamp, existing: existing, library: library, report: report)
                changed = true
            } catch {
                // Offline / server busy: what was saved so far stays; the next run resumes.
            }
        }
        progress = 1
        message = ""
        if changed { NotificationCenter.default.post(name: .localLibraryDidChange, object: nil) }
        await prefetchArtwork(client: client, sections: video.map(\.key))
    }

    /// Posters of the newest titles of the enabled libraries, so the first screens draw from disk.
    private func prefetchArtwork(client: PlexServerClient, sections: [String]) async {
        var urls: [URL] = []
        for key in sections {
            let items = await LocalLibrary.shared.recentlyAdded(server: client.machineIdentifier, section: key, limit: 30) ?? []
            urls += items.compactMap { client.posterURL($0) }
        }
        await ImageLoader.shared.prefetch(urls, concurrency: 3)
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

    nonisolated private static func fetch(_ client: PlexServerClient, _ path: String, _ query: [(String, String)]) async throws -> MediaContainer {
        guard let url = client.url(path, query) else { throw PlexError.invalidURL }
        let data = try await PlexHTTP.data(for: PlexHTTP.request(url, token: client.token))
        return try JSONDecoder().decode(MediaContainerResponse.self, from: data).mediaContainer
    }

    nonisolated private static func count(_ client: PlexServerClient, section: String, type: Int) async throws -> Int {
        let c = try await fetch(client, "/library/sections/\(section)/all",
                                [("type", "\(type)"), ("X-Plex-Container-Start", "0"), ("X-Plex-Container-Size", "0")])
        return c.totalSize ?? c.size ?? 0
    }

    /// Every item of one type, in pages of 200 (movies, shows or seasons; never episodes).
    nonisolated private static func all(_ client: PlexServerClient, section: String, type: Int,
                                        extra: [(String, String)] = [],
                                        report: (Int, Int) -> Void = { _, _ in }) async throws -> [PlexItem] {
        var out: [PlexItem] = []
        var start = 0
        while true {
            try Task.checkCancellation()
            let c = try await fetch(client, "/library/sections/\(section)/all",
                                    [("type", "\(type)"), ("includeGuids", "1"),
                                     ("X-Plex-Container-Start", "\(start)"), ("X-Plex-Container-Size", "200")] + extra)
            out += c.metadata
            start += c.metadata.count
            let total = c.totalSize ?? c.size ?? 0
            report(start, total)
            if c.metadata.isEmpty || start >= total { break }
        }
        // Paging can repeat an item when the library changes meanwhile.
        return out.uniqued()
    }

    /// One show's episodes.
    nonisolated private static func leaves(_ client: PlexServerClient, show: String, section: String) async throws -> [PlexItem] {
        let c = try await fetch(client, "/library/metadata/\(show)/allLeaves", [("includeGuids", "1")])
        return c.metadata.filter(\.isEpisode).uniqued().map { item in
            guard item.librarySectionID == nil else { return item }
            var copy = item
            copy.librarySectionID = section
            return copy
        }
    }

    nonisolated private static func download(client: PlexServerClient, stamp: SectionStamp, existing: LocalSection?,
                                             library: LocalLibrary, report: @escaping @Sendable (Double) -> Void) async throws {
        let server = client.machineIdentifier
        var section = existing ?? LocalSection(key: stamp.key, type: stamp.type, title: stamp.title)
        section.title = stamp.title
        let previousHighWater = section.highWater

        if stamp.type == "movie" {
            if let existing, existing.complete, !existing.items.isEmpty {
                // Only what changed; everything again if something was removed.
                async let total = count(client, section: stamp.key, type: 1)
                let changed = try await all(client, section: stamp.key, type: 1,
                                            extra: [("updatedAt>>", "\(previousHighWater)")])
                var byKey = Dictionary(existing.items.map { ($0.ratingKey, $0) }, uniquingKeysWith: { a, _ in a })
                for item in changed { byKey[item.ratingKey] = item }
                if byKey.count != (try await total) {
                    section.items = try await all(client, section: stamp.key, type: 1) { d, t in
                        report(t > 0 ? Double(d) / Double(t) : 1)
                    }
                } else {
                    var seen = Set<String>()
                    section.items = existing.items.compactMap { seen.insert($0.ratingKey).inserted ? byKey[$0.ratingKey] : nil }
                        + changed.filter { seen.insert($0.ratingKey).inserted }
                }
            } else {
                section.items = try await all(client, section: stamp.key, type: 1) { d, t in
                    report(t > 0 ? Double(d) / Double(t) : 1)
                }
            }
            section.highWater = max(previousHighWater, section.items.compactMap { $0.updatedAt ?? $0.addedAt }.max() ?? 0)
            section.contentChangedAt = stamp.contentChangedAt
            section.complete = true
            section.lastWanted = Date()
            await library.store(section, server: server)
            return
        }

        // Shows and seasons in full (small), then episodes show by show.
        let shows = try await all(client, section: stamp.key, type: 2)
        section.items = shows
        section.seasons = try await all(client, section: stamp.key, type: 3)
        report(0.05)

        // Shows no longer on the server.
        let current = Set(shows.map(\.ratingKey))
        for gone in section.episodeCounts.keys where !current.contains(gone) {
            try? FileManager.default.removeItem(at: LocalLibrary.episodeFile(server, stamp.key, show: gone))
            section.episodeCounts[gone] = nil
            section.latestAdded[gone] = nil
            section.latestAired[gone] = nil
        }
        section.episodeShows = section.episodeShows.filter { current.contains($0.value) }

        // Shows whose episodes changed (new / removed episodes, or edited since last time).
        let todo = shows.filter { show in
            guard let stored = section.episodeCounts[show.ratingKey] else { return true }
            return stored != (show.leafCount ?? stored) || (show.updatedAt ?? 0) > previousHighWater
        }

        var done = 0
        var changedShows: [String] = []
        // Two shows at a time; each show's episodes are written to disk and released.
        for start in stride(from: 0, to: todo.count, by: 2) {
            try Task.checkCancellation()
            let batch = Array(todo[start..<min(start + 2, todo.count)])
            let results = await withTaskGroup(of: (String, [PlexItem]?).self) { group in
                for show in batch {
                    group.addTask { (show.ratingKey, try? await leaves(client, show: show.ratingKey, section: stamp.key)) }
                }
                var out: [(String, [PlexItem]?)] = []
                for await result in group { out.append(result) }
                return out
            }
            for (show, episodes) in results {
                guard let episodes else { continue }
                LocalLibrary.writeEpisodes(episodes, server: server, section: stamp.key, show: show)
                if section.episodeCounts[show] != nil {
                    // Updating a show: forget its old episodes first (first downloads skip this).
                    section.episodeShows = section.episodeShows.filter { $0.value != show }
                }
                for episode in episodes { section.episodeShows[episode.ratingKey] = show }
                section.episodeCounts[show] = episodes.count
                section.latestAdded[show] = episodes.compactMap(\.addedAt).max()
                section.latestAired[show] = episodes.compactMap(\.originallyAvailableAt).max()
                changedShows.append(show)
            }
            done += batch.count
            if done % 10 == 0 || done == todo.count {
                report(0.05 + 0.95 * Double(done) / Double(max(todo.count, 1)))
            }
            // Save progress now and then, so the library fills in and an interruption resumes here.
            if done % 100 == 0 {
                await library.store(section, server: server, changedShows: changedShows)
                changedShows = []
            }
        }

        section.highWater = max(previousHighWater, (shows + section.seasons).compactMap { $0.updatedAt ?? $0.addedAt }.max() ?? 0)
        section.contentChangedAt = stamp.contentChangedAt
        section.complete = true
        section.lastWanted = Date()
        await library.store(section, server: server, changedShows: changedShows)
    }
}

extension Notification.Name {
    /// The background download stored new or changed items.
    static let localLibraryDidChange = Notification.Name("localLibraryDidChange")
}
