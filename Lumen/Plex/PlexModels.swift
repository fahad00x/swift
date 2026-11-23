import Foundation

// MARK: - Lossy decoding helpers

/// Decodes an element if possible, otherwise yields nil, so one malformed item
/// never breaks a whole library page.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension KeyedDecodingContainer {
    func lossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T]? {
        guard let raw = try? decodeIfPresent([Lossy<T>].self, forKey: key) else { return nil }
        return raw.compactMap(\.value)
    }

    func lenientInt(forKey key: Key) -> Int? {
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int(s) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        return nil
    }

    func lenientString(forKey key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        return nil
    }

    func lenientDouble(forKey key: Key) -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }

    func lenientBool(forKey key: Key) -> Bool? {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i != 0 }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s == "1" || s == "true" }
        return nil
    }
}

// MARK: - plex.tv account models

struct PlexPin: Decodable {
    let id: Int
    let code: String
    let authToken: String?
    let expiresIn: Int?
}

struct PlexUser: Codable {
    let id: Int?
    let username: String?
    let title: String?
    let email: String?
    let thumb: String?

    var displayName: String { title ?? username ?? "Plex" }
}

struct PlexConnection: Decodable, Hashable {
    let uri: String
    let local: Bool
    let relay: Bool
    let isHTTPS: Bool

    enum CodingKeys: String, CodingKey { case uri, local, relay, proto = "protocol" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uri = try c.decode(String.self, forKey: .uri)
        local = c.lenientBool(forKey: .local) ?? false
        relay = c.lenientBool(forKey: .relay) ?? false
        isHTTPS = (c.lenientString(forKey: .proto) ?? "") == "https" || uri.hasPrefix("https")
    }

    /// Lower is better: local direct → remote direct → relay, https first.
    var priority: Int {
        let base = relay ? 20 : (local ? 0 : 10)
        return base + (isHTTPS ? 0 : 1)
    }
}

struct PlexResource: Decodable, Identifiable, Hashable {
    let name: String
    let product: String?
    let provides: String?
    let clientIdentifier: String
    let accessToken: String?
    let owned: Bool
    let presence: Bool
    let connections: [PlexConnection]

    var id: String { clientIdentifier }
    var isServer: Bool { provides?.contains("server") ?? false }

    enum CodingKeys: String, CodingKey {
        case name, product, provides, clientIdentifier, accessToken, owned, presence, connections
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Plex"
        product = c.lenientString(forKey: .product)
        provides = c.lenientString(forKey: .provides)
        clientIdentifier = try c.decode(String.self, forKey: .clientIdentifier)
        accessToken = c.lenientString(forKey: .accessToken)
        owned = c.lenientBool(forKey: .owned) ?? false
        presence = c.lenientBool(forKey: .presence) ?? false
        connections = c.lossyArray(PlexConnection.self, forKey: .connections) ?? []
    }
}

// MARK: - Server models

struct MediaContainerResponse: Decodable {
    let mediaContainer: MediaContainer
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
}

struct MediaContainer: Decodable {
    let size: Int?
    let totalSize: Int?
    var metadata: [PlexItem]
    let directories: [PlexDirectory]
    var hubs: [PlexHub]
    let librarySectionID: String?

    enum CodingKeys: String, CodingKey {
        case size, totalSize, librarySectionID
        case metadata = "Metadata", directories = "Directory", hubs = "Hub"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = c.lenientInt(forKey: .size)
        totalSize = c.lenientInt(forKey: .totalSize)
        librarySectionID = c.lenientString(forKey: .librarySectionID)
        directories = c.lossyArray(PlexDirectory.self, forKey: .directories) ?? []
        hubs = c.lossyArray(PlexHub.self, forKey: .hubs) ?? []
        // Library listings carry the section id on the container only.
        let section = librarySectionID
        metadata = (c.lossyArray(PlexItem.self, forKey: .metadata) ?? []).map { item in
            guard item.librarySectionID == nil, let section else { return item }
            var copy = item
            copy.librarySectionID = section
            return copy
        }
    }
}

/// A library section (Movies, TV Shows, …).
struct PlexDirectory: Codable, Identifiable, Hashable {
    let key: String
    let title: String
    let type: String
    let art: String?
    let thumb: String?

    var id: String { key }
    var isVideoLibrary: Bool { type == "movie" || type == "show" }

    enum CodingKeys: String, CodingKey { case key, title, type, art, thumb }

