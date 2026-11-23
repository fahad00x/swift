import Foundation
import Observation

extension Notification.Name {
    /// The active profile's data changed on another device (or after the first-run import).
    static let profileDataDidChangeRemotely = Notification.Name("profileDataDidChangeRemotely")
    /// An item was added to / removed from the active profile's My List.
    static let myListDidChange = Notification.Name("myListDidChange")
}

/// Viewer profiles and their personal data, stored locally (works offline / without iCloud)
/// and mirrored to CloudKit. UI-independent so other Lumen apps can reuse it.
@MainActor
@Observable
final class ProfileStore {
    static let containerIdentifier = "iCloud.com.fahad00x.lumen"
    static let shared = ProfileStore(containerIdentifier: containerIdentifier)

    enum CloudStatus: Equatable {
        case checking
        case localOnly
        case syncing
        case synced(Date)
        case failed(String)

        var description: String {
            switch self {
            case .checking: return "جارٍ التحقق…"
            case .localOnly: return "غير مفعّلة في هذه النسخة (الحفظ على الجهاز فقط)"
            case .syncing: return "جارٍ المزامنة…"
            case .synced(let date):
                return "متزامنة · " + date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "ar")))
            case .failed(let message): return message
            }
        }
    }

    private(set) var profiles: [UserProfile] = []
    private(set) var activeProfileID: String?
    private(set) var cloudStatus: CloudStatus = .checking
    private(set) var rememberLastProfile: Bool
    /// Bumped on every change to the active profile's progress, watched marks or My List.
    private(set) var revision = 0

    /// Overlay read by networking code; always reflects the active profile.
    let snapshot = UserStateSnapshot()

    @ObservationIgnored private var states: [String: MediaState] = [:]
    @ObservationIgnored private var list: [String: WatchlistEntry] = [:]
    /// recordName → modifiedAt of the local change that still has to be uploaded.
    @ObservationIgnored private var dirty: [String: Date] = [:]
    @ObservationIgnored private var pendingDeletes: Set<String> = []
    @ObservationIgnored private var changeToken: Data?
    @ObservationIgnored private let cloud: CloudKitSync?
    @ObservationIgnored private var scheduledSync: Task<Void, Never>?
    @ObservationIgnored private var autoSync: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var isSyncing = false

    private enum Keys {
        static let remember = "profiles.rememberLast"
        static let lastProfile = "profiles.lastProfileID"
        static let backup = "profiles.backup"
    }

    init(containerIdentifier: String) {
        cloud = CloudKitSync.isEntitled(containerIdentifier: containerIdentifier)
            ? CloudKitSync(containerIdentifier: containerIdentifier) : nil
        rememberLastProfile = UserDefaults.standard.bool(forKey: Keys.remember)
        loadFromDisk()
        if cloud == nil { cloudStatus = .localOnly }
    }

    // MARK: - Launch

    /// Call once the server is connected. Pulls from iCloud (waiting a few seconds at most),
    /// creates the default profile on first run, and re-enters the last profile if asked to.
    /// - Returns: true when the default profile was just created (import the existing data then).
    func prepare(sectionKeys: [String]) async -> Bool {
        if profiles.isEmpty {
            await syncNow(timeout: 8)
        } else {
            scheduleSync(after: 0)
        }
        startAutoSync()

        var created = false
        if profiles.isEmpty {
            let me = UserProfile(name: "أنا", symbol: "person.fill", colorHex: "#F5A524", isOwner: true,
                                 scopes: sectionKeys.map { ScopeID(.all, $0).raw }, knownSections: sectionKeys)
            upsertProfile(me)
            created = true
        }
        if activeProfileID == nil, rememberLastProfile,
           let last = UserDefaults.standard.string(forKey: Keys.lastProfile),
           profiles.contains(where: { $0.id == last }) {
            activeProfileID = last
            refreshSnapshot()
        }
        return created
    }

    // MARK: - Profiles

    var activeProfile: UserProfile? {
        guard let activeProfileID else { return nil }
        return profiles.first { $0.id == activeProfileID }
    }

    var owner: UserProfile? { profiles.first(where: \.isOwner) ?? profiles.first }

    func activate(_ profile: UserProfile) {
        activeProfileID = profile.id
        UserDefaults.standard.set(profile.id, forKey: Keys.lastProfile)
        refreshSnapshot()
        revision += 1
        scheduleSync(after: 0)
    }

    /// Back to "Who's watching?".
    func deactivate() {
        flush()
        activeProfileID = nil
        refreshSnapshot()
    }

    func setRememberLastProfile(_ on: Bool) {
        rememberLastProfile = on
        UserDefaults.standard.set(on, forKey: Keys.remember)
    }

    @discardableResult
    func createProfile(_ profile: UserProfile) -> UserProfile {
        var p = profile
        p.createdAt = Date()
        upsertProfile(p)
        return p
    }

    func update(_ profile: UserProfile) {
        upsertProfile(profile)
    }

    func delete(_ profile: UserProfile) {
        guard !profile.isOwner else { return }
        profiles.removeAll { $0.id == profile.id }
        dirty.removeValue(forKey: profile.recordName)
        pendingDeletes.insert(profile.recordName)
        // Its states and list items are deleted on the server by the `deleteSelf` reference.
        for (name, state) in states where state.profileID == profile.id {
            states.removeValue(forKey: name)
            dirty.removeValue(forKey: name)
        }
        for (name, entry) in list where entry.profileID == profile.id {
            list.removeValue(forKey: name)
            dirty.removeValue(forKey: name)
        }
        if activeProfileID == profile.id { activeProfileID = nil; refreshSnapshot() }
        changed()
    }

    func verifyPIN(_ pin: String, for profile: UserProfile) -> Bool {
        ProfilePIN.verify(pin, profile: profile)
    }

    /// Records the server's libraries as seen; `enable` adds the new ones to the active profile.
    func acknowledgeSections(_ keys: [String], enable: Bool) {
        guard var p = activeProfile else { return }
        let new = keys.filter { !p.knownSections.contains($0) }
        guard !new.isEmpty else { return }
        p.knownSections += new
        if enable { p.scopes += new.map { ScopeID(.all, $0).raw } }
        upsertProfile(p)
    }

    private func upsertProfile(_ profile: UserProfile) {
        var p = profile
        p.modifiedAt = Date()
        if let i = profiles.firstIndex(where: { $0.id == p.id }) {
            profiles[i] = p
        } else {
            profiles.append(p)
        }
        sortProfiles()
        markDirty(p.recordName, p.modifiedAt)
        changed()
    }

    private func sortProfiles() {
        profiles.sort { ($0.isOwner ? 0 : 1, $0.createdAt) < ($1.isOwner ? 0 : 1, $1.createdAt) }
    }

    // MARK: - Progress and watched marks

    /// The active profile's states.
    var activeStates: [MediaState] {
        _ = revision
        guard let activeProfileID else { return [] }
        return states.values.filter { $0.profileID == activeProfileID }
    }

    /// Episodes of a show or season the active profile has watched (observable: re-read on change).
    func watchedEpisodeCount(under parentKey: String) -> Int {
        _ = revision
        return snapshot.watchedCount(under: parentKey)
    }

    func state(for ratingKey: String) -> MediaState? {
        _ = revision
        guard let activeProfileID else { return nil }
        return states[MediaState.recordName(profileID: activeProfileID, ratingKey: ratingKey)]
    }

    /// Saves the playback position (every 10 s while playing, on pause, stop and exit).
    func recordProgress(_ info: MediaInfo, offsetMs: Int, durationMs: Int) {
        mutateState(info) { state in
            state.offsetMs = max(0, offsetMs)
            if durationMs > 0 { state.durationMs = durationMs }
            state.lastViewedAt = Date()
        }
    }

    func setWatched(_ infos: [MediaInfo], watched: Bool) {
        let now = Date()
        for info in infos {
            mutateState(info, notify: false) { state in
                state.watched = watched
                state.offsetMs = 0
                if info.durationMs > 0 { state.durationMs = info.durationMs }
                if watched { state.lastViewedAt = now }
            }
        }
        changed()
    }

    func chooseAudio(_ info: MediaInfo, streamID: Int?, language: String?) {
        mutateState(info) { $0.audioStreamID = streamID }
        if var p = activeProfile, let language, p.preferredAudioLanguage != language {
            p.preferredAudioLanguage = language
            upsertProfile(p)
        }
    }

    /// `streamID` nil = subtitles off.
    func chooseSubtitle(_ info: MediaInfo, streamID: Int?, language: String?) {
        mutateState(info) { $0.subtitleStreamID = streamID ?? 0 }
        guard var p = activeProfile else { return }
        let off = streamID == nil
        guard p.subtitlesOff != off || (!off && language != nil && p.preferredSubtitleLanguage != language) else { return }
        p.subtitlesOff = off
        if !off, let language { p.preferredSubtitleLanguage = language }
        upsertProfile(p)
    }

    private func mutateState(_ info: MediaInfo, notify: Bool = true, _ change: (inout MediaState) -> Void) {
        guard let profileID = activeProfileID else { return }
        let name = MediaState.recordName(profileID: profileID, ratingKey: info.ratingKey)
        var state = states[name] ?? MediaState(profileID: profileID, ratingKey: info.ratingKey, type: info.type,
                                               genres: info.genres, offsetMs: 0, durationMs: info.durationMs,
                                               watched: false, lastViewedAt: Date(), modifiedAt: Date())
        // Keep the descriptive fields current (they drive Continue Watching and suggestions).
        state.type = info.type
        state.showKey = info.showKey ?? state.showKey
        state.seasonKey = info.seasonKey ?? state.seasonKey
        state.sectionKey = info.sectionKey ?? state.sectionKey
        state.sortIndex = info.sortIndex ?? state.sortIndex
        if !info.genres.isEmpty { state.genres = info.genres }
        change(&state)
        state.modifiedAt = Date()
        states[name] = state
        markDirty(name, state.modifiedAt)
        if notify { changed() }
    }

    // MARK: - My List

    var myList: [WatchlistEntry] {
        _ = revision
        guard let activeProfileID else { return [] }
        return list.values.filter { $0.profileID == activeProfileID }.sorted { $0.addedAt > $1.addedAt }
    }

    func isOnMyList(_ ratingKey: String) -> Bool {
        _ = revision
        guard let activeProfileID else { return false }
        return list[WatchlistEntry.recordName(profileID: activeProfileID, ratingKey: ratingKey)] != nil
    }

    func toggleMyList(_ info: MediaInfo) {
        guard let profileID = activeProfileID else { return }
        let name = WatchlistEntry.recordName(profileID: profileID, ratingKey: info.ratingKey)
        if list.removeValue(forKey: name) != nil {
            dirty.removeValue(forKey: name)
            pendingDeletes.insert(name)
        } else {
            let entry = WatchlistEntry(profileID: profileID, ratingKey: info.ratingKey, type: info.type,
                                       sectionKey: info.sectionKey, addedAt: Date(), modifiedAt: Date())
            list[name] = entry
            pendingDeletes.remove(name)
            markDirty(name, entry.modifiedAt)
        }
        changed()
        NotificationCenter.default.post(name: .myListDidChange, object: nil)
    }

    // MARK: - First-run import

    struct ImportedState: Sendable {
        var info: MediaInfo
        var offsetMs: Int
        var watched: Bool
        var lastViewedAt: Date
    }

    /// Copies data that existed before profiles (Plex progress / watched / watchlist) to a profile.
    func importExisting(_ imported: [ImportedState], myList items: [MediaInfo], into profileID: String) {
        let now = Date()
        for item in imported {
            let name = MediaState.recordName(profileID: profileID, ratingKey: item.info.ratingKey)
            guard states[name] == nil else { continue }
            let state = MediaState(profileID: profileID, ratingKey: item.info.ratingKey, type: item.info.type,
                                   showKey: item.info.showKey, seasonKey: item.info.seasonKey,
                                   sectionKey: item.info.sectionKey, sortIndex: item.info.sortIndex,
                                   genres: item.info.genres, offsetMs: item.offsetMs,
                                   durationMs: item.info.durationMs, watched: item.watched,
                                   lastViewedAt: item.lastViewedAt, modifiedAt: now)
            states[name] = state
            markDirty(name, now)
        }
        for info in items {
            let name = WatchlistEntry.recordName(profileID: profileID, ratingKey: info.ratingKey)
            guard list[name] == nil else { continue }
            list[name] = WatchlistEntry(profileID: profileID, ratingKey: info.ratingKey, type: info.type,
                                        sectionKey: info.sectionKey, addedAt: now, modifiedAt: now)
            markDirty(name, now)
        }
        changed()
        NotificationCenter.default.post(name: .profileDataDidChangeRemotely, object: nil)
    }

    // MARK: - Change tracking

    private func markDirty(_ recordName: String, _ date: Date) {
        dirty[recordName] = date
        pendingDeletes.remove(recordName)
    }

    private func changed() {
        refreshSnapshot()
        revision += 1
        scheduleSave()
        scheduleSync(after: 10)
    }

    private func refreshSnapshot() {
        snapshot.replace(with: activeProfileID.map { id in states.values.filter { $0.profileID == id } } ?? [])
    }

    // MARK: - Sync

    /// Saves now and uploads pending changes (playback stop, app going to the background).
    func flush() {
        saveTask?.cancel()
        saveToDisk()
        scheduleSync(after: 0)
    }

    /// Coalesces uploads: at most one pending sync at a time.
    func scheduleSync(after seconds: Double) {
        guard cloud != nil else { return }
        if seconds > 0, scheduledSync != nil { return }
        scheduledSync?.cancel()
        scheduledSync = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled else { return }
            self?.scheduledSync = nil
            await self?.syncNow()
        }
    }

    /// Pulls every 2 minutes so changes made on another device show up.
    private func startAutoSync() {
        guard cloud != nil, autoSync == nil else { return }
        autoSync = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                await self?.syncNow()
            }
        }
    }

    /// Waits for the sync, or `timeout` seconds at most (the sync keeps running after that).
    func syncNow(timeout: Double) async {
        final class Gate { var open = false }
        let gate = Gate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finish: @MainActor () -> Void = {
                guard !gate.open else { return }
                gate.open = true
                continuation.resume()
            }
            Task { @MainActor in await self.syncNow(); finish() }
            Task { @MainActor in try? await Task.sleep(for: .seconds(timeout)); finish() }
        }
    }

    func syncNow() async {
        guard let cloud, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        cloudStatus = .syncing
        do {
            try await cloud.prepare()
            // Pull first so a newer change from another device wins (last writer wins).
            let changes = try await cloud.fetchChanges(since: changeToken)
            apply(changes)
            changeToken = changes.token

            let uploads: [(SyncRecord, Date)] = dirty.compactMap { name, date in record(named: name).map { ($0, date) } }
            let deletions = Array(pendingDeletes)
            var failure: String?
            if !uploads.isEmpty || !deletions.isEmpty {
                let result = try await cloud.push(uploads.map(\.0), deleting: deletions)
                let pushedDates = Dictionary(uploads.map { ($0.0.recordName, $0.1) }, uniquingKeysWith: { a, _ in a })
                for name in result.saved where dirty[name] == pushedDates[name] {
                    dirty.removeValue(forKey: name)
                }
                for name in result.deleted { pendingDeletes.remove(name) }
                failure = result.failures.values.first
            }
            saveToDisk()
            cloudStatus = failure.map { CloudStatus.failed($0) } ?? .synced(Date())
        } catch {
            cloudStatus = .failed(CloudKitSync.describe(error))
        }
    }

    private func record(named name: String) -> SyncRecord? {
        if let state = states[name] { return .state(state) }
        if let entry = list[name] { return .listItem(entry) }
        if let profile = profiles.first(where: { $0.recordName == name }) { return .profile(profile) }
        return nil
    }

    /// Last writer wins: a remote record replaces the local one unless the local copy has a
    /// newer change that hasn't been uploaded yet.
    private func apply(_ changes: CloudChanges) {
        guard !changes.records.isEmpty || !changes.deletedRecordNames.isEmpty else { return }
        var touchedActive = false
        func localIsNewer(_ name: String, than remote: Date) -> Bool {
            if pendingDeletes.contains(name) { return true }
            guard let pending = dirty[name] else { return false }
            return pending > remote
        }

        for record in changes.records {
            let name = record.recordName
            guard !localIsNewer(name, than: record.modifiedAt) else { continue }
            dirty.removeValue(forKey: name)
            switch record {
            case .profile(let p):
                if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p } else { profiles.append(p) }
            case .state(let s):
                states[name] = s
                if s.profileID == activeProfileID { touchedActive = true }
            case .listItem(let w):
                list[name] = w
                if w.profileID == activeProfileID { touchedActive = true }
            }
        }
        for name in changes.deletedRecordNames {
            dirty.removeValue(forKey: name)
            if let s = states.removeValue(forKey: name), s.profileID == activeProfileID { touchedActive = true }
            if let w = list.removeValue(forKey: name), w.profileID == activeProfileID { touchedActive = true }
            if let i = profiles.firstIndex(where: { $0.recordName == name }) {
                let removed = profiles.remove(at: i)
                states = states.filter { $0.value.profileID != removed.id }
                list = list.filter { $0.value.profileID != removed.id }
                if removed.id == activeProfileID { activeProfileID = nil }
            }
        }
        sortProfiles()
        refreshSnapshot()
        revision += 1
        if touchedActive { NotificationCenter.default.post(name: .profileDataDidChangeRemotely, object: nil) }
    }

    // MARK: - Local cache

    private struct Cache: Codable {
        var profiles: [UserProfile]
        var states: [MediaState]
        var list: [WatchlistEntry]
        var dirty: [String: Date]
        var pendingDeletes: [String]
        var changeToken: Data?
    }

    /// tvOS only guarantees the Caches directory, so profiles are also kept in UserDefaults
    /// (small); everything else is restored from iCloud if the system purges the cache.
    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profiles.json")
    }

    private func loadFromDisk() {
        if let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            profiles = cache.profiles
            states = Dictionary(cache.states.map { ($0.recordName, $0) }, uniquingKeysWith: { a, _ in a })
            list = Dictionary(cache.list.map { ($0.recordName, $0) }, uniquingKeysWith: { a, _ in a })
            dirty = cache.dirty
            pendingDeletes = Set(cache.pendingDeletes)
            changeToken = cache.changeToken
        } else if let data = UserDefaults.standard.data(forKey: Keys.backup),
                  let backup = try? JSONDecoder().decode([UserProfile].self, from: data) {
            profiles = backup
            // The cache is gone: fetch everything again.
            changeToken = nil
        }
        sortProfiles()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveToDisk()
        }
    }

    private func saveToDisk() {
        let cache = Cache(profiles: profiles, states: Array(states.values), list: Array(list.values),
                          dirty: dirty, pendingDeletes: Array(pendingDeletes), changeToken: changeToken)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Keys.backup)
        }
    }
}
