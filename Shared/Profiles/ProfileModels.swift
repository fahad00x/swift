import CryptoKit
import Foundation

// Platform-independent profile models (no UI, no Plex types), shared by the tvOS app
// and any future iPad / iPhone app that uses the same CloudKit container.

/// An in-app viewer ("Who's watching?"). Every profile uses the same Plex account and token;
/// everything personal (progress, watched marks, My List, libraries, preferred tracks) is per profile.
struct UserProfile: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// SF Symbol name.
    var symbol: String
    /// "#RRGGBB"
    var colorHex: String
    var isKids: Bool
    /// The main profile ("أنا"): its PIN unlocks kids' settings, and it can't be deleted.
    var isOwner: Bool
    /// SHA-256 of the PIN salted with the profile id. Never the PIN itself.
    var pinHash: String?
    /// Enabled library scopes, in tab order (see `ScopeID`).
    var scopes: [String]
    /// Every server library this profile has already seen; any other library is new (and locked).
    var knownSections: [String]
    /// Plex genre tags (English, as on the server) to focus rows and suggestions on. Empty = all.
    var genres: [String]
    /// ISO 639-2 codes as reported by Plex / mpv ("ara", "eng", …).
    var preferredAudioLanguage: String?
    var preferredSubtitleLanguage: String?
    var subtitlesOff: Bool
    /// Sidebar libraries and playback preferences (one JSON field in iCloud, so new settings
    /// need no CloudKit schema change). nil on profiles saved before it existed.
    var settings: ProfileSettings?
    var createdAt: Date
    var modifiedAt: Date

    init(id: String = UUID().uuidString, name: String, symbol: String, colorHex: String,
         isKids: Bool = false, isOwner: Bool = false, pinHash: String? = nil,
         scopes: [String] = [], knownSections: [String] = [], genres: [String] = []) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.colorHex = colorHex
        self.isKids = isKids
        self.isOwner = isOwner
        self.pinHash = pinHash
        self.scopes = scopes
        self.knownSections = knownSections
        self.genres = genres
        preferredAudioLanguage = nil
        preferredSubtitleLanguage = nil
        subtitlesOff = false
        createdAt = Date()
        modifiedAt = Date()
    }

    var recordName: String { "profile-\(id)" }
    var hasPIN: Bool { pinHash != nil }

    /// Changes that affect what the profile sees (used to rebuild the browsing UI).
    var contentSignature: String {
        "\(isKids)|\(scopes.joined(separator: ","))|\(genres.joined(separator: ","))"
    }
}

/// Per-profile settings that follow the profile to every device.
struct ProfileSettings: Codable, Hashable, Sendable {
    /// Libraries pinned to the Apple TV sidebar, in order (scope ids).
    var sidebarScopes: [String]?
    var autoSkipIntro: Bool?
    var autoPlayNext: Bool?

    /// Device keys these mirror (the players read them from UserDefaults).
    static let autoSkipIntroKey = "playback.autoSkipIntro"
    static let autoPlayNextKey = "playback.autoPlayNext"
}

/// Playback progress, watched mark and chosen tracks of one item for one profile.
struct MediaState: Codable, Identifiable, Hashable, Sendable {
    var profileID: String
    var ratingKey: String
    var type: String
    var showKey: String?
    var seasonKey: String?
    var sectionKey: String?
    /// season × 10 000 + episode, to order a show's episodes.
    var sortIndex: Int?
    var genres: [String]
    var offsetMs: Int
    var durationMs: Int
    var watched: Bool
    var lastViewedAt: Date
    /// Plex stream id chosen for this item (nil = use the profile's language preference).
    var audioStreamID: Int?
    /// Plex stream id, 0 = subtitles off, nil = use the profile's preference.
    var subtitleStreamID: Int?
    var modifiedAt: Date

    var id: String { recordName }
    var recordName: String { Self.recordName(profileID: profileID, ratingKey: ratingKey) }
    static func recordName(profileID: String, ratingKey: String) -> String { "state-\(profileID)-\(ratingKey)" }

    var progress: Double? {
        guard durationMs > 0, offsetMs > 0 else { return nil }
        return min(1, Double(offsetMs) / Double(durationMs))
    }
}

/// An item on a profile's "قائمتي" (My List).
struct WatchlistEntry: Codable, Identifiable, Hashable, Sendable {
    var profileID: String
    var ratingKey: String
    var type: String
    var sectionKey: String?
    var addedAt: Date
    var modifiedAt: Date

    var id: String { recordName }
    var recordName: String { Self.recordName(profileID: profileID, ratingKey: ratingKey) }
    static func recordName(profileID: String, ratingKey: String) -> String { "list-\(profileID)-\(ratingKey)" }
}

/// What the store needs to know about a media item (built by the app from its Plex model).
struct MediaInfo: Hashable, Sendable {
    var ratingKey: String
    var type: String
    var showKey: String?
    var seasonKey: String?
    var sectionKey: String?
    var sortIndex: Int?
    var genres: [String]
    var durationMs: Int
}

/// A library scope a profile can enable: a whole library, or (when anime is mixed in)
/// only its anime / only its non-anime titles. Stored as "all:12", "anime:12", "noanime:12".
struct ScopeID: Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case all
        case anime
        case noAnime = "noanime"
    }

    let kind: Kind
    let sectionKey: String

    init(_ kind: Kind, _ sectionKey: String) {
        self.kind = kind
        self.sectionKey = sectionKey
    }

    init?(raw: String) {
        guard let colon = raw.firstIndex(of: ":"),
              let kind = Kind(rawValue: String(raw[..<colon])) else { return nil }
        self.kind = kind
        sectionKey = String(raw[raw.index(after: colon)...])
    }

    var raw: String { "\(kind.rawValue):\(sectionKey)" }
}

enum ProfilePIN {
    static let length = 4

    static func hash(_ pin: String, profileID: String) -> String {
        let digest = SHA256.hash(data: Data("lumen.pin|\(profileID)|\(pin)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func verify(_ pin: String, profile: UserProfile) -> Bool {
        guard let stored = profile.pinHash else { return true }
        return hash(pin, profileID: profile.id) == stored
    }
}
