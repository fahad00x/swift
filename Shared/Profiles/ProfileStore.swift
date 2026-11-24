import CloudKit
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
                return "متزامنة" + ArabicFormat.separator + ArabicFormat.time(date)
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
    /// Title of a profile just added from another iCloud account's invitation (for a message).
    var acceptedShareTitle: String?
    /// Profiles other iCloud accounts shared with this one: profileID → their zone.
    private(set) var sharedZones: [String: SharedZone] = [:]

    /// Overlay read by networking code; always reflects the active profile.
    let snapshot = UserStateSnapshot()

    @ObservationIgnored private var states: [String: MediaState] = [:]
    @ObservationIgnored private var list: [String: WatchlistEntry] = [:]
    /// recordName → modifiedAt of the local change that still has to be uploaded.
    @ObservationIgnored private var dirty: [String: Date] = [:]
    @ObservationIgnored private var pendingDeletes: Set<String> = []
    @ObservationIgnored private var changeToken: Data?
    @ObservationIgnored private var sharedTokens: [String: Data] = [:]
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
        applySettingsToDevice()
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
        // Settings edits (e.g. hidden libraries) are saved right away, not after the debounce.
        saveToDisk()
        scheduleSync(after: 0)
    }

    func delete(_ profile: UserProfile) {
        // The owner can't be deleted; a shared profile belongs to the account that shared it.
        guard !profile.isOwner, !isSharedWithMe(profile) else { return }
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

    // MARK: - Per-profile settings (follow the profile to every device)

    /// Changes the active profile's settings.
    func updateSettings(_ change: (inout ProfileSettings) -> Void) {
        guard var p = activeProfile else { return }
        var settings = p.settings ?? ProfileSettings()
        change(&settings)
        guard settings != p.settings else { return }
        p.settings = settings
        upsertProfile(p)
    }

    /// Copies the active profile's playback preferences to the keys the players read.
    private func applySettingsToDevice() {
        guard let settings = activeProfile?.settings else { return }
        if let on = settings.autoSkipIntro { UserDefaults.standard.set(on, forKey: ProfileSettings.autoSkipIntroKey) }
        if let on = settings.autoPlayNext { UserDefaults.standard.set(on, forKey: ProfileSettings.autoPlayNextKey) }
    }

    // MARK: - Sharing with another iCloud account

    /// The profile lives in another account's iCloud and was shared with this one.
    func isSharedWithMe(_ profile: UserProfile) -> Bool { sharedZones[profile.id] != nil }

    /// Uploads everything, then returns the profile's share (created on first use) for the
    /// system sharing screen.
    func prepareShare(for profile: UserProfile) async throws -> (CKShare, CKContainer) {
        guard let cloud else { throw CloudSyncError.account(.couldNotDetermine) }
        await syncNow()
        let result = try await cloud.share(profileID: profile.id, title: profile.name)
        // Upload the profile's data again (unchanged) so every record is in the shared hierarchy.
        for (name, state) in states where state.profileID == profile.id { dirty[name] = dirty[name] ?? state.modifiedAt }
        for (name, entry) in list where entry.profileID == profile.id { dirty[name] = dirty[name] ?? entry.modifiedAt }
        scheduleSync(after: 0)
        return result
    }

    /// Opens an invitation to someone else's profile (link tapped on this device).
    func acceptShare(_ metadata: CKShare.Metadata) async {
        guard let cloud else { return }
        do {
            try await cloud.accept(metadata)
            await syncNow()
            acceptedShareTitle = (metadata.share[CKShare.SystemFieldKey.title] as? String) ?? "مستخدم مشترك"
        } catch {
            cloudStatus = .failed(CloudKitSync.describe(error))
        }
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

    // MARK: - Import from Plex into the active profile

    enum ImportMode: Sendable {
        /// Adds what's missing; watched here or there = watched; the latest position wins.
        case merge
        /// The chosen libraries become what Plex says (anything else watched there is cleared).
        case replace
    }

    struct ImportSummary: Equatable, Sendable {
        var added = 0
        var updated = 0
        var cleared = 0
    }

    private struct ImportBackup: Codable {
        var date: Date
        var states: [MediaState]
        /// Records the import created.
        var added: [String]
    }

    private func importBackupURL(_ profileID: String) -> URL {
        cacheURL.deletingLastPathComponent().appendingPathComponent("import-undo-\(profileID).json")
    }

    /// Items of `sections` watched or started on Plex, for one profile only (nothing if it's no
    /// longer the active one). Never touches the other profiles, My List or chosen tracks.
    @discardableResult
    func importHistory(_ imported: [ImportedState], sections: Set<String>, mode: ImportMode,
                       into profileID: String) -> ImportSummary? {
        guard profileID == activeProfileID else { return nil }
        let now = Date()
        var summary = ImportSummary()
        var before: [MediaState] = []
        var added: [String] = []
        var seen = Set<String>()

        func save(_ state: MediaState, replacing old: MediaState) {
            before.append(old)
            var state = state
            state.modifiedAt = now
            states[old.recordName] = state
            markDirty(old.recordName, now)
        }

        for item in imported {
            let name = MediaState.recordName(profileID: profileID, ratingKey: item.info.ratingKey)
            guard seen.insert(name).inserted else { continue }
            guard let old = states[name] else {
                states[name] = MediaState(profileID: profileID, ratingKey: item.info.ratingKey, type: item.info.type,
                                          showKey: item.info.showKey, seasonKey: item.info.seasonKey,
                                          sectionKey: item.info.sectionKey, sortIndex: item.info.sortIndex,
                                          genres: item.info.genres, offsetMs: item.offsetMs,
                                          durationMs: item.info.durationMs, watched: item.watched,
                                          lastViewedAt: item.lastViewedAt, modifiedAt: now)
                markDirty(name, now)
                added.append(name)
                summary.added += 1
                continue
            }
            var new = old
            new.showKey = new.showKey ?? item.info.showKey
            new.seasonKey = new.seasonKey ?? item.info.seasonKey
            new.sectionKey = new.sectionKey ?? item.info.sectionKey
            new.sortIndex = new.sortIndex ?? item.info.sortIndex
            if new.durationMs == 0 { new.durationMs = item.info.durationMs }
            // Not touched here yet (tracks chosen only, or cleared): its date says nothing.
            let untouched = !old.watched && old.offsetMs == 0
            switch mode {
            case .replace:
                new.watched = item.watched
                new.offsetMs = item.offsetMs
                new.lastViewedAt = item.lastViewedAt
            case .merge:
                new.watched = old.watched || item.watched
                if untouched || item.lastViewedAt > old.lastViewedAt {
                    new.offsetMs = item.offsetMs
                    new.lastViewedAt = item.lastViewedAt
                }
                if new.watched { new.offsetMs = 0 }
            }
            guard new.watched != old.watched || new.offsetMs != old.offsetMs || new.lastViewedAt != old.lastViewedAt else { continue }
            save(new, replacing: old)
            summary.updated += 1
        }

        if mode == .replace {
            for old in states.values where old.profileID == profileID && !seen.contains(old.recordName)
                && old.sectionKey.map(sections.contains) == true && (old.watched || old.offsetMs > 0) {
                // Kept (chosen tracks, and so the change reaches the other devices), but cleared.
                var new = old
                new.watched = false
                new.offsetMs = 0
                save(new, replacing: old)
                summary.cleared += 1
            }
        }

        guard !before.isEmpty || !added.isEmpty else { return summary }
        if let data = try? JSONEncoder().encode(ImportBackup(date: now, states: before, added: added)) {
            try? data.write(to: importBackupURL(profileID), options: .atomic)
        }
        changed()
        saveToDisk()
        NotificationCenter.default.post(name: .profileDataDidChangeRemotely, object: nil)
        return summary
    }

    /// The last import into the active profile can be taken back (on this device).
    var canUndoImport: Bool {
        _ = revision
        guard let activeProfileID else { return false }
        return FileManager.default.fileExists(atPath: importBackupURL(activeProfileID).path)
    }

    /// What the last import changed goes back to what it was; anything watched since is kept.
    func undoImport() {
        guard let profileID = activeProfileID,
              let data = try? Data(contentsOf: importBackupURL(profileID)),
              let backup = try? JSONDecoder().decode(ImportBackup.self, from: data) else { return }
        let now = Date()
        // Everything the import wrote has its date (iCloud may round it); another one means it
        // was played or marked since.
        func untouched(_ name: String) -> Bool {
            states[name].map { abs($0.modifiedAt.timeIntervalSince(backup.date)) < 1 } ?? false
        }
        for old in backup.states where untouched(old.recordName) {
            var state = old
            state.modifiedAt = now
            states[old.recordName] = state
            markDirty(old.recordName, now)
        }
        for name in backup.added where untouched(name) {
            guard var state = states[name] else { continue }
            state.watched = false
            state.offsetMs = 0
            state.modifiedAt = now
            states[name] = state
            markDirty(name, now)
        }
        try? FileManager.default.removeItem(at: importBackupURL(profileID))
        changed()
        saveToDisk()
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
            // Profiles shared with this account (a failure here never stops the private sync).
            if let shared = try? await cloud.fetchShared(tokens: sharedTokens) {
                applyShared(shared)
            }

            let uploads: [(SyncRecord, Date)] = dirty.compactMap { name, date in record(named: name).map { ($0, date) } }
            let deletions = Array(pendingDeletes)
            var failure: String?
            if !uploads.isEmpty || !deletions.isEmpty {
                let result = try await cloud.push(uploads.map(\.0), deleting: deletions, shared: sharedZones)
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

    /// Merges the shared database; a profile whose share ended is removed from this device only.
    private func applyShared(_ shared: SharedChanges) {
        var zones = sharedZones.filter { shared.listedZones.contains($0.value.key) }
        for (id, zone) in shared.profileZones { zones[id] = zone }
        let ended = sharedZones.keys.filter { zones[$0] == nil }
        sharedZones = zones
        sharedTokens = shared.zoneTokens
        var changes = shared.changes
        changes.deletedRecordNames += ended.map { "profile-\($0)" }
        apply(changes)
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
        /// When this device last changed the record (saved with it, so it survives a purged cache).
        func localModified(_ name: String) -> Date? {
            if let state = states[name] { return state.modifiedAt }
            if let entry = list[name] { return entry.modifiedAt }
            return profiles.first { $0.recordName == name }?.modifiedAt
        }
        func localIsNewer(_ name: String, than remote: Date) -> Bool {
            if pendingDeletes.contains(name) { return true }
            if let pending = dirty[name], pending > remote { return true }
            // Newest change wins even when the pending upload was lost (e.g. the system purged
            // the cache before it went out): the older cloud copy never replaces it.
            // (1 s margin: iCloud stores dates to the millisecond, so our own upload reads back a
            // hair older and must not count as a newer local change.)
            guard let local = localModified(name), local.timeIntervalSince(remote) > 1 else { return false }
            dirty[name] = local
            return true
        }

        for record in changes.records {
            let name = record.recordName
            guard !localIsNewer(name, than: record.modifiedAt) else { continue }
            dirty.removeValue(forKey: name)
            switch record {
            case .profile(let p):
                if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p } else { profiles.append(p) }
                if p.id == activeProfileID { applySettingsToDevice() }
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
        var sharedZones: [String: SharedZone]?
        var sharedTokens: [String: Data]?
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
            sharedZones = cache.sharedZones ?? [:]
            sharedTokens = cache.sharedTokens ?? [:]
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
                          dirty: dirty, pendingDeletes: Array(pendingDeletes), changeToken: changeToken,
                          sharedZones: sharedZones, sharedTokens: sharedTokens)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Keys.backup)
        }
    }
}
