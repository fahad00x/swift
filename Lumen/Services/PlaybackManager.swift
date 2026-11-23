import AVFoundation
import AVKit
import UIKit

/// AVPlayerViewController that tells us when the user leaves playback (Menu / Back).
final class LumenPlayerViewController: AVPlayerViewController {
    var onDismiss: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            let callback = onDismiss
            onDismiss = nil
            callback?()
        }
    }
}

/// Presents the native tvOS player and keeps Plex in sync (resume position, watched state).
@MainActor
final class PlaybackManager {
    static let shared = PlaybackManager()

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var skipObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var continuation: CheckedContinuation<Void, Never>?
    private var current: (item: PlexItem, client: PlexServerClient, plan: PlaybackPlan)?

    private init() {}

    /// True while a player is on screen.
    var isPlaying: Bool { continuation != nil }

    /// Plays an item and returns once the player has been dismissed.
    func play(_ item: PlexItem, client: PlexServerClient, fromBeginning: Bool = false) async {
        guard continuation == nil else { return }

        // Always refresh: we need streams and intro/credits markers.
        let full = (try? await client.metadata(item.ratingKey)) ?? item

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        if PlaybackSettings.engine == .mpv {
            await playWithMPV(full, client: client, fromBeginning: fromBeginning)
        } else {
            await playWithSystemPlayer(full, client: client, fromBeginning: fromBeginning)
        }
    }

    // MARK: MPV engine (plays every format natively, 4K HDR, no server transcoding)

    private func playWithMPV(_ item: PlexItem, client: PlexServerClient, fromBeginning: Bool) async {
        guard let plan = client.playbackPlan(for: item,
                                             forceTranscode: PlaybackSettings.forceTranscode,
                                             maxBitrateKbps: PlaybackSettings.maxBitrateKbps,
                                             nativeEngine: true),
              let presenter = Self.topViewController()
        else { return }

        let layer = MPVMetalLayer()
        var config = MPVPlayer.Configuration()
        config.hdr = item.isHDR
        config.fastProfile = PlaybackSettings.fastProfile

        guard let mpv = MPVPlayer(layer: layer, configuration: config) else {
            // Fall back to the system player if mpv can't start.
            await playWithSystemPlayer(item, client: client, fromBeginning: fromBeginning)
            return
        }

        let session = PlayerSession(item: item, client: client, player: mpv)
        let vc = MPVPlayerViewController(session: session, metalLayer: layer,
                                         displayCriteria: DisplayCriteriaFactory.make(for: item))
        vc.onDismiss = { [weak self] in
            Task { @MainActor in
                await session.finish()
                if plan.isTranscode { await client.stopTranscode(sessionID: plan.sessionID) }
                NotificationCenter.default.post(name: .plexPlaybackDidEnd, object: nil)
                self?.continuation?.resume()
                self?.continuation = nil
            }
        }
        presenter.present(vc, animated: true) {
            session.start(url: plan.url, fromBeginning: fromBeginning)
        }
        await withCheckedContinuation { self.continuation = $0 }
    }

    // MARK: System player (AVPlayer; Plex converts unsupported formats)

