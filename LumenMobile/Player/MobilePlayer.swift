import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Full-screen MPV player for iPhone: landscape, tap to show controls, double-tap a side to
/// jump 10 s, slider to scrub, audio / subtitle menu.
final class MobilePlayerViewController: UIViewController {
    let session: PlayerSession
    private let metalLayer: MPVMetalLayer
    private let hdr: Bool
    private var overlayHost: UIHostingController<MobilePlayerControls>!

    var onDismiss: (() -> Void)?

    init(session: PlayerSession, metalLayer: MPVMetalLayer, hdr: Bool) {
        self.session = session
        self.metalLayer = metalLayer
        self.hdr = hdr
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        metalLayer.frame = view.bounds
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        if hdr { metalLayer.wantsExtendedDynamicRangeContent = true }
        view.layer.addSublayer(metalLayer)

        let controls = MobilePlayerControls(session: session) { [weak self] in self?.close() }
        overlayHost = UIHostingController(rootView: controls)
        overlayHost.view.backgroundColor = .clear
        addChild(overlayHost)
        overlayHost.view.frame = view.bounds
        overlayHost.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlayHost.view)
        overlayHost.didMove(toParent: self)

        session.onRequestClose = { [weak self] in self?.close() }

        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = view.bounds
        CATransaction.commit()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfSupportedInterfaceOrientations()
        view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            let callback = onDismiss
            onDismiss = nil
            callback?()
        }
    }

    @objc private func didEnterBackground() {
        session.player.isPaused = true
    }

    private func close() {
        guard presentingViewController != nil, !isBeingDismissed else { return }
        dismiss(animated: true)
    }
}

// MARK: - Controls

struct MobilePlayerControls: View {
    let session: PlayerSession
    let onClose: () -> Void

    var body: some View {
        ZStack {
            // Tap: show / hide controls. Double-tap a side: ±10 s.
            HStack(spacing: 0) {
                tapZone(seek: -10)
                tapZone(seek: 10)
            }
            .environment(\.layoutDirection, .leftToRight)

            if session.isBuffering && session.errorMessage == nil {
                ProgressView().controlSize(.large).tint(.white)
            }

            if let error = session.errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                    Text(error).multilineTextAlignment(.center)
                    Button("إغلاق", action: onClose).buttonStyle(.borderedProminent)
                }
                .padding(28)
                .background(RoundedRectangle(cornerRadius: 20).fill(.black.opacity(0.85)))
            } else if session.controlsVisible || session.scrubPosition != nil {
                controls.transition(.opacity)
            }

