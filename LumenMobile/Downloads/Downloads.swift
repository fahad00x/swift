import Foundation
import Observation
import UIKit

// «التنزيلات»: the original file of a movie or an episode, saved on the device to watch without
// a connection. The file is the server's own (every format plays in the MPV player), with the
// Plex sidecar subtitles and the artwork next to it. Downloads keep going in the background and
// resume where they stopped. Progress and watched marks go to the profile as usual (saved on
// the device, synced with iCloud once there's a connection).

/// One title on the device.
struct DownloadEntry: Codable, Identifiable, Hashable {
    enum State: String, Codable { case waiting, downloading, done, failed }

    /// Plex rating key of the movie or episode.
    let ratingKey: String
    /// Full details as they were (tracks, chapters, markers), used to play without the server.
    var item: PlexItem
    var serverID: String
    var state: State
    var written: Int64 = 0
    var total: Int64 = 0
    var addedAt = Date()
    /// File names inside the title's folder.
    var fileName: String?
    var subtitleFiles: [String: String] = [:]
    var posterFile: String?
    var backdropFile: String?
    var error: String?

    var id: String { ratingKey }
    var fraction: Double { total > 0 ? min(1, Double(written) / Double(total)) : 0 }
}

@MainActor
@Observable
final class Downloads {
    static let shared = Downloads()

    private(set) var entries: [String: DownloadEntry] = [:]

    /// Newest first.
    var list: [DownloadEntry] { entries.values.sorted { $0.addedAt > $1.addedAt } }
    var usedBytes: Int64 { entries.values.reduce(0) { $0 + ($1.state == .done ? $1.total : $1.written) } }

    /// Set by the app delegate when the system wakes the app for finished background downloads.
    @ObservationIgnored var backgroundCompletion: (() -> Void)?

    static let sessionID = "com.fahad00x.lumen.downloads"

