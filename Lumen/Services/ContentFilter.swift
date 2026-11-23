import SwiftUI

/// A library (or its anime / non-anime half) as a tab, row source and filter.
struct LibraryScope: Identifiable, Hashable {
    let kind: ScopeID.Kind
    let section: PlexDirectory
    /// Tab title, e.g. «الأفلام», «أنمي», «المسلسلات بدون أنمي».
    var title: String
    /// For row titles: «أضيف مؤخراً في \(rowName)».
    var rowName: String

    var id: String { ScopeID(kind, section.key).raw }

    var icon: String {
        switch kind {
        case .anime: return "sparkles"
        case .all, .noAnime: return section.type == "show" ? "tv" : "film"
        }
    }

    static func defaultTitles(kind: ScopeID.Kind, section: PlexDirectory) -> (title: String, rowName: String) {
        switch kind {
        case .all: return (section.title, section.title)
        case .anime: return ("أنمي", "الأنمي")
        case .noAnime: return ("\(section.title) بدون أنمي", "\(section.title) (بدون أنمي)")
        }
    }
}

enum AnimeClassifier {
    /// Anime genre, or Animation from Japan, or an "Anime" label / collection.
    static func isAnime(_ item: PlexItem) -> Bool {
        let genres = Set(item.genres.map { $0.tag.lowercased() })
        if genres.contains("anime") || genres.contains("أنمي") { return true }
        if genres.contains("animation") || genres.contains("رسوم متحركة") {
            let japan: Set<String> = ["japan", "jp", "ja", "اليابان"]
            if item.countries.contains(where: { japan.contains($0.tag.lowercased()) }) { return true }
        }
        let tags = item.labels + item.collections
        return tags.contains { ["anime", "أنمي"].contains($0.tag.lowercased()) }
    }

    /// Whether a library mixes anime with other titles (from a sample of its items).
    static func libraryHasAnime(_ section: PlexDirectory, client: PlexServerClient) async -> Bool {
        guard let page = try? await client.items(section: section, sort: .recentlyAdded, start: 0, size: 400) else { return false }
        return page.items.contains(where: isAnime)
    }
}

/// What the active profile may see: enabled libraries / anime scopes, kids ratings, genre focus.
/// Locked libraries and scopes are hidden everywhere: tabs, hero, rows, search, Continue Watching.
struct ContentFilter {
    let scopes: [LibraryScope]
    let isKids: Bool
    /// Lowercased Plex genre tags to focus rows and suggestions on (empty = all genres).
    let focusGenres: Set<String>
    private let kindsBySection: [String: Set<ScopeID.Kind>]
    private let allowsEverything: Bool

    static let unrestricted = ContentFilter()

    private init() {
        scopes = []
        isKids = false
        focusGenres = []
        kindsBySection = [:]
        allowsEverything = true
    }

