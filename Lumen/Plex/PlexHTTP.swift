import Foundation

enum PlexError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case http(Int)
    case unreachable(String)
    case notPlayable
    case notCached

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "رابط غير صالح."
        case .invalidResponse: return "استجابة غير متوقعة من الخادم."
        case .unauthorized: return "انتهت صلاحية الجلسة، يرجى تسجيل الدخول من جديد."
        case .http(let code): return "خطأ من الخادم (\(code))."
        case .unreachable(let name): return "تعذّر الوصول إلى الخادم «\(name)». تأكد أنه يعمل وأن الوصول عن بُعد مفعّل."
        case .notPlayable: return "لا يمكن تشغيل هذا العنصر."
        case .notCached: return "غير محفوظ على الجهاز."
        }
    }
}

/// Identity this app presents to Plex (shows up under Settings → Devices on plex.tv).
enum PlexClientInfo {
    static let product = "Lumen"
    #if os(tvOS)
    static let platform = "tvOS"
    static let device = "Apple TV"
    #else
    static let platform = "iOS"
    static let device = "iPhone"
    #endif
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    /// Build number (increases with every CI build); shown in Settings to tell builds apart.
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
    static var platformVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    static let identifier: String = {
        let key = "plex.clientIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }()

    static var headers: [String: String] {
        [
            "Accept": "application/json",
            "X-Plex-Product": product,
            "X-Plex-Version": version,
            "X-Plex-Client-Identifier": identifier,
            "X-Plex-Platform": platform,
            "X-Plex-Platform-Version": platformVersion,
            "X-Plex-Device": device,
            "X-Plex-Device-Name": "Lumen (\(device))",
            "X-Plex-Language": Locale.preferredLanguages.first ?? "ar",
        ]
    }

    /// Same identity as query parameters, for URLs handed to AVPlayer.
    static var queryItems: [(String, String)] {
        headers.filter { $0.key.hasPrefix("X-Plex") }.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }
}

enum PlexHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 6
        return URLSession(configuration: config)
    }()

    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Builds `base + path` with strictly percent-encoded query values
    /// (Plex paths like `/:/timeline` and nested `url=` params need this).
    static func url(base: String, path: String, query: [(String, String)] = []) -> URL? {
        var s = base.hasSuffix("/") ? String(base.dropLast()) : base
        s += path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty {
            s += (path.contains("?") ? "&" : "?")
            s += query.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        }
        return URL(string: s)
    }

    static func request(_ url: URL, method: String = "GET", token: String?) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        for (k, v) in PlexClientInfo.headers { req.setValue(v, forHTTPHeaderField: k) }
        if let token { req.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
        return req
    }

    @discardableResult
    static func data(for request: URLRequest, session: URLSession = PlexHTTP.session) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PlexError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw PlexError.unauthorized
        default: throw PlexError.http(http.statusCode)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from request: URLRequest) async throws -> T {
        let data = try await Self.data(for: request)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