    private func playWithSystemPlayer(_ full: PlexItem, client: PlexServerClient, fromBeginning: Bool) async {
        guard let plan = client.playbackPlan(for: full,
                                             forceTranscode: PlaybackSettings.forceTranscode,
                                             maxBitrateKbps: PlaybackSettings.maxBitrateKbps),
              let presenter = Self.topViewController()
        else { return }

        let playerItem = AVPlayerItem(url: plan.url)
        playerItem.externalMetadata = await Self.metadata(for: full, client: client)
        let player = AVPlayer(playerItem: playerItem)
        self.player = player
        current = (full, client, plan)

        let startSeconds = fromBeginning ? 0 : Double(full.viewOffset ?? 0) / 1000
        if startSeconds > 5 {
            let target = CMTime(seconds: startSeconds, preferredTimescale: 600)
            statusObservation = playerItem.observe(\.status, options: [.new]) { item, _ in
                guard item.status == .readyToPlay else { return }
                item.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
                Task { @MainActor in PlaybackManager.shared.statusObservation = nil }
            }
        }

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { _ in
            Task { @MainActor in await PlaybackManager.shared.report(state: "playing") }
        }

        let vc = LumenPlayerViewController()
        vc.player = player
        skipObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak vc, weak player] time in
            MainActor.assumeIsolated {
                guard let vc, let player else { return }
                PlaybackManager.updateSkipActions(vc: vc, player: player, item: full, seconds: time.seconds)
            }
        }
        vc.onDismiss = { [weak self] in
            Task { @MainActor in await self?.finish() }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: playerItem, queue: .main) { [weak vc] _ in
            vc?.dismiss(animated: true)
        }

        presenter.present(vc, animated: true) { player.play() }

        await withCheckedContinuation { self.continuation = $0 }
    }

    private func report(state: String) async {
        guard let current, let player else { return }
        let time = player.currentTime().seconds
        guard time.isFinite else { return }
        let duration = current.item.duration ?? Int((player.currentItem?.duration.seconds ?? 0) * 1000)
        if time > 10 {
            ProfileStore.shared.recordProgress(current.item.mediaInfo, offsetMs: Int(time * 1000), durationMs: duration)
        }
        await current.client.reportTimeline(item: current.item, state: state,
                                            timeMs: Int(time * 1000), durationMs: duration,
                                            sessionID: current.plan.sessionID)
    }

    private func finish() async {
        guard let current, let player else { return }
        player.pause()
        await report(state: "stopped")

        // Watched mark for the active profile only (Plex is never told).
        let position = player.currentTime().seconds * 1000
        if let duration = current.item.duration, duration > 0, position / Double(duration) > 0.9 {
            ProfileStore.shared.setWatched([current.item.mediaInfo], watched: true)
        }
        ProfileStore.shared.flush()
        if current.plan.isTranscode {
            await current.client.stopTranscode(sessionID: current.plan.sessionID)
        }

        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let skipObserver { player.removeTimeObserver(skipObserver) }
        skipObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        statusObservation = nil
        self.player = nil
        self.current = nil

        NotificationCenter.default.post(name: .plexPlaybackDidEnd, object: nil)
        continuation?.resume()
        continuation = nil
    }

    /// Native tvOS "Skip Intro"-style button for AVPlayerViewController.
    private static func updateSkipActions(vc: AVPlayerViewController, player: AVPlayer, item: PlexItem, seconds: Double) {
        let ms = Int(seconds * 1000)
        var action: UIAction?
        let segments = item.skipSegments
        if let intro = segments.first(where: { $0.kind != .credits && ms >= $0.startMs && ms < $0.endMs - 1000 }) {
            let title = intro.kind == .recap ? "تخطي الملخّص" : "تخطي المقدمة"
            action = UIAction(title: title, image: UIImage(systemName: "forward.end.fill")) { [weak player] _ in
                player?.seek(to: CMTime(seconds: intro.endSeconds, preferredTimescale: 600))
            }
        } else if let credits = segments.first(where: { $0.kind == .credits }), ms >= credits.startMs, ms < credits.endMs {
            action = UIAction(title: "تخطي الختام", image: UIImage(systemName: "forward.end.fill")) { [weak vc] _ in
                vc?.dismiss(animated: true)
            }
        }
        let current = vc.contextualActions.first?.title
        if current != action?.title { vc.contextualActions = action.map { [$0] } ?? [] }
    }

    // MARK: Helpers

    private static func metadata(for item: PlexItem, client: PlexServerClient) async -> [AVMetadataItem] {
        func make(_ id: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol) -> AVMutableMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value
            m.extendedLanguageTag = "und"
            return m
        }
        var items: [AVMetadataItem] = []
        if item.isEpisode {
            items.append(make(.commonIdentifierTitle, (item.grandparentTitle ?? item.title) as NSString))
            items.append(make(.iTunesMetadataTrackSubTitle, (item.cardSubtitle ?? item.title) as NSString))
        } else {
            items.append(make(.commonIdentifierTitle, item.title as NSString))
            if let year = item.year { items.append(make(.iTunesMetadataTrackSubTitle, String(year) as NSString)) }
        }
        if let summary = item.summary, !summary.isEmpty {
            items.append(make(.commonIdentifierDescription, summary as NSString))
        }
        if let url = client.imageURL(item.posterPath, width: 400, height: 600),
           let image = await ImageLoader.shared.image(for: url),
           let data = image.jpegData(compressionQuality: 0.8) {
            let art = make(.commonIdentifierArtwork, data as NSData)
            art.dataType = kCMMetadataBaseDataType_JPEG as String
            items.append(art)
        }
        return items
    }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
