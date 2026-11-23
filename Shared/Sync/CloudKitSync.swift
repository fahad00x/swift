import CloudKit
import Foundation

/// One synced model value.
enum SyncRecord: Sendable {
    case profile(UserProfile)
    case state(MediaState)
    case listItem(WatchlistEntry)

    var recordName: String {
        switch self {
        case .profile(let p): return p.recordName
        case .state(let s): return s.recordName
        case .listItem(let w): return w.recordName
        }
    }

    var modifiedAt: Date {
        switch self {
        case .profile(let p): return p.modifiedAt
        case .state(let s): return s.modifiedAt
        case .listItem(let w): return w.modifiedAt
        }
    }
}

struct CloudChanges: Sendable {
    var records: [SyncRecord] = []
    var deletedRecordNames: [String] = []
    /// Archived CKServerChangeToken.
    var token: Data?
}

struct CloudPushResult: Sendable {
    var saved: [String] = []
    var deleted: [String] = []
    var failures: [String: String] = [:]
}

enum CloudSyncError: LocalizedError {
    case account(CKAccountStatus)

    var errorDescription: String? {
        switch self {
        case .account(.noAccount): return "سجّل الدخول إلى iCloud من إعدادات Apple TV لتفعيل المزامنة."
        case .account(.restricted): return "iCloud مقيّد على هذا الجهاز."
        case .account(.temporarilyUnavailable): return "iCloud غير متاح مؤقتاً."
        default: return "تعذّر التحقق من حساب iCloud."
        }
    }
}

