import Foundation
import Observation

/// App-wide state: sign-in, server choice and the active server client.
@MainActor
@Observable
final class AppSession {
    enum Phase: Equatable {
        case launching
        case signedOut
        case selectingServer
        case connecting(String)
        case ready
        case failed(String)
    }

    private static let tokenKey = "plex.authToken"
    private static let lastServerKey = "plex.lastServer"

    var phase: Phase = .launching
    var user: PlexUser?
    var servers: [PlexResource] = []
    var client: PlexServerClient?
    var sections: [PlexDirectory] = []
    let profiles = ProfileStore.shared
    /// A background refresh (connection / libraries) is running: show a small indicator only.
    private(set) var isRefreshing = false

    private var token: String?

    private static func serverTokenKey(_ id: String) -> String { "plex.serverToken.\(id)" }

    /// Cache-first launch: with a saved server, open immediately on the last connection and
    /// libraries, then check everything with the server and plex.tv in the background.
    /// Only the very first launch (nothing saved) waits on the network.
    func bootstrap() async {
        guard phase == .launching else { return }
        guard let saved = Keychain.get(Self.tokenKey) else {
            phase = .signedOut
            return
        }
        token = saved
        Task.detached(priority: .background) { PlexResponseCache.trim() }
        if let cached = CachedServer.load(), !cached.sections.isEmpty,
           let serverToken = Keychain.get(Self.serverTokenKey(cached.id)) {
            user = cached.user
            client = PlexServerClient(cached: cached, token: serverToken, accountToken: saved,
                                      userState: profiles.snapshot)
            sections = cached.sections
            _ = await profiles.prepare(sectionKeys: cached.sections.map(\.key))
            phase = .ready
            if let client { LibrarySync.shared.start(client: client) }
            Task { await revalidate() }
            return
        }
        await loadAccount()
    }

    /// Background check after a cache-first launch (or «تحديث المكتبة»): keeps the saved
    /// connection if it still answers, otherwise finds the best one again; refreshes the
    /// libraries, the account and the server list. Never blocks the UI.
    func revalidate() async {
        guard let token, let current = client, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let userTask = try? PlexAccount.user(token: token)
        async let serversTask = PlexAccount.servers(token: token)
        do {
            servers = try await serversTask
        } catch PlexError.unauthorized {
            signOut()
            return
        } catch {
            // Offline / plex.tv down: keep using what's saved.
        }
        if let fresh = await userTask { user = fresh }

        var active = current
        if !(await current.isReachable()),
           let server = servers.first(where: { $0.id == current.machineIdentifier }),
           let connection = await PlexAccount.bestConnection(for: server, token: server.accessToken ?? token) {
            active = PlexServerClient(resource: server, connection: connection, accountToken: token,
                                      userState: profiles.snapshot)
            client = active
            remember(server: server, connection: connection)
            NotificationCenter.default.post(name: .libraryShouldRefresh, object: nil)
        }
        if let fresh = try? await active.sections(), !fresh.isEmpty, fresh != sections {
            sections = fresh
        }
        saveCache()
        // Picks up what changed on the server (only changed libraries / items are fetched).
        LibrarySync.shared.start(client: active, force: true)
    }

    /// «تحديث المكتبة» in Settings: everything from the server again.
    func refreshLibrary() async {
        await revalidate()
        NotificationCenter.default.post(name: .libraryShouldRefresh, object: nil)
    }

    private func remember(server: PlexResource, connection: PlexConnection) {
        if let serverToken = server.accessToken ?? token {
            Keychain.set(serverToken, for: Self.serverTokenKey(server.id))
        }
        UserDefaults.standard.set(server.id, forKey: Self.lastServerKey)
        CachedServer(id: server.id, name: server.name, uri: connection.uri, isLocal: connection.local,
                     sections: sections, user: user).save()
    }

    private func saveCache() {
        guard let client, var cached = CachedServer.load(), cached.id == client.machineIdentifier else { return }
        cached.sections = sections
        cached.user = user
        cached.uri = client.baseURL
        cached.isLocal = client.isLocal
        cached.save()
    }

    func completeSignIn(token: String) async {
        Keychain.set(token, for: Self.tokenKey)
        self.token = token
        await loadAccount()
    }

    /// Called by the sign-in screen once plex.tv approves the PIN. Runs in a task the screen
    /// doesn't own, so replacing the screen doesn't cancel the account / server requests.
    func beginSignIn(token: String) {
        Task { await completeSignIn(token: token) }
    }

