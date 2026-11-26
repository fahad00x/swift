import Foundation

/// Last searches that found something (newest first), kept on the device.
enum RecentSearches {
    private static let key = "recentSearches"
    private static let limit = 8

    static func load() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    static func add(_ term: String) -> [String] {
        var list = load().filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        list.insert(term, at: 0)
        list = Array(list.prefix(limit))
        UserDefaults.standard.set(list, forKey: key)
        return list
    }
}