    init(profile: UserProfile, sections: [PlexDirectory]) {
        let byKey = Dictionary(sections.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var scopes: [LibraryScope] = []
        var kinds: [String: Set<ScopeID.Kind>] = [:]
        for raw in profile.scopes {
            guard let id = ScopeID(raw: raw), let section = byKey[id.sectionKey],
                  !scopes.contains(where: { $0.id == raw }) else { continue }
            let names = LibraryScope.defaultTitles(kind: id.kind, section: section)
            scopes.append(LibraryScope(kind: id.kind, section: section, title: names.title, rowName: names.rowName))
            kinds[section.key, default: []].insert(id.kind)
        }
        // Several anime tabs: say which library each one comes from.
        let animeCount = scopes.filter { $0.kind == .anime }.count
        if animeCount > 1 {
            for i in scopes.indices where scopes[i].kind == .anime {
                scopes[i].title = "أنمي" + ArabicFormat.separator + ArabicFormat.isolated(scopes[i].section.title)
                scopes[i].rowName = "أنمي \(scopes[i].section.title)"
            }
        }
        self.scopes = scopes
        kindsBySection = kinds
        isKids = profile.isKids
        focusGenres = Set(profile.genres.map { $0.lowercased() })
        allowsEverything = false
    }

    /// Changes whenever what the profile may see changes (libraries, kids mode, genre focus).
    var signature: String {
        scopes.map(\.id).joined(separator: ",") + "|\(isKids)|" + focusGenres.sorted().joined(separator: ",")
    }

    /// Distinct libraries behind the enabled scopes, in tab order.
    var sections: [PlexDirectory] {
        var seen = Set<String>()
        return scopes.map(\.section).filter { seen.insert($0.key).inserted }
    }

    /// The library is split (anime / non-anime) for this profile, so its items need tags.
    func isSplit(_ sectionKey: String) -> Bool {
        guard let kinds = kindsBySection[sectionKey] else { return false }
        return !kinds.contains(.all)
    }

    // MARK: Decisions

    static let kidsRatings: Set<String> = ["G", "PG", "TV-Y", "TV-Y7", "TV-Y7-FV", "TV-G", "TV-PG"]

    /// Compares the normalized code, so "PG - Children" (anime agents) or "us/TV-Y7" count as PG / TV-Y7.
    static func isKidSafe(_ rating: String?) -> Bool {
        guard let r = ArabicFormat.contentRating(rating) else { return false }
        return kidsRatings.contains(r)
    }

    /// `owner` is the show of an episode / season (or the item's own full metadata).
    func allows(_ item: PlexItem, owner: PlexItem? = nil) -> Bool {
        if allowsEverything { return true }
        guard passesKids(item, owner: owner), let section = sectionKey(item, owner: owner),
              let kinds = kindsBySection[section] else { return false }
        if kinds.contains(.all) { return true }
        let anime = AnimeClassifier.isAnime(tagSource(item, owner: owner))
        return anime ? kinds.contains(.anime) : kinds.contains(.noAnime)
    }

    func matches(_ item: PlexItem, scope: LibraryScope, owner: PlexItem? = nil) -> Bool {
        if allowsEverything { return true }
        guard passesKids(item, owner: owner), sectionKey(item, owner: owner) == scope.section.key else { return false }
        switch scope.kind {
        case .all: return true
        case .anime: return AnimeClassifier.isAnime(tagSource(item, owner: owner))
        case .noAnime: return !AnimeClassifier.isAnime(tagSource(item, owner: owner))
        }
    }

    /// Item has one of the focus genres (always true without a focus).
    func isFocused(_ item: PlexItem, owner: PlexItem? = nil) -> Bool {
        guard !focusGenres.isEmpty else { return true }
        return tagSource(item, owner: owner).genres.contains { focusGenres.contains($0.tag.lowercased()) }
    }

    private func passesKids(_ item: PlexItem, owner: PlexItem?) -> Bool {
        guard isKids else { return true }
        let rating = (item.contentRating?.isEmpty == false ? item.contentRating : nil) ?? owner?.contentRating
        return Self.isKidSafe(rating)
    }

    private func sectionKey(_ item: PlexItem, owner: PlexItem?) -> String? {
        item.librarySectionID ?? owner?.librarySectionID
    }

    private func tagSource(_ item: PlexItem, owner: PlexItem?) -> PlexItem {
        if item.isEpisode || item.isSeason { return owner ?? item }
        if item.genres.isEmpty, let owner { return owner }
        return item
    }

    // MARK: Resolution (fetches missing metadata when needed)

    private static func ownerKey(_ item: PlexItem) -> String {
        switch item.type {
        case "episode": return item.grandparentRatingKey ?? item.ratingKey
        case "season": return item.parentRatingKey ?? item.ratingKey
        default: return item.ratingKey
        }
    }

    private func needsOwner(_ item: PlexItem, splitCheck: Bool) -> Bool {
        if allowsEverything { return false }
        if item.librarySectionID == nil { return true }
        let child = item.isEpisode || item.isSeason
        if isKids, child, item.contentRating?.isEmpty ?? true { return true }
        if splitCheck || !focusGenres.isEmpty {
            if child { return true }
            if item.genres.isEmpty { return true }
        }
        return false
    }

    /// Keeps the items this profile may see (in `scope` when given). Episodes are judged by their
    /// show (genres, country, labels, rating); missing metadata is fetched and cached.
    func resolve(_ items: [PlexItem], client: PlexServerClient, scope: LibraryScope? = nil,
                 focusedOnly: Bool = false) async -> [PlexItem] {
        if allowsEverything && !focusedOnly { return items }
        let needing = items.filter { item in
            let split = scope.map { $0.kind != .all } ?? item.librarySectionID.map(isSplit) ?? true
            return needsOwner(item, splitCheck: split || focusedOnly)
        }
        let keys = Set(needing.map(Self.ownerKey))
        var owners: [String: PlexItem] = [:]
        await withTaskGroup(of: (String, PlexItem?).self) { group in
            for key in keys {
                group.addTask { (key, await client.cachedMetadata(key)) }
            }
            for await (key, item) in group { if let item { owners[key] = item } }
        }
        return items.filter { item in
            let owner = owners[Self.ownerKey(item)]
            let visible = scope.map { matches(item, scope: $0, owner: owner) } ?? allows(item, owner: owner)
            return visible && (!focusedOnly || isFocused(item, owner: owner))
        }
    }
}

private struct ContentFilterKey: EnvironmentKey {
    static let defaultValue = ContentFilter.unrestricted
}

extension EnvironmentValues {
    var contentFilter: ContentFilter {
        get { self[ContentFilterKey.self] }
        set { self[ContentFilterKey.self] = newValue }
    }
}