    /// A cancelled request (the screen that started it went away) is not a failure to show.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return false
    }

    func retry() async {
        if token == nil { phase = .signedOut } else { await loadAccount() }
    }

    func loadAccount() async {
        guard let token else { phase = .signedOut; return }
        phase = .connecting("جارٍ تحميل حسابك…")
        do {
            async let userTask = PlexAccount.user(token: token)
            async let serversTask = PlexAccount.servers(token: token)
            user = try await userTask
            servers = try await serversTask
        } catch PlexError.unauthorized {
            signOut()
            return
        } catch where Self.isCancellation(error) {
            // Retry in a fresh task instead of showing «مُلغى».
            Task { await self.loadAccount() }
            return
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        if servers.isEmpty {
            phase = .failed("لا توجد خوادم Plex مرتبطة بهذا الحساب.")
        } else if let last = UserDefaults.standard.string(forKey: Self.lastServerKey),
                  let server = servers.first(where: { $0.id == last }) {
            await connect(to: server)
        } else if servers.count == 1 {
            await connect(to: servers[0])
        } else {
            phase = .selectingServer
        }
    }

    func connect(to server: PlexResource) async {
        guard let token else { phase = .signedOut; return }
        phase = .connecting("جارٍ الاتصال بـ «\(server.name)»…")
        guard let connection = await PlexAccount.bestConnection(for: server, token: server.accessToken ?? token) else {
            phase = .failed(PlexError.unreachable(server.name).localizedDescription)
            return
        }
        let client = PlexServerClient(resource: server, connection: connection, accountToken: token,
                                      userState: profiles.snapshot)
        do {
            sections = try await client.sections()
            self.client = client
            remember(server: server, connection: connection)
            phase = .connecting("جارٍ تحميل المستخدمين…")
            let firstRun = await profiles.prepare(sectionKeys: sections.map(\.key))
            if firstRun, let owner = profiles.owner {
                // Data from before profiles (Plex progress / watched / watchlist) goes to «أنا».
                let sections = self.sections
                Task { await ProfileMigration.run(client: client, sections: sections, store: self.profiles, into: owner.id) }
            }
            phase = .ready
            LibrarySync.shared.start(client: client, force: true)
        } catch where Self.isCancellation(error) {
            Task { await self.connect(to: server) }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func chooseAnotherServer() {
        client = nil
        sections = []
        CachedServer.clear()
        UserDefaults.standard.removeObject(forKey: Self.lastServerKey)
        phase = servers.isEmpty ? .signedOut : .selectingServer
    }

    func signOut() {
        profiles.deactivate()
        Keychain.set(nil, for: Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.lastServerKey)
        if let id = client?.machineIdentifier { Keychain.set(nil, for: Self.serverTokenKey(id)) }
        CachedServer.clear()
        PlexResponseCache.clear()
        token = nil
        user = nil
        servers = []
        client = nil
        sections = []
        phase = .signedOut
    }
}

/// Backdrop shown behind browsing screens; follows the focused item (Infuse-style).
@MainActor
@Observable
final class BackdropState {
    var url: URL?
}

enum PlaybackEngine: String, CaseIterable, Identifiable {
    case mpv, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mpv: return "Lumen (MPV) — كل الصيغ"
        case .system: return "مشغّل النظام (AVPlayer)"
        }
    }
}

/// How styled (ASS) subtitles look.
enum SubtitleLook: String, CaseIterable, Identifiable, Sendable {
    /// As the translator made them.
    case original
    /// Dialogue in the app's look; signs and songs placed on the picture keep theirs.
    case dialogue

    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "الأصلي"
        case .dialogue: return "توحيد الحوار"
        }
    }
}

enum PlaybackSettings {
    static let engineKey = "playback.engine"
    static let fastProfileKey = "playback.mpvFastProfile"
    static let autoSkipIntroKey = "playback.autoSkipIntro"
    static let autoPlayNextKey = "playback.autoPlayNext"
    static let forceTranscodeKey = "playback.forceTranscode"
    static let maxBitrateKey = "playback.maxBitrateKbps"
    static let skipSecondsKey = "playback.skipSeconds"
    static let subtitleSizeKey = "playback.subtitleSize"
    static let subtitleLookKey = "playback.subtitleLook"
    static let defaultBitrate = 1_000_000
    static let defaultSkip = 10
    static let defaultSubtitleSize = 44

    static var engine: PlaybackEngine {
        UserDefaults.standard.string(forKey: engineKey).flatMap(PlaybackEngine.init(rawValue:)) ?? .mpv
    }
    static var fastProfile: Bool { UserDefaults.standard.bool(forKey: fastProfileKey) }
    static var forceTranscode: Bool { UserDefaults.standard.bool(forKey: forceTranscodeKey) }
    static var maxBitrateKbps: Int {
        let v = UserDefaults.standard.integer(forKey: maxBitrateKey)
        return v == 0 ? defaultBitrate : v
    }

    /// Left / Right in the player.
    static var skipSeconds: Double {
        let v = UserDefaults.standard.integer(forKey: skipSecondsKey)
        return Double(v == 0 ? defaultSkip : v)
    }
    /// Text subtitles (styled ASS and picture subtitles keep their own size).
    static var subtitleSize: Int {
        let v = UserDefaults.standard.integer(forKey: subtitleSizeKey)
        return v == 0 ? defaultSubtitleSize : v
    }

    static var subtitleLook: SubtitleLook {
        get { UserDefaults.standard.string(forKey: subtitleLookKey).flatMap(SubtitleLook.init(rawValue:)) ?? .original }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: subtitleLookKey) }
    }

    static let subtitleSizes: [(title: String, size: Int)] = [
        ("صغير", 36), ("متوسط", 44), ("كبير", 54), ("كبير جدًا", 66),
    ]

    static let bitrateOptions: [(title: String, kbps: Int)] = [
        ("الأصلية (بدون حد)", 1_000_000),
        ("4K — 40 ميغابت", 40_000),
        ("1080p — 20 ميغابت", 20_000),
        ("1080p — 10 ميغابت", 10_000),
        ("720p — 4 ميغابت", 4_000),
    ]
}

extension Notification.Name {
    static let plexPlaybackDidEnd = Notification.Name("plexPlaybackDidEnd")
    /// Reload screens from the server (connection changed, or «تحديث المكتبة»).
    static let libraryShouldRefresh = Notification.Name("libraryShouldRefresh")
}