            if let notice = session.notice {
                Label(notice, systemImage: "forward.end.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 24)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            if let skip = session.skipAction, session.errorMessage == nil {
                Button { session.performSkip() } label: {
                    Label(skip.title, systemImage: skip.icon)
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(.white))
                        .foregroundStyle(.black)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 40)
                .padding(.bottom, session.controlsVisible ? 90 : 30)
            }
        }
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.2), value: session.controlsVisible)
        .animation(.easeInOut(duration: 0.2), value: session.skipAction)
        .animation(.easeInOut(duration: 0.2), value: session.notice)
        .ignoresSafeArea()
    }

    private func tapZone(seek seconds: Double) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { session.seek(by: seconds) }
            .onTapGesture {
                if session.controlsVisible { session.hideControls() } else { session.showControls() }
            }
    }

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            VStack {
                HStack(alignment: .top, spacing: 16) {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title).font(.headline).lineLimit(1)
                        if let subtitle = session.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                        }
                        if !session.skipStatus.isEmpty {
                            Text(session.skipStatus).font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                    }
                    Spacer()
                    tracksMenu
                }
                .padding(.horizontal, 40)
                .padding(.top, 20)

                Spacer()

                HStack(spacing: 60) {
                    Button { session.seek(by: -10) } label: {
                        Image(systemName: "gobackward.10").font(.system(size: 34))
                    }
                    Button { session.togglePause() } label: {
                        Image(systemName: session.isPaused ? "play.fill" : "pause.fill").font(.system(size: 50))
                    }
                    Button { session.seek(by: 10) } label: {
                        Image(systemName: "goforward.10").font(.system(size: 34))
                    }
                }
                .environment(\.layoutDirection, .leftToRight)

                Spacer()

                timeline
                    .padding(.horizontal, 40)
                    .padding(.bottom, 24)
            }
        }
    }

    private var timeline: some View {
        let total = max(session.duration, 1)
        let current = session.scrubPosition ?? session.position
        return VStack(spacing: 6) {
            Slider(value: Binding(get: { min(current, total) },
                                  set: { session.scrubPosition = $0 }),
                   in: 0...total) { editing in
                if editing {
                    session.beginScrub()
                } else if let target = session.scrubPosition {
                    session.commitScrub(base: 0, delta: target)
                }
            }
            HStack {
                Text(Self.format(current))
                Spacer()
                Text("-" + Self.format(max(0, session.duration - current)))
            }
            .font(.caption.monospacedDigit())
        }
        .environment(\.layoutDirection, .leftToRight)
        .tint(Theme.accent)
    }

    private var tracksMenu: some View {
        Menu {
            Section("الصوت") {
                ForEach(session.audioTracks) { track in
                    Button { session.selectAudio(track) } label: {
                        if track.isSelected { Label(track.displayName, systemImage: "checkmark") } else { Text(track.displayName) }
                    }
                }
            }
            Section("الترجمة") {
                Button { session.selectSubtitle(nil) } label: {
                    if session.subtitleTracks.contains(where: \.isSelected) { Text("بدون ترجمة") } else { Label("بدون ترجمة", systemImage: "checkmark") }
                }
                ForEach(session.subtitleTracks) { track in
                    Button { session.selectSubtitle(track) } label: {
                        if track.isSelected { Label(track.displayName, systemImage: "checkmark") } else { Text(track.displayName) }
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble").font(.title3).frame(width: 44, height: 44)
        }
    }

    static func format(_ seconds: Double) -> String {
        ArabicFormat.clock(seconds: seconds)
    }
}

// MARK: - Playback manager

/// AVPlayerViewController that tells us when the user closes it.
final class SystemPlayerViewController: AVPlayerViewController {
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

/// Presents the player; progress and watched marks go to the active profile (never to Plex).
@MainActor
final class PlaybackManager {
    static let shared = PlaybackManager()

    private var continuation: CheckedContinuation<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    private init() {}

    /// Grows with every playback (any engine): a closing player leaves the audio session
    /// alone when another playback has started meanwhile.
    private(set) var playbackGeneration = 0

    var isPlaying: Bool { continuation != nil }

    /// Plays an item and returns once the player has been closed.
    func play(_ item: PlexItem, client: PlexServerClient, fromBeginning: Bool = false) async {
        guard continuation == nil else { return }
        playbackGeneration += 1
        let full = (try? await client.metadata(item.ratingKey)) ?? item

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        if PlaybackSettings.engine == .mpv {
            await playWithMPV(full, client: client, fromBeginning: fromBeginning)
        } else {
            await playWithSystemPlayer(full, client: client, fromBeginning: fromBeginning)
        }
    }

    private func playWithMPV(_ item: PlexItem, client: PlexServerClient, fromBeginning: Bool) async {
        guard let plan = client.playbackPlan(for: item, forceTranscode: PlaybackSettings.forceTranscode,
                                             maxBitrateKbps: PlaybackSettings.maxBitrateKbps, nativeEngine: true),
              let presenter = Self.topViewController()
        else { return }

        let layer = MPVMetalLayer()
        var config = MPVPlayer.Configuration()
        config.hdr = item.isHDR
        config.fastProfile = PlaybackSettings.fastProfile
        guard let mpv = MPVPlayer(layer: layer, configuration: config) else {
            await playWithSystemPlayer(item, client: client, fromBeginning: fromBeginning)
            return
        }

        let session = PlayerSession(item: item, client: client, player: mpv)
        let vc = MobilePlayerViewController(session: session, metalLayer: layer, hdr: item.isHDR)
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

    private func playWithSystemPlayer(_ item: PlexItem, client: PlexServerClient, fromBeginning: Bool) async {
        guard let plan = client.playbackPlan(for: item, forceTranscode: PlaybackSettings.forceTranscode,
                                             maxBitrateKbps: PlaybackSettings.maxBitrateKbps),
              let presenter = Self.topViewController()
        else { return }

        let store = ProfileStore.shared
        let playerItem = AVPlayerItem(url: plan.url)
        let player = AVPlayer(playerItem: playerItem)
        let sessionID = plan.sessionID
        let durationMs = item.duration ?? 0

        let start = fromBeginning ? 0 : Double(item.viewOffset ?? 0) / 1000
        if start > 5 { _ = await player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }

        // Every 10 s: save for the profile, then the playback timeline Plex needs.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { time in
            let seconds = time.seconds
            guard seconds.isFinite, seconds > 10 else { return }
            MainActor.assumeIsolated {
                store.recordProgress(item.mediaInfo, offsetMs: Int(seconds * 1000), durationMs: durationMs)
            }
            Task {
                await client.reportTimeline(item: item, state: "playing", timeMs: Int(seconds * 1000),
                                            durationMs: durationMs, sessionID: sessionID)
            }
        }

        let vc = SystemPlayerViewController()
        vc.player = player
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: playerItem, queue: .main) { [weak vc] _ in
            vc?.dismiss(animated: true)
        }
        vc.onDismiss = { [weak self] in
            Task { @MainActor in
                player.pause()
                let seconds = player.currentTime().seconds
                if seconds.isFinite {
                    if durationMs > 0, seconds * 1000 / Double(durationMs) > 0.9 {
                        store.setWatched([item.mediaInfo], watched: true)
                    } else if seconds > 10 {
                        store.recordProgress(item.mediaInfo, offsetMs: Int(seconds * 1000), durationMs: durationMs)
                    }
                    await client.reportTimeline(item: item, state: "stopped", timeMs: Int(seconds * 1000),
                                                durationMs: durationMs, sessionID: sessionID)
                }
                store.flush()
                if plan.isTranscode { await client.stopTranscode(sessionID: sessionID) }
                if let observer = self?.timeObserver { player.removeTimeObserver(observer) }
                if let observer = self?.endObserver { NotificationCenter.default.removeObserver(observer) }
                self?.timeObserver = nil
                self?.endObserver = nil
                NotificationCenter.default.post(name: .plexPlaybackDidEnd, object: nil)
                self?.continuation?.resume()
                self?.continuation = nil
            }
        }
        presenter.present(vc, animated: true) { player.play() }
        await withCheckedContinuation { self.continuation = $0 }
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