    init(key: String, title: String, type: String) {
        self.key = key
        self.title = title
        self.type = type
        art = nil
        thumb = nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.lenientString(forKey: .key) ?? ""
        let rawTitle = c.lenientString(forKey: .title) ?? ""
        type = c.lenientString(forKey: .type) ?? ""
        // Libraries in Arabic everywhere (sidebar, rows, settings): «Movies - 4K» → «أفلام 4K».
        title = (type == "movie" || type == "show") ? LibraryName.arabic(rawTitle) : rawTitle
        art = c.lenientString(forKey: .art)
        thumb = c.lenientString(forKey: .thumb)
    }
}

/// Arabic display names for libraries named in English («Movies - Kids» → «أفلام أطفال»,
/// «TV - Arabic» → «مسلسلات عربية»). A name with an unknown word is kept as it is.
enum LibraryName {
    private static let bases: [String: String] = [
        "movies": "أفلام", "movie": "أفلام", "films": "أفلام", "film": "أفلام",
        "tv": "مسلسلات", "tv shows": "مسلسلات", "shows": "مسلسلات", "series": "مسلسلات",
        "anime": "أنمي", "documentaries": "وثائقيات", "documentary": "وثائقيات",
        "sports": "رياضة", "sport": "رياضة", "kids": "أطفال", "cartoons": "كرتون",
        "music": "موسيقى", "concerts": "حفلات", "theater": "مسرح", "theatre": "مسرح",
        "stand-up comedy": "ستاند أب كوميدي", "stand-up": "ستاند أب كوميدي", "standup": "ستاند أب كوميدي",
        "home videos": "فيديوهات منزلية", "other videos": "فيديوهات أخرى",
    ]
    /// Whole qualifiers first (phrases), then word by word.
    private static let phrases: [String: String] = [
        "arabic dubbed": "مدبلجة عربي", "arabic dub": "مدبلجة عربي",
        "kids dubbed": "أطفال مدبلجة", "kids dub": "أطفال مدبلجة",
        "kids arabic": "أطفال عربية", "arabic kids": "أطفال عربية",
        "stand-up comedy": "ستاند أب كوميدي",
    ]
    private static let words: [String: String] = [
        "4k": "4K", "uhd": "4K", "hd": "HD", "hdr": "HDR", "anime": "أنمي", "arabic": "عربية",
        "asian": "آسيوية", "korean": "كورية", "japanese": "يابانية", "chinese": "صينية",
        "turkish": "تركية", "indian": "هندية", "hindi": "هندية", "english": "إنجليزية",
        "french": "فرنسية", "spanish": "إسبانية", "documentary": "وثائقية", "documentaries": "وثائقية",
        "doc": "وثائقية", "docs": "وثائقية", "kids": "أطفال", "family": "عائلية", "classic": "كلاسيكية",
        "classics": "كلاسيكية", "dubbed": "مدبلجة", "dub": "مدبلجة", "unsubtitled": "بدون ترجمة",
        "unsubbed": "بدون ترجمة", "subbed": "مترجمة", "reality": "واقع", "ramadan": "رمضان",
        "comedy": "كوميدي", "horror": "رعب", "action": "أكشن", "christmas": "كريسماس",
        "new": "جديدة", "old": "قديمة", "sports": "رياضة", "music": "موسيقى", "theater": "مسرح",
    ]

    /// Whole names that don't follow «base + qualifier».
    private static let names: [String: String] = [
        "theater arabic": "مسرح عربي", "arabic theater": "مسرح عربي", "theatre arabic": "مسرح عربي",
        "tv - reality": "برامج الواقع", "reality": "برامج الواقع", "reality tv": "برامج الواقع",
    ]

    static func arabic(_ raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if let known = names[name.lowercased()] { return known }
        let parts = name.components(separatedBy: " - ")
        guard let base = translate(base: parts[0]) else { return raw }
        guard parts.count > 1 else { return base }
        let rest = parts.dropFirst().joined(separator: " ")
        guard let qualifier = translate(qualifier: rest) else { return raw }
        return base + " " + qualifier
    }

    private static func translate(base: String) -> String? {
        let lower = base.lowercased()
        if let known = bases[lower] { return known }
        // «Theater Arabic»: a known base followed by qualifier words.
        let tokens = lower.split(separator: " ").map(String.init)
        guard tokens.count > 1, let head = bases[tokens[0]],
              let tail = translate(qualifier: tokens.dropFirst().joined(separator: " ")) else { return nil }
        return head + " " + tail
    }

