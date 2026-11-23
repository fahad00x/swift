import Foundation

/// plex.tv account API: PIN linking, user info and server discovery.
enum PlexAccount {
    private static let base = "https://plex.tv"

    /// Creates a short 4-character PIN that the user enters at plex.tv/link.
    static func createPin() async throws -> PlexPin {
        guard let url = PlexHTTP.url(base: base, path: "/api/v2/pins", query: [("strong", "false")]) else { throw PlexError.invalidURL }
        return try await PlexHTTP.decode(PlexPin.self, from: PlexHTTP.request(url, method: "POST", token: nil))
    }

    static func checkPin(id: Int) async throws -> PlexPin {
        guard let url = PlexHTTP.url(base: base, path: "/api/v2/pins/\(id)") else { throw PlexError.invalidURL }
        return try await PlexHTTP.decode(PlexPin.self, from: PlexHTTP.request(url, token: nil))
    }

    static func user(token: String) async throws -> PlexUser {
        guard let url = PlexHTTP.url(base: base, path: "/api/v2/user") else { throw PlexError.invalidURL }
        return try await PlexHTTP.decode(PlexUser.self, from: PlexHTTP.request(url, token: token))
    }

    static func servers(token: String) async throws -> [PlexResource] {
        guard let url = PlexHTTP.url(base: base, path: "/api/v2/resources",
                                     query: [("includeHttps", "1"), ("includeRelay", "1"), ("includeIPv6", "0")])
        else { throw PlexError.invalidURL }
        let data = try await PlexHTTP.data(for: PlexHTTP.request(url, token: token))
        let all = try JSONDecoder().decode([Lossy<PlexResource>].self, from: data).compactMap(\.value)
        return all.filter(\.isServer).sorted { ($0.owned ? 0 : 1, $0.name) < ($1.owned ? 0 : 1, $1.name) }
    }

    /// Probes every connection of a server in parallel and returns the best reachable one.
    static func bestConnection(for resource: PlexResource, token: String) async -> PlexConnection? {
        let candidates = resource.connections.sorted { $0.priority < $1.priority }
        return await withTaskGroup(of: PlexConnection?.self) { group in
            for connection in candidates {
                group.addTask {
                    guard let url = PlexHTTP.url(base: connection.uri, path: "/identity") else { return nil }
                    let req = PlexHTTP.request(url, token: token)
                    do {
                        try await PlexHTTP.data(for: req, session: PlexHTTP.probeSession)
                        return connection
                    } catch {
                        return nil
                    }
                }
            }
            var best: PlexConnection?
            for await result in group {
                guard let result else { continue }
                if best == nil || result.priority < best!.priority { best = result }
                // A direct local connection can't be beaten; stop waiting for the rest.
                if result.priority == 0 { group.cancelAll(); break }
            }
            return best
        }
    }
}
