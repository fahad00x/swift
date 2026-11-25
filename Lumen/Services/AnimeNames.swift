import Foundation

/// Other titles of anime (Japanese in Latin letters, short names, Arabic) by their TVDB / TMDB /
/// IMDb id, from a file in the app (scripts/build_anime_index.py): search knows them at once,
/// with no network. Contains information from the anime-offline-database (ODbL 1.0).
struct AnimeNames: Sendable {
    private let lists: [[String]]
    private let ids: [String: Int]

    /// Read once, when first needed (off the main thread).
    static let shared: AnimeNames = {
        struct File: Decodable { let names: [[String]]; let ids: [String: Int] }
        guard let url = Bundle.main.url(forResource: "AnimeNames", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return AnimeNames(lists: [], ids: [:]) }
        return AnimeNames(lists: file.names, ids: file.ids)
    }()

    func names(of item: PlexItem) -> [String] {
        guard !ids.isEmpty else { return [] }
        let movie = item.type == "movie"
        for kind in ["tvdb://", "tmdb://", "imdb://"] where !(movie && kind == "tvdb://") {
            for guid in item.guids where guid.hasPrefix(kind) {
                let key = movie && kind == "tmdb://" ? "m:" + guid : guid
                if let index = ids[key], lists.indices.contains(index) { return lists[index] }
            }
        }
        return []
    }
}