    private static func translate(qualifier: String) -> String? {
        let lower = qualifier.lowercased()
        if let phrase = phrases[lower] { return phrase }
        var out: [String] = []
        for token in lower.split(separator: " ") {
            guard let word = words[String(token)] else { return nil }
            out.append(word)
        }
        return out.isEmpty ? nil : out.joined(separator: " ")
    }
}

struct PlexHub: Decodable, Identifiable {
    let hubIdentifier: String
    let title: String
    let type: String
    /// e.g. "hub.movie.recentlyadded" (more specific than the identifier on some servers).
    let context: String?
    /// Path of the full hub, for paging ("/hubs/sections/1/…").
    let hubKey: String?
    let more: Bool
    var items: [PlexItem]

    var id: String { hubIdentifier }

    enum CodingKeys: String, CodingKey { case hubIdentifier, title, type, context, hubKey, key, more, items = "Metadata" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.lenientString(forKey: .title) ?? ""
        hubIdentifier = c.lenientString(forKey: .hubIdentifier) ?? title
        type = c.lenientString(forKey: .type) ?? ""
        context = c.lenientString(forKey: .context)
        hubKey = c.lenientString(forKey: .key) ?? c.lenientString(forKey: .hubKey)
        more = c.lenientBool(forKey: .more) ?? false
        items = c.lossyArray(PlexItem.self, forKey: .items) ?? []
    }
}

struct PlexTag: Codable, Hashable, Identifiable {
    let tag: String
    let role: String?
    let thumb: String?

    var id: String { tag + (role ?? "") }

    enum CodingKeys: String, CodingKey { case tag, role, thumb }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = c.lenientString(forKey: .tag) ?? ""
        role = c.lenientString(forKey: .role)
        thumb = c.lenientString(forKey: .thumb)
    }
}

/// Artwork variants Plex attaches to metadata (coverPoster, background, clearLogo…).
struct PlexImage: Codable, Hashable {
    let type: String
    let url: String

    enum CodingKeys: String, CodingKey { case type, url }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenientString(forKey: .type) ?? ""
        url = c.lenientString(forKey: .url) ?? ""
    }
}

struct PlexStream: Codable, Hashable, Identifiable {
    let id: Int
    let streamType: Int
    let codec: String?
    let displayTitle: String?
    let extendedDisplayTitle: String?
    let language: String?
    let channels: Int?
    let colorTrc: String?
    let doviPresent: Bool
    let selected: Bool
    /// Present only for sidecar (external) subtitle files.
    let key: String?
    let languageCode: String?
    let title: String?
    let frameRate: Double?
    let width: Int?
    let height: Int?
    /// Position of the stream inside the container (matches mpv's `ff-index`).
    let index: Int?

    enum CodingKeys: String, CodingKey {
        case id, streamType, codec, displayTitle, extendedDisplayTitle, language, channels, colorTrc, selected
        case key, languageCode, title, frameRate, width, height, index
        case doviPresent = "DOVIPresent"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt(forKey: .id) ?? 0
        streamType = c.lenientInt(forKey: .streamType) ?? 0
        codec = c.lenientString(forKey: .codec)
        displayTitle = c.lenientString(forKey: .displayTitle)
        extendedDisplayTitle = c.lenientString(forKey: .extendedDisplayTitle)
        language = c.lenientString(forKey: .language)
        channels = c.lenientInt(forKey: .channels)
        colorTrc = c.lenientString(forKey: .colorTrc)
        doviPresent = c.lenientBool(forKey: .doviPresent) ?? false
        selected = c.lenientBool(forKey: .selected) ?? false
        key = c.lenientString(forKey: .key)
        languageCode = c.lenientString(forKey: .languageCode)
        title = c.lenientString(forKey: .title)
        frameRate = c.lenientDouble(forKey: .frameRate)
        width = c.lenientInt(forKey: .width)
        height = c.lenientInt(forKey: .height)
        index = c.lenientInt(forKey: .index)
    }

    /// Display name for audio/subtitle pickers.
    var label: String { extendedDisplayTitle ?? displayTitle ?? title ?? language ?? "مسار \(id)" }

    var isAtmos: Bool {
        [displayTitle, extendedDisplayTitle, title].compactMap { $0?.lowercased() }.contains { $0.contains("atmos") }
    }
}