/// CloudKit storage for profiles, in the private database of `iCloud.com.fahad00x.lumen`.
///
/// Layout (shared by every Lumen app — tvOS now, iPad / iPhone later):
/// - Custom zone `LumenProfiles` (not the default zone), so it can later be shared with another
///   iCloud account through a zone-wide `CKShare`.
/// - `Profile` record per profile; `MediaState` and `WatchlistItem` records point to their profile
///   with a `profile` reference (`deleteSelf`, so deleting a profile deletes its data) and as
///   their `parent` (needed for sharing hierarchies).
/// - Conflicts: last writer wins, by each record's `modifiedAt` (merged in `ProfileStore`);
///   uploads overwrite the server copy (`.allKeys`) after the latest changes have been pulled.
actor CloudKitSync {
    static let zoneName = "LumenProfiles"

    enum RecordType {
        static let profile = "Profile"
        static let state = "MediaState"
        static let listItem = "WatchlistItem"
    }

    private let containerIdentifier: String
    private let zoneID: CKRecordZone.ID
    private var container: CKContainer?
    private var zoneReady = false

    init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
        zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    private var ckContainer: CKContainer {
        if let container { return container }
        let made = CKContainer(identifier: containerIdentifier)
        container = made
        return made
    }

    private var database: CKDatabase { ckContainer.privateCloudDatabase }

    // MARK: Entitlement check

    /// True when the running binary is signed with the iCloud entitlement for `containerIdentifier`.
    /// `CKContainer(identifier:)` raises an (uncatchable) exception without it — e.g. in unsigned
    /// CI or simulator builds — so the app falls back to local storage instead.
    static func isEntitled(containerIdentifier: String) -> Bool {
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let signature = codeSignatureRange(in: data)
        else { return false }
        // Built from pieces so the full needle never appears as a literal in the binary itself.
        var needle = Data("<string>".utf8)
        needle.append(Data(containerIdentifier.utf8))
        needle.append(Data("</".utf8))
        needle.append(Data("string>".utf8))
        let blob = data.subdata(in: signature)
        return blob.range(of: needle) != nil && blob.range(of: Data("CloudKit".utf8)) != nil
    }

    /// Byte range of LC_CODE_SIGNATURE in a thin 64-bit Mach-O (device builds are arm64-only).
    private static func codeSignatureRange(in data: Data) -> Range<Int>? {
        func u32(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        guard u32(0) == 0xFEEDFACF, let ncmds = u32(16) else { return nil }
        var offset = 32
        for _ in 0..<ncmds {
            guard let cmd = u32(offset), let size = u32(offset + 4), size > 0 else { return nil }
            if cmd == 0x1D, let dataOff = u32(offset + 8), let dataSize = u32(offset + 12) {
                let start = Int(dataOff), end = start + Int(dataSize)
                guard end <= data.count else { return nil }
                return start..<end
            }
            offset += Int(size)
        }
        return nil
    }

    // MARK: Setup

    func prepare() async throws {
        let status = try await ckContainer.accountStatus()
        guard status == .available else { throw CloudSyncError.account(status) }
        guard !zoneReady else { return }
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        zoneReady = true
    }

    // MARK: Pull

    func fetchChanges(since tokenData: Data?) async throws -> CloudChanges {
        var token = tokenData.flatMap(Self.unarchiveToken)
        var changes = CloudChanges()
        var moreComing = true
        while moreComing {
            do {
                let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
                for (_, outcome) in result.modificationResultsByID {
                    if case .success(let modification) = outcome, let record = RecordMapper.decode(modification.record) {
                        changes.records.append(record)
                    }
                }
                changes.deletedRecordNames += result.deletions.map(\.recordID.recordName)
                token = result.changeToken
                moreComing = result.moreComing
            } catch let error as CKError where error.code == .changeTokenExpired && token != nil {
                // Start over from scratch; the merge keeps whichever side is newer.
                token = nil
                changes = CloudChanges()
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                zoneReady = false
                throw error
            }
        }
        changes.token = token.flatMap(Self.archiveToken)
        return changes
    }

    // MARK: Push

    func push(_ records: [SyncRecord], deleting deletions: [String]) async throws -> CloudPushResult {
        var result = CloudPushResult()
        // Profiles first, so children never reference a profile the server hasn't seen.
        let ordered = records.sorted { lhs, rhs in
            if case .profile = lhs, !(rhs.isProfile) { return true }
            return false
        }
        let toSave = ordered.map { RecordMapper.record(for: $0, zoneID: zoneID) }
        let toDelete = deletions.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        let batch = 300

        do {
            for start in stride(from: 0, to: toSave.count, by: batch) {
                let chunk = Array(toSave[start..<min(start + batch, toSave.count)])
                let outcome = try await database.modifyRecords(saving: chunk, deleting: [], savePolicy: .allKeys, atomically: false)
                for (id, saved) in outcome.saveResults {
                    switch saved {
                    case .success: result.saved.append(id.recordName)
                    case .failure(let error):
                        result.failures[id.recordName] = Self.describe(error)
                        if (error as? CKError)?.code == .zoneNotFound { zoneReady = false }
                    }
                }
            }
            for start in stride(from: 0, to: toDelete.count, by: batch) {
                let chunk = Array(toDelete[start..<min(start + batch, toDelete.count)])
                let outcome = try await database.modifyRecords(saving: [], deleting: chunk, savePolicy: .allKeys, atomically: false)
                for (id, deleted) in outcome.deleteResults {
                    switch deleted {
                    case .success: result.deleted.append(id.recordName)
                    case .failure(let error):
                        if (error as? CKError)?.code == .unknownItem {
                            result.deleted.append(id.recordName)
                        } else {
                            result.failures[id.recordName] = Self.describe(error)
                        }
                    }
                }
            }
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            zoneReady = false
            throw error
        }
        return result
    }

    // MARK: Helpers

    private static func archiveToken(_ token: CKServerChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func unarchiveToken(_ data: Data) -> CKServerChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? CloudSyncError { return error.localizedDescription }
        guard let ck = error as? CKError else { return error.localizedDescription }
        switch ck.code {
        case .networkUnavailable, .networkFailure: return "لا يوجد اتصال بالإنترنت."
        case .notAuthenticated: return "سجّل الدخول إلى iCloud من إعدادات Apple TV."
        case .quotaExceeded: return "مساحة iCloud ممتلئة."
        case .serviceUnavailable, .requestRateLimited, .zoneBusy: return "خدمة iCloud مشغولة، ستُعاد المحاولة لاحقاً."
        case .badContainer, .missingEntitlement, .permissionFailure: return "حاوية iCloud غير مهيّأة لهذا التطبيق."
        case .invalidArguments, .serverRejectedRequest: return "مخطط CloudKit غير منشور في بيئة الإنتاج (راجع SETUP-TESTFLIGHT.md)."
        default: return ck.localizedDescription
        }
    }
}

private extension SyncRecord {
    var isProfile: Bool {
        if case .profile = self { return true }
        return false
    }
}

// MARK: - Record mapping

/// Model ⇄ CKRecord. Lists are stored as JSON strings (CloudKit can't infer the type of an empty list).
enum RecordMapper {
    typealias RecordType = CloudKitSync.RecordType

    static func record(for value: SyncRecord, zoneID: CKRecordZone.ID) -> CKRecord {
        let id = CKRecord.ID(recordName: value.recordName, zoneID: zoneID)
        switch value {
        case .profile(let p):
            let r = CKRecord(recordType: RecordType.profile, recordID: id)
            r["profileID"] = p.id as NSString
            r["name"] = p.name as NSString
            r["symbol"] = p.symbol as NSString
            r["colorHex"] = p.colorHex as NSString
            r["isKids"] = NSNumber(value: p.isKids ? 1 : 0)
            r["isOwner"] = NSNumber(value: p.isOwner ? 1 : 0)
            r["pinHash"] = p.pinHash.map { $0 as NSString }
            r["scopes"] = json(p.scopes)
            r["knownSections"] = json(p.knownSections)
            r["genres"] = json(p.genres)
            r["preferredAudioLanguage"] = p.preferredAudioLanguage.map { $0 as NSString }
            r["preferredSubtitleLanguage"] = p.preferredSubtitleLanguage.map { $0 as NSString }
            r["subtitlesOff"] = NSNumber(value: p.subtitlesOff ? 1 : 0)
            r["createdAt"] = p.createdAt as NSDate
            r["modifiedAt"] = p.modifiedAt as NSDate
            return r

        case .state(let s):
            let r = CKRecord(recordType: RecordType.state, recordID: id)
            link(r, profileID: s.profileID, zoneID: zoneID)
            r["ratingKey"] = s.ratingKey as NSString
            r["type"] = s.type as NSString
            r["showKey"] = s.showKey.map { $0 as NSString }
            r["seasonKey"] = s.seasonKey.map { $0 as NSString }
            r["sectionKey"] = s.sectionKey.map { $0 as NSString }
            r["sortIndex"] = s.sortIndex.map { NSNumber(value: $0) }
            r["genres"] = json(s.genres)
            r["offsetMs"] = NSNumber(value: s.offsetMs)
            r["durationMs"] = NSNumber(value: s.durationMs)
            r["watched"] = NSNumber(value: s.watched ? 1 : 0)
            r["lastViewedAt"] = s.lastViewedAt as NSDate
            r["audioStreamID"] = s.audioStreamID.map { NSNumber(value: $0) }
            r["subtitleStreamID"] = s.subtitleStreamID.map { NSNumber(value: $0) }
            r["modifiedAt"] = s.modifiedAt as NSDate
            return r

        case .listItem(let w):
            let r = CKRecord(recordType: RecordType.listItem, recordID: id)
            link(r, profileID: w.profileID, zoneID: zoneID)
            r["ratingKey"] = w.ratingKey as NSString
            r["type"] = w.type as NSString
            r["sectionKey"] = w.sectionKey.map { $0 as NSString }
            r["addedAt"] = w.addedAt as NSDate
            r["modifiedAt"] = w.modifiedAt as NSDate
            return r
        }
    }

    static func decode(_ r: CKRecord) -> SyncRecord? {
        let modified = (r["modifiedAt"] as? Date) ?? r.modificationDate ?? Date.distantPast
        switch r.recordType {
        case RecordType.profile:
            guard let id = r["profileID"] as? String, let name = r["name"] as? String else { return nil }
            var p = UserProfile(id: id, name: name,
                                symbol: (r["symbol"] as? String) ?? "person.fill",
                                colorHex: (r["colorHex"] as? String) ?? "#F5A524",
                                isKids: bool(r.object(forKey: "isKids")), isOwner: bool(r.object(forKey: "isOwner")),
                                pinHash: r["pinHash"] as? String,
                                scopes: list(r.object(forKey: "scopes")), knownSections: list(r.object(forKey: "knownSections")),
                                genres: list(r.object(forKey: "genres")))
            p.preferredAudioLanguage = r["preferredAudioLanguage"] as? String
            p.preferredSubtitleLanguage = r["preferredSubtitleLanguage"] as? String
            p.subtitlesOff = bool(r.object(forKey: "subtitlesOff"))
            p.createdAt = (r["createdAt"] as? Date) ?? r.creationDate ?? Date()
            p.modifiedAt = modified
            return .profile(p)

        case RecordType.state:
            guard let profileID = r["profileID"] as? String, let key = r["ratingKey"] as? String else { return nil }
            return .state(MediaState(profileID: profileID, ratingKey: key,
                                     type: (r["type"] as? String) ?? "",
                                     showKey: r["showKey"] as? String,
                                     seasonKey: r["seasonKey"] as? String,
                                     sectionKey: r["sectionKey"] as? String,
                                     sortIndex: int(r.object(forKey: "sortIndex")),
                                     genres: list(r.object(forKey: "genres")),
                                     offsetMs: int(r.object(forKey: "offsetMs")) ?? 0,
                                     durationMs: int(r.object(forKey: "durationMs")) ?? 0,
                                     watched: bool(r.object(forKey: "watched")),
                                     lastViewedAt: (r["lastViewedAt"] as? Date) ?? modified,
                                     audioStreamID: int(r.object(forKey: "audioStreamID")),
                                     subtitleStreamID: int(r.object(forKey: "subtitleStreamID")),
                                     modifiedAt: modified))

        case RecordType.listItem:
            guard let profileID = r["profileID"] as? String, let key = r["ratingKey"] as? String else { return nil }
            return .listItem(WatchlistEntry(profileID: profileID, ratingKey: key,
                                            type: (r["type"] as? String) ?? "",
                                            sectionKey: r["sectionKey"] as? String,
                                            addedAt: (r["addedAt"] as? Date) ?? modified,
                                            modifiedAt: modified))
        default:
            return nil
        }
    }

    /// `profile` reference (cascade delete) + `parent` (sharing hierarchy) + plain profile id.
    private static func link(_ r: CKRecord, profileID: String, zoneID: CKRecordZone.ID) {
        let parentID = CKRecord.ID(recordName: "profile-\(profileID)", zoneID: zoneID)
        r["profileID"] = profileID as NSString
        r["profile"] = CKRecord.Reference(recordID: parentID, action: .deleteSelf)
        r.setParent(parentID)
    }

    private static func json(_ values: [String]) -> NSString {
        let data = (try? JSONEncoder().encode(values)) ?? Data("[]".utf8)
        return (String(data: data, encoding: .utf8) ?? "[]") as NSString
    }

    private static func list(_ value: Any?) -> [String] {
        guard let text = value as? String, let data = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func bool(_ value: Any?) -> Bool {
        ((value as? NSNumber)?.intValue ?? 0) != 0
    }
}