    @ObservationIgnored private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        return URLSession(configuration: configuration, delegate: bridge, delegateQueue: nil)
    }()
    @ObservationIgnored private let bridge = DownloadBridge()
    @ObservationIgnored private var lastSave = Date.distantPast

    private init() {
        load()
        bridge.owner = self
        // Reattach to what the system kept downloading while the app was closed.
        session.getAllTasks { tasks in
            let running = Set(tasks.compactMap(\.taskDescription))
            Task { @MainActor in
                for key in self.entries.keys where self.entries[key]?.state == .downloading && !running.contains(key) {
                    // Stopped while closed (no task left): try again from where it was.
                    self.resume(key)
                }
            }
        }
    }

    // MARK: Asking

    func entry(_ ratingKey: String) -> DownloadEntry? { entries[ratingKey] }

    /// The saved file, once it's complete.
    func localFile(_ ratingKey: String) -> URL? {
        guard let entry = entries[ratingKey], entry.state == .done, let name = entry.fileName else { return nil }
        let url = Self.folder(ratingKey).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func localSubtitle(_ ratingKey: String, streamKey: String) -> URL? {
        guard let name = entries[ratingKey]?.subtitleFiles[streamKey] else { return nil }
        return Self.folder(ratingKey).appendingPathComponent(name)
    }

    func image(_ ratingKey: String, backdrop: Bool = false) -> UIImage? {
        guard let entry = entries[ratingKey], let name = backdrop ? (entry.backdropFile ?? entry.posterFile) : entry.posterFile
        else { return nil }
        return UIImage(contentsOfFile: Self.folder(ratingKey).appendingPathComponent(name).path)
    }

    // MARK: Starting

    /// Movies and episodes (a show or season: each of its episodes).
    func download(_ item: PlexItem, client: PlexServerClient) async {
        if item.isShow || item.isSeason {
            let episodes = item.isShow ? await client.allLeaves(item.ratingKey)
                                       : ((try? await client.children(item.ratingKey)) ?? [])
            for episode in episodes where entries[episode.ratingKey] == nil {
                await download(episode, client: client)
            }
            return
        }
        guard entries[item.ratingKey]?.state != .done, entries[item.ratingKey]?.state != .downloading else { return }
        let full = (try? await client.metadata(item.ratingKey)) ?? item
        guard let part = full.primaryPart, let partKey = part.key, let url = client.directURL(partKey: partKey) else {
            return
        }
        let ext = (part.container ?? full.media.first?.container ?? "mkv").lowercased()
        var entry = DownloadEntry(ratingKey: full.ratingKey, item: full, serverID: client.machineIdentifier,
                                  state: .downloading, total: Int64(part.size ?? 0))
        entry.fileName = "video.\(ext)"
        entries[full.ratingKey] = entry
        save(now: true)
        try? FileManager.default.createDirectory(at: Self.folder(full.ratingKey), withIntermediateDirectories: true)

        let task = session.downloadTask(with: url)
        task.taskDescription = full.ratingKey
        if entry.total > 0 { task.countOfBytesClientExpectsToReceive = entry.total }
        task.resume()

        // The small things next to it, while the file downloads.
        await saveExtras(full, client: client)
    }

    private func saveExtras(_ item: PlexItem, client: PlexServerClient) async {
        let folder = Self.folder(item.ratingKey)
        var subtitles: [String: String] = [:]
        for (index, stream) in item.subtitleStreams.enumerated() {
            guard let key = stream.key, let url = client.url(key, includeToken: true),
                  let (data, _) = try? await URLSession.shared.data(from: url) else { continue }
            let ext = (stream.codec ?? "srt").lowercased()
            let name = "sub-\(index).\(ext)"
            if (try? data.write(to: folder.appendingPathComponent(name))) != nil { subtitles[key] = name }
        }
        let poster = await saveImage(client.posterURL(item), to: folder.appendingPathComponent("poster.jpg"))
        let backdrop = await saveImage(client.imageURL(item.landscapePath ?? item.backdropPath, width: 1280, height: 720),
                                       to: folder.appendingPathComponent("backdrop.jpg"))
        guard var entry = entries[item.ratingKey] else { return }
        entry.subtitleFiles = subtitles
        entry.posterFile = poster ? "poster.jpg" : nil
        entry.backdropFile = backdrop ? "backdrop.jpg" : nil
        entries[item.ratingKey] = entry
        save(now: true)
    }

    private func saveImage(_ url: URL?, to file: URL) async -> Bool {
        guard let url, let (data, _) = try? await URLSession.shared.data(from: url) else { return false }
        return (try? data.write(to: file)) != nil
    }

    /// After a failure or a stop: from where it stopped when the server allows it.
    func resume(_ ratingKey: String) {
        guard var entry = entries[ratingKey] else { return }
        let resumeFile = Self.folder(ratingKey).appendingPathComponent("resume.data")
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeFile) {
            task = session.downloadTask(withResumeData: data)
            try? FileManager.default.removeItem(at: resumeFile)
        } else if let client = AppSessionClient.current, let key = entry.item.primaryPart?.key,
                  let url = client.directURL(partKey: key) {
            task = session.downloadTask(with: url)
            entry.written = 0
        } else {
            entry.state = .failed
            entry.error = "لا يوجد اتصال بالخادم"
            entries[ratingKey] = entry
            return
        }
        task.taskDescription = ratingKey
        task.resume()
        entry.state = .downloading
        entry.error = nil
        entries[ratingKey] = entry
        save(now: true)
    }

    /// Stops it and removes everything it saved.
    func delete(_ ratingKey: String) {
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == ratingKey }.forEach { $0.cancel() }
        }
        entries[ratingKey] = nil
        try? FileManager.default.removeItem(at: Self.folder(ratingKey))
        save(now: true)
    }

    // MARK: From the session

    fileprivate func progressed(_ key: String, written: Int64, total: Int64) {
        guard var entry = entries[key] else { return }
        entry.written = written
        if total > 0 { entry.total = total }
        entry.state = .downloading
        entries[key] = entry
        save(now: false)
    }

    fileprivate func finished(_ key: String, file: URL) {
        guard var entry = entries[key], let name = entry.fileName else { return }
        let target = Self.folder(key).appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: file, to: target)
            let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? entry.total
            entry.state = .done
            entry.written = size
            entry.total = size
            entry.error = nil
        } catch {
            entry.state = .failed
            entry.error = "تعذّر حفظ الملف"
        }
        entries[key] = entry
        save(now: true)
    }

    fileprivate func failed(_ key: String, error: Error, resumeData: Data?) {
        guard var entry = entries[key] else { return }
        if (error as? URLError)?.code == .cancelled, resumeData == nil { return } // deleted
        if let resumeData {
            try? resumeData.write(to: Self.folder(key).appendingPathComponent("resume.data"))
        }
        entry.state = .failed
        entry.error = (error as? URLError)?.code == .notConnectedToInternet ? "انقطع الاتصال" : "توقف التحميل"
        entries[key] = entry
        save(now: true)
    }

    fileprivate func backgroundEventsDone() {
        backgroundCompletion?()
        backgroundCompletion = nil
    }

    // MARK: Storage

    nonisolated static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var url = base.appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            // Big files the server still has: not in iCloud backups.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return url
    }

    nonisolated static func folder(_ ratingKey: String) -> URL {
        root.appendingPathComponent(ratingKey.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    nonisolated private static var indexFile: URL { root.appendingPathComponent("index.json") }

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexFile),
              let saved = try? JSONDecoder().decode([DownloadEntry].self, from: data) else { return }
        entries = Dictionary(saved.map { ($0.ratingKey, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Progress is saved every few seconds, the rest at once.
    private func save(now: Bool) {
        guard now || Date().timeIntervalSince(lastSave) > 3 else { return }
        lastSave = Date()
        let list = Array(entries.values)
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(list) { try? data.write(to: Downloads.indexFile, options: .atomic) }
        }
    }

    /// Free space left on the device.
    nonisolated static var freeBytes: Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// The client of the signed-in server (for restarting a download without a details page).
@MainActor
enum AppSessionClient {
    static weak var current: PlexServerClient?
}

/// URLSession's delegate, on its own queue; hands everything to `Downloads` on the main actor.
private final class DownloadBridge: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var owner: Downloads?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        Task { @MainActor in owner?.progressed(key, written: totalBytesWritten, total: totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            Task { @MainActor in owner?.failed(key, error: URLError(.badServerResponse), resumeData: nil) }
            return
        }
        // The file is removed when this returns: move it somewhere of ours first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { try FileManager.default.moveItem(at: location, to: kept) } catch { return }
        Task { @MainActor in owner?.finished(key, file: kept) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let key = task.taskDescription else { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in owner?.failed(key, error: error, resumeData: resume) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in owner?.backgroundEventsDone() }
    }
}