/// Intro / credits markers (detected by Plex Media Server, needs Plex Pass on the server).
struct PlexMarker: Codable, Hashable {
    let type: String
    let startMs: Int
    let endMs: Int
    let isFinal: Bool

    var isIntro: Bool { type == "intro" }
    var isCredits: Bool { type == "credits" }

    enum CodingKeys: String, CodingKey {
        case type
        case startMs = "startTimeOffset", endMs = "endTimeOffset", isFinal = "final"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenientString(forKey: .type) ?? ""
        startMs = c.lenientInt(forKey: .startMs) ?? 0
        endMs = c.lenientInt(forKey: .endMs) ?? 0
        isFinal = c.lenientBool(forKey: .isFinal) ?? false
    }
}

struct PlexPart: Codable, Hashable {
    let id: Int?
    let key: String?
    let container: String?
    let size: Int?
    let streams: [PlexStream]

    enum CodingKeys: String, CodingKey { case id, key, container, size, streams = "Stream" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt(forKey: .id)
        key = c.lenientString(forKey: .key)
        container = c.lenientString(forKey: .container)
        size = c.lenientInt(forKey: .size)
        streams = c.lossyArray(PlexStream.self, forKey: .streams) ?? []
    }
}

struct PlexMedia: Codable, Hashable {
    let id: Int?
    let bitrate: Int?
    let width: Int?
    let height: Int?
    let videoResolution: String?
    let container: String?
    let videoCodec: String?
    let audioCodec: String?
    let audioChannels: Int?
    let parts: [PlexPart]

    enum CodingKeys: String, CodingKey {
        case id, bitrate, width, height, videoResolution, container, videoCodec, audioCodec, audioChannels
        case parts = "Part"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt(forKey: .id)
        bitrate = c.lenientInt(forKey: .bitrate)
        width = c.lenientInt(forKey: .width)
        height = c.lenientInt(forKey: .height)
        videoResolution = c.lenientString(forKey: .videoResolution)
        container = c.lenientString(forKey: .container)
        videoCodec = c.lenientString(forKey: .videoCodec)
        audioCodec = c.lenientString(forKey: .audioCodec)
        audioChannels = c.lenientInt(forKey: .audioChannels)
        parts = c.lossyArray(PlexPart.self, forKey: .parts) ?? []
    }

    var resolutionBadge: String? {
        guard let r = videoResolution?.lowercased() else { return nil }
        switch r {
        case "4k": return "4K"
        case "sd": return "SD"
        default: return Int(r) != nil ? "\(r)p" : r.uppercased()
        }
    }
}

/// Any Plex metadata item: movie, show, season, episode…
/// Plex's "UltraBlur" palette for an item's artwork: four corner colours (hex, no "#").
/// Missing on older servers and on some items; every field is optional.
struct PlexUltraBlurColors: Codable, Hashable, Sendable {
    let topLeft: String?
    let topRight: String?
    let bottomLeft: String?
    let bottomRight: String?

    /// Usable only when all four corners are present.
    var isComplete: Bool { [topLeft, topRight, bottomLeft, bottomRight].allSatisfy { ($0?.count ?? 0) >= 6 } }
}

struct PlexItem: Codable, Identifiable, Hashable {
    let ratingKey: String
    let key: String?
    let type: String
    let title: String
    let summary: String?
    let tagline: String?
    let year: Int?
    let thumb: String?
    let art: String?
    /// Playlists: a mosaic of their items ("/playlists/{id}/composite/{stamp}").
    let composite: String?
    let parentThumb: String?
    let grandparentThumb: String?
    let grandparentArt: String?
    let duration: Int?
    // Progress fields are replaced by the active profile's own data (see `applying(_:)`);
    // the values Plex sends are shared by everyone using the account.
    var viewOffset: Int?
    var viewCount: Int?
    let leafCount: Int?
    var viewedLeafCount: Int?
    let childCount: Int?
    let index: Int?
    let parentIndex: Int?
    let parentTitle: String?
    let grandparentTitle: String?
    let parentRatingKey: String?
    let grandparentRatingKey: String?
    let contentRating: String?
    let audienceRating: Double?
    let rating: Double?
    /// Where the ratings come from, e.g. "imdb://image.rating", "themoviedb://image.rating".
    let audienceRatingImage: String?
    let ratingImage: String?
    let studio: String?
    let originallyAvailableAt: String?
    let media: [PlexMedia]
    let genres: [PlexTag]
    let directors: [PlexTag]
    let roles: [PlexTag]
    let markers: [PlexMarker]
    let images: [PlexImage]
    /// e.g. "plex://movie/5d776…" (used for the Plex watchlist).
    let guid: String?
    let addedAt: Int?
    /// When Plex last changed the item (drives the incremental library sync).
    let updatedAt: Int?
    let lastViewedAt: Int?
    /// For extras: trailer, behindTheScenes, featurette…
    let subtype: String?
    var librarySectionID: String?
    let countries: [PlexTag]
    let labels: [PlexTag]
    let collections: [PlexTag]
    let chapters: [PlexChapter]
    /// External ids, e.g. "imdb://tt0944947", "tmdb://1399", "tvdb://121361" (`includeGuids=1`).
    let guids: [String]
    /// Background colours for this item's artwork (Plex UltraBlur), when the server sends them.
    let ultraBlurColors: PlexUltraBlurColors?

