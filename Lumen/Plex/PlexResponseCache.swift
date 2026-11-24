import CryptoKit
import Foundation

/// On-disk copy of every Plex server response (library lists, metadata, hubs…), so screens can
/// show the last known library instantly and refresh it in the background
/// (stale-while-revalidate). Stored in Caches; the system may purge it, which only costs speed.
enum PlexResponseCache {
    enum Policy: Sendable {
        /// Normal: fetch from the server and save the response.
        case network
        /// Answer only from disk (no network); a miss throws.
        case cacheOnly
    }

    /// Set around a whole screen load: `PlexResponseCache.$policy.withValue(.cacheOnly) { … }`.
    @TaskLocal static var policy: Policy = .network

    private static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlexResponses", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Per server + path + query (the token travels in a header, so it's never part of the key).
    private static func file(server: String, path: String, query: [(String, String)]) -> URL {
        let q = query.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let digest = SHA256.hash(data: Data("\(server)|\(path)|\(q)".utf8))
        return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined() + ".json")
    }

    static func read(server: String, path: String, query: [(String, String)]) -> Data? {
        try? Data(contentsOf: file(server: server, path: path, query: query))
    }

    static func write(_ data: Data, server: String, path: String, query: [(String, String)]) {
        try? data.write(to: file(server: server, path: path, query: query), options: .atomic)
    }

    /// Keeps the cache under `limit` bytes, dropping the least recently written responses.
    static func trim(limit: Int = 300 * 1024 * 1024) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > limit else { return }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > limit {
            try? fm.removeItem(at: url)
            total -= size
        }
    }

    static func size() -> Int { size(of: directory) }

    /// Bytes of the files in a folder.
    static func size(of folder: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func clear() {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
    }
}

/// The server, connection and libraries last used, so the next launch can open straight away
/// instead of asking plex.tv and probing every connection first. The server's access token is
/// kept in the Keychain, not here.
struct CachedServer: Codable {
    var id: String
    var name: String
    var uri: String
    var isLocal: Bool
    var sections: [PlexDirectory]
    var user: PlexUser?

    private static let key = "plex.cachedServer"

    static func load() -> CachedServer? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CachedServer.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
