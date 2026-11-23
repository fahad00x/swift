import CryptoKit
import UIKit

/// Artwork cache: memory, then disk (Caches/Artwork), then network.
/// Disk entries are keyed without the host and the token, so a poster saved over the local
/// connection is reused over the remote one (and after the token changes).
actor ImageLoader {
    static let shared = ImageLoader()

    private let memory = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    private let session: URLSession
    private let directory: URL
    /// Trim the disk cache back to this size (oldest files first) once per launch.
    private let diskLimit: Int = 600 * 1024 * 1024

    init() {
        memory.countLimit = 300
        // Bound decoded memory rather than item count alone (the system also empties it under pressure).
        memory.totalCostLimit = 160 * 1024 * 1024
        #if canImport(UIKit)
        let cache = memory
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: nil) { _ in cache.removeAllObjects() }
        #endif
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config)
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dir = directory, limit = diskLimit
        Task.detached(priority: .background) { Self.trim(dir, limit: limit) }
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = memory.object(forKey: url as NSURL) { return cached }
        if let task = inFlight[url] { return await task.value }

        let session = self.session
        let file = diskFile(for: url)
        let task = Task<UIImage?, Never>.detached(priority: .userInitiated) {
            if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
                return image.preparingForDisplay() ?? image
            }
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  let image = UIImage(data: data) else { return nil }
            try? data.write(to: file, options: .atomic)
            // Decode now (off the main thread) so large images don't stutter animations when first drawn.
            return image.preparingForDisplay() ?? image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
            memory.setObject(image, forKey: url as NSURL, cost: cost)
            // Synchronous copy for views appearing on this artwork (first frame, no black).
            ImageMemo.shared.cache.setObject(image, forKey: url as NSURL)
        }
        return image
    }

    /// Downloads artwork to the disk cache only (no decoding), a few at a time; skips what's there.
    func prefetch(_ urls: [URL], concurrency: Int = 6) async {
        let session = self.session
        let pending = urls.map { ($0, diskFile(for: $0)) }
            .filter { !FileManager.default.fileExists(atPath: $0.1.path) }
        guard !pending.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for (i, entry) in pending.enumerated() {
                if i >= concurrency { _ = await group.next() }
                let (url, file) = entry
                group.addTask(priority: .background) {
                    guard let (data, response) = try? await session.data(from: url),
                          (response as? HTTPURLResponse)?.statusCode ?? 200 < 400, !data.isEmpty else { return }
                    try? data.write(to: file, options: .atomic)
                }
            }
        }
    }

    private func diskFile(for url: URL) -> URL {
        var key = url.path
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = components.queryItems?
                .filter { $0.name != "X-Plex-Token" }
                .sorted { $0.name < $1.name }
            key += "?" + (components.percentEncodedQuery ?? "")
        }
        let digest = SHA256.hash(data: Data(key.utf8))
        return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined())
    }

    private static func trim(_ dir: URL, limit: Int) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
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
}