    var id: String { ratingKey }

    static func == (lhs: PlexItem, rhs: PlexItem) -> Bool { lhs.ratingKey == rhs.ratingKey }
    func hash(into hasher: inout Hasher) { hasher.combine(ratingKey) }

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, type, title, summary, tagline, year, thumb, art, composite, parentThumb, grandparentThumb,
             grandparentArt, duration, viewOffset, viewCount, leafCount, viewedLeafCount, childCount, index,
             parentIndex, parentTitle, grandparentTitle, parentRatingKey, grandparentRatingKey, contentRating,
             audienceRating, rating, audienceRatingImage, ratingImage, studio, originallyAvailableAt, guid, addedAt, updatedAt, subtype, lastViewedAt, librarySectionID
        case media = "Media", genres = "Genre", directors = "Director", roles = "Role", markers = "Marker", images = "Image"
        case countries = "Country", labels = "Label", collections = "Collection", chapters = "Chapter", guids = "Guid"
        case ultraBlurColors = "UltraBlurColors"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let rk = c.lenientString(forKey: .ratingKey) else {
            throw DecodingError.keyNotFound(CodingKeys.ratingKey, .init(codingPath: c.codingPath, debugDescription: "missing ratingKey"))
        }
        ratingKey = rk
        key = c.lenientString(forKey: .key)
        type = c.lenientString(forKey: .type) ?? ""
        title = c.lenientString(forKey: .title) ?? ""
        // Without the "---" source notes some agents append (display text only).
        summary = ArabicFormat.summary(c.lenientString(forKey: .summary))
        tagline = c.lenientString(forKey: .tagline)
        year = c.lenientInt(forKey: .year)
        thumb = c.lenientString(forKey: .thumb)
        art = c.lenientString(forKey: .art)
        composite = c.lenientString(forKey: .composite)
        parentThumb = c.lenientString(forKey: .parentThumb)
        grandparentThumb = c.lenientString(forKey: .grandparentThumb)
        grandparentArt = c.lenientString(forKey: .grandparentArt)
        duration = c.lenientInt(forKey: .duration)
        viewOffset = c.lenientInt(forKey: .viewOffset)
        viewCount = c.lenientInt(forKey: .viewCount)
        leafCount = c.lenientInt(forKey: .leafCount)
        viewedLeafCount = c.lenientInt(forKey: .viewedLeafCount)
        childCount = c.lenientInt(forKey: .childCount)
        index = c.lenientInt(forKey: .index)
        parentIndex = c.lenientInt(forKey: .parentIndex)
        parentTitle = c.lenientString(forKey: .parentTitle)
        grandparentTitle = c.lenientString(forKey: .grandparentTitle)
        parentRatingKey = c.lenientString(forKey: .parentRatingKey)
        grandparentRatingKey = c.lenientString(forKey: .grandparentRatingKey)
        contentRating = c.lenientString(forKey: .contentRating)
        audienceRating = c.lenientDouble(forKey: .audienceRating)
        rating = c.lenientDouble(forKey: .rating)
        audienceRatingImage = c.lenientString(forKey: .audienceRatingImage)
        ratingImage = c.lenientString(forKey: .ratingImage)
        studio = c.lenientString(forKey: .studio)
        originallyAvailableAt = c.lenientString(forKey: .originallyAvailableAt)
        media = c.lossyArray(PlexMedia.self, forKey: .media) ?? []
        genres = c.lossyArray(PlexTag.self, forKey: .genres) ?? []
        directors = c.lossyArray(PlexTag.self, forKey: .directors) ?? []
        roles = c.lossyArray(PlexTag.self, forKey: .roles) ?? []
        markers = c.lossyArray(PlexMarker.self, forKey: .markers) ?? []
        images = c.lossyArray(PlexImage.self, forKey: .images) ?? []
        guid = c.lenientString(forKey: .guid)
        addedAt = c.lenientInt(forKey: .addedAt)
        updatedAt = c.lenientInt(forKey: .updatedAt)
        subtype = c.lenientString(forKey: .subtype)
        lastViewedAt = c.lenientInt(forKey: .lastViewedAt)
        librarySectionID = c.lenientString(forKey: .librarySectionID)
        countries = c.lossyArray(PlexTag.self, forKey: .countries) ?? []
        labels = c.lossyArray(PlexTag.self, forKey: .labels) ?? []
        collections = c.lossyArray(PlexTag.self, forKey: .collections) ?? []
        chapters = c.lossyArray(PlexChapter.self, forKey: .chapters) ?? []
        // Plex sends [{"id": "imdb://…"}]; the on-device copy of Home stores plain strings.
        let objects = (c.lossyArray(PlexGuid.self, forKey: .guids) ?? []).map(\.id)
        guids = objects.isEmpty ? ((try? c.decodeIfPresent([String].self, forKey: .guids)) ?? nil) ?? [] : objects
        // Plex sends an object; tolerate an array of one, and anything malformed.
        if let colors = try? c.decodeIfPresent(PlexUltraBlurColors.self, forKey: .ultraBlurColors) {
            ultraBlurColors = colors.isComplete ? colors : nil
        } else if let list = try? c.decodeIfPresent([PlexUltraBlurColors].self, forKey: .ultraBlurColors) {
            ultraBlurColors = list.first.flatMap { $0.isComplete ? $0 : nil }
        } else {
            ultraBlurColors = nil
        }
    }
}

extension Array where Element == PlexItem {
    /// Drops repeated items (same ratingKey), keeping the first. SwiftUI lists crash when an
    /// id appears twice (e.g. a library listing that shifted while it was being paged).
    func uniqued() -> [PlexItem] {
        var seen = Set<String>()
        return filter { seen.insert($0.ratingKey).inserted }
    }
}

// MARK: - Per-profile data

extension PlexItem {
    /// Replaces Plex's shared progress / watched values with the active profile's.
    func applying(_ state: UserStateSnapshot) -> PlexItem {
        var copy = self
        switch type {
        case "show", "season":
            copy.viewOffset = nil
            copy.viewCount = nil
            copy.viewedLeafCount = state.watchedCount(under: ratingKey)
        default:
            let entry = state.entry(for: ratingKey)
            let watched = entry?.watched ?? false
            copy.viewCount = watched ? 1 : 0
            copy.viewOffset = (!watched && (entry?.offsetMs ?? 0) > 0) ? entry?.offsetMs : nil
            copy.viewedLeafCount = nil
        }
        return copy
    }

    /// What the profile store records about this item.
    var mediaInfo: MediaInfo {
        MediaInfo(ratingKey: ratingKey, type: type,
                  showKey: isEpisode ? grandparentRatingKey : (isSeason ? parentRatingKey : nil),
                  seasonKey: isEpisode ? parentRatingKey : nil,
                  sectionKey: librarySectionID,
                  sortIndex: isEpisode ? (parentIndex ?? 0) * 10_000 + (index ?? 0) : nil,
                  genres: genres.map(\.tag),
                  durationMs: duration ?? 0)
    }
}

// MARK: - Presentation helpers

extension PlexItem {
    var isEpisode: Bool { type == "episode" }
    var isShow: Bool { type == "show" }
    var isSeason: Bool { type == "season" }
    var isPlayable: Bool { type == "movie" || type == "episode" }

    var isWatched: Bool {
        if isShow || isSeason, let leaf = leafCount, let viewed = viewedLeafCount { return leaf > 0 && viewed >= leaf }
        return (viewCount ?? 0) > 0
    }

    var unwatchedCount: Int? {
        guard isShow || isSeason, let leaf = leafCount else { return nil }
        let remaining = leaf - (viewedLeafCount ?? 0)
        return remaining > 0 ? remaining : nil
    }

    /// 0…1 when partially watched.
    var progress: Double? {
        guard let offset = viewOffset, let duration, duration > 0, offset > 0 else { return nil }
        return min(1, Double(offset) / Double(duration))
    }

    var posterPath: String? {
        if isEpisode { return grandparentThumb ?? parentThumb ?? thumb }
        if isSeason { return thumb ?? parentThumb }
        if type == "playlist" { return thumb ?? composite }
        return thumb
    }

    var landscapePath: String? {
        if isEpisode { return thumb ?? art ?? grandparentArt }
        return art ?? thumb
    }

    var backdropPath: String? { art ?? grandparentArt ?? thumb }

    /// "الموسم ١  •  الحلقة ٧"
    var episodeCode: String? {
        guard isEpisode else { return nil }
        return ArabicFormat.episodeCode(season: parentIndex, episode: index)
    }

    var cardTitle: String { isEpisode ? (grandparentTitle ?? title) : title }

    /// "الموسم ١  •  الحلقة ٧ — <title>" for an episode, the show for a season, else the year.
    var cardSubtitle: String? {
        if isEpisode { return ArabicFormat.episodeLine(season: parentIndex, episode: index, title: title) }
        if isSeason { return parentTitle }
        return year.map { ArabicFormat.digits($0) }
    }

    /// Rating code without the agent's description or country prefix ("PG-13 - Teens…" → "PG-13").
    var normalizedContentRating: String? { ArabicFormat.contentRating(contentRating) }

    var durationText: String? { duration.map(PlexItem.format(ms:)) }

    var remainingText: String? {
        guard let duration, let offset = viewOffset, offset > 0 else { return nil }
        return PlexItem.format(ms: max(0, duration - offset)) + " متبقية"
    }

    static func format(ms: Int) -> String {
        ArabicFormat.duration(ms: ms)
    }

    /// Rating with its source (IMDb, TMDB, MAL…) as the server's agent provided it.
    var ratingDisplay: (source: String, value: Double)? {
        func source(_ image: String?) -> String {
            let s = (image ?? "").lowercased()
            if s.contains("imdb") { return "IMDb" }
            if s.contains("themoviedb") || s.contains("tmdb") { return "TMDB" }
            if s.contains("myanimelist") || s.hasPrefix("mal") { return "MAL" }
            if s.contains("anidb") { return "AniDB" }
            if s.contains("tvdb") { return "TVDB" }
            if s.contains("rottentomatoes") { return "RT" }
            return ""
        }
        if let v = audienceRating, v > 0 { return (source(audienceRatingImage), v) }
        if let v = rating, v > 0 { return (source(ratingImage), v) }
        return nil
    }

    var primaryPart: PlexPart? { media.first?.parts.first }
    var streams: [PlexStream] { primaryPart?.streams ?? [] }
    var videoStream: PlexStream? { streams.first { $0.streamType == 1 } }
    var audioStreams: [PlexStream] { streams.filter { $0.streamType == 2 } }
    var subtitleStreams: [PlexStream] { streams.filter { $0.streamType == 3 } }

    /// Transparent title artwork, when the server provides one.
    var clearLogoPath: String? { images.first { $0.type == "clearLogo" && !$0.url.isEmpty }?.url }

    /// Plex Discover id for the watchlist (only for items matched by the Plex agents).
    var discoverID: String? {
        guard let guid, guid.hasPrefix("plex://") else { return nil }
        return guid.split(separator: "/").last.map(String.init)
    }

    var introMarker: PlexMarker? { markers.first { $0.isIntro && $0.endMs > $0.startMs } }
    /// The final credits marker (or the last one), i.e. where "Next episode" should appear.
    var creditsMarker: PlexMarker? {
        let credits = markers.filter(\.isCredits)
        return credits.first(where: \.isFinal) ?? credits.last
    }

    var isHDR: Bool { dynamicRangeBadge != nil }

    var dynamicRangeBadge: String? {
        guard let v = videoStream else { return nil }
        if v.doviPresent { return "Dolby Vision" }
        switch v.colorTrc?.lowercased() {
        case "smpte2084": return "HDR10"
        case "arib-std-b67": return "HLG"
        default: return nil
        }
    }

    var audioBadge: String? {
        guard let m = media.first, let codec = m.audioCodec?.uppercased() else { return nil }
        let channels: String
        switch m.audioChannels ?? 0 {
        case 8: channels = " 7.1"
        case 6: channels = " 5.1"
        case 2: channels = " 2.0"
        default: channels = ""
        }
        return codec + channels
    }
}
