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

    /// The iPhone turns to landscape; the iPad stays as the user holds it (iPadOS ignores a forced
    /// orientation for apps that support multitasking), and the video fits that.
    private static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { Self.isPad ? .all : .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        Self.isPad ? (view.window?.windowScene?.interfaceOrientation ?? .landscapeRight) : .landscapeRight
    }
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
        // A sublayer's drawable keeps its first size; follow the view (rotation, Split View).
        let scale = metalLayer.contentsScale
        metalLayer.drawableSize = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        CATransaction.commit()
    }

    /// Turned (iPad), or a new window size: mpv draws at the new size once the turn is over.
    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.view.setNeedsLayout()
            self?.view.layoutIfNeeded()
            self?.session.player.refreshOutputSize()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !Self.isPad {
            setNeedsUpdateOfSupportedInterfaceOrientations()
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in }
        }
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

    /// «التقديم والترجيع» from Settings (5, 10, 15 or 30 s; each has its own symbol).
    private let skip = PlaybackSettings.skipSeconds
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// A finger sliding across the picture: where it started, to scrub from there.
    @State private var dragStart: Double?

    private var wide: Bool { Metrics(sizeClass).isWide }
    private var inset: CGFloat { wide ? 44 : 24 }

    var body: some View {
        ZStack {
            // Tap: show / hide controls (or close a panel). Double-tap a side: ±skip.
            // Slide across: scrub, like the Apple TV remote's surface.
            GeometryReader { geo in
                HStack(spacing: 0) {
                    tapZone(seek: -skip)
                    tapZone(seek: skip)
                }
                .environment(\.layoutDirection, .leftToRight)
                .gesture(scrubGesture(width: geo.size.width))
            }

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
            } else if session.controlsVisible || session.scrubPosition != nil || session.panel != nil {
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

            if let skipAction = session.skipAction, session.errorMessage == nil, session.panel == nil {
                Button { session.performSkip() } label: {
                    Label(skipAction.title, systemImage: skipAction.icon)
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(.white))
                        .foregroundStyle(.black)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, inset)
                .padding(.bottom, session.controlsVisible ? (wide ? 190 : 160) : 30)
            }

            if let panel = session.panel {
                panelView(panel)
                    // Over its buttons (the trailing end: the left in Arabic).
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: wide ? .bottomTrailing : .bottom)
                    .padding(.horizontal, wide ? inset : 12)
                    .padding(.bottom, wide ? 150 : 130)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.2), value: session.controlsVisible)
        .animation(.easeInOut(duration: 0.2), value: session.skipAction)
        .animation(.easeInOut(duration: 0.2), value: session.notice)
        .animation(.easeOut(duration: 0.18), value: session.panel)
        .ignoresSafeArea()
    }

    private func tapZone(seek seconds: Double) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { session.seek(by: seconds) }
            .onTapGesture {
                if session.panel != nil { session.panel = nil; return }
                if session.controlsVisible { session.hideControls() } else { session.showControls() }
            }
    }

    /// Sliding across the picture moves the playhead (the screen's width ≈ 10 minutes, or the
    /// whole file if it's shorter); lifting the finger jumps there.
    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard session.panel == nil, session.duration > 0,
                      abs(value.translation.width) > abs(value.translation.height) else { return }
                if dragStart == nil {
                    dragStart = session.position
                    session.beginScrub()
                }
                let span = min(session.duration, 600)
                let delta = Double(value.translation.width / max(width, 1)) * span
                session.scrubPosition = min(max(0, (dragStart ?? 0) + delta), max(0, session.duration - 1))
            }
            .onEnded { _ in
                defer { dragStart = nil }
                guard dragStart != nil, let target = session.scrubPosition else { return }
                session.commitScrub(to: target)
            }
    }

    // MARK: Controls

    private var controls: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.55), location: 0),
                .init(color: .clear, location: 0.22),
                .init(color: .clear, location: 0.55),
                .init(color: .black.opacity(0.7), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(.black.opacity(0.35)))
                    }
                    .accessibilityLabel("إغلاق")
                    Spacer()
                    if !session.skipStatus.isEmpty {
                        Text(session.skipStatus).font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                }
                .padding(.horizontal, inset)
                .padding(.top, wide ? 30 : 20)

                Spacer()

                // Each button sits on a dark circle, so it stays visible over a bright scene
                // (the gradient leaves the middle of the picture clear).
                HStack(spacing: wide ? 56 : 36) {
                    Button { session.seek(by: -skip) } label: {
                        Image(systemName: "gobackward.\(Int(skip))").font(.system(size: wide ? 34 : 28))
                            .centerControl(diameter: wide ? 76 : 64)
                    }
                    Button { session.togglePause() } label: {
                        Image(systemName: session.isPaused ? "play.fill" : "pause.fill").font(.system(size: wide ? 46 : 38))
                            .centerControl(diameter: wide ? 104 : 88)
                    }
                    Button { session.seek(by: skip) } label: {
                        Image(systemName: "goforward.\(Int(skip))").font(.system(size: wide ? 34 : 28))
                            .centerControl(diameter: wide ? 76 : 64)
                    }
                }
                .environment(\.layoutDirection, .leftToRight)

                Spacer()

                VStack(spacing: 14) {
                    HStack(alignment: .bottom, spacing: 20) {
                        info
                        Spacer(minLength: 12)
                        buttons
                    }
                    timeline
                }
                .padding(.horizontal, inset)
                .padding(.bottom, wide ? 34 : 22)
            }
        }
    }

    /// «S1 • E3 – عنوان الحلقة» small, the show big. A movie: its title and year.
    private var info: some View {
        let item = session.item
        return VStack(alignment: .leading, spacing: 4) {
            if item.isEpisode {
                Text(Self.episodeLine(item))
                    .font(wide ? .callout : .footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            Text(item.isEpisode ? (item.grandparentTitle ?? item.title) : item.title)
                .font(wide ? .title.weight(.bold) : .title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !item.isEpisode, let year = session.subtitle {
                Text(year).font(.footnote).foregroundStyle(.white.opacity(0.75))
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 8)
    }

    static func episodeLine(_ episode: PlexItem) -> String {
        var code: [String] = []
        if let season = episode.parentIndex { code.append("S\(season)") }
        if let number = episode.index { code.append("E\(number)") }
        let prefix = code.isEmpty ? "" : "\u{2068}" + code.joined(separator: " • ") + "\u{2069}"
        let title = episode.title.isEmpty ? "" : "\u{2068}\(episode.title)\u{2069}"
        return [prefix, title].filter { !$0.isEmpty }.joined(separator: " – ")
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: wide ? 14 : 10) {
            ForEach(session.buttonPanels) { panel in
                Button {
                    session.panel = session.panel == panel ? nil : panel
                    if session.panel == nil { session.showControls() }
                } label: {
                    Image(systemName: Self.icon(panel))
                        .font(.system(size: wide ? 20 : 17, weight: .semibold))
                        .frame(width: wide ? 50 : 42, height: wide ? 50 : 42)
                        .background(Circle().fill(.ultraThinMaterial))
                        .overlay(Circle().strokeBorder(Color.white.opacity(session.panel == panel ? 0.9 : 0.18),
                                                       lineWidth: session.panel == panel ? 1.5 : 1))
                        .environment(\.colorScheme, .dark)
                }
                .accessibilityLabel(Self.title(panel))
            }
        }
    }

    static func icon(_ panel: PlayerSession.Panel) -> String {
        switch panel {
        case .episodes: return "list.and.film"
        case .subtitles: return "captions.bubble"
        case .audio: return "waveform"
        case .quality: return "slider.horizontal.3"
        }
    }

    static func title(_ panel: PlayerSession.Panel) -> String {
        switch panel {
        case .episodes: return "الحلقات"
        case .subtitles: return "الترجمة"
        case .audio: return "الصوت"
        case .quality: return "الجودة"
        }
    }

    // MARK: Progress

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
                    session.commitScrub(to: target)
                }
            }
            HStack {
                Text(Self.format(current))
                Spacer()
                Text("-" + Self.format(max(0, session.duration - current)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
        }
        .environment(\.layoutDirection, .leftToRight)
        .tint(Theme.accent)
    }

    // MARK: Panels

    @ViewBuilder
    private func panelView(_ panel: PlayerSession.Panel) -> some View {
        PlayerPanelCard(title: Self.title(panel), wide: wide) {
            switch panel {
            case .episodes:
                ForEach(session.seasonEpisodes) { episode in
                    PlayerPanelRow(selected: episode.ratingKey == session.item.ratingKey) {
                        session.panel = nil
                        Task { await session.play(episode: episode) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.episodeLine(episode)).lineLimit(1)
                            if let duration = episode.duration {
                                Text(ArabicFormat.duration(ms: duration)).font(.caption).opacity(0.6)
                            }
                        }
                    }
                }
                if session.seasonEpisodes.isEmpty {
                    Text("جارٍ التحميل…").font(.callout).opacity(0.6).padding(12)
                }
            case .subtitles:
                ForEach(orderedSubtitles.preferred) { subtitleRow($0) }
                PlayerPanelRow(selected: !session.subtitleTracks.contains(where: \.isSelected)) {
                    session.selectSubtitle(nil)
                } label: { Text("بدون") }
                ForEach(orderedSubtitles.others) { subtitleRow($0) }
                // Only styled subtitles have a look of their own.
                if session.subtitleTracks.contains(where: { $0.isSelected && ["ass", "ssa"].contains($0.codec?.lowercased() ?? "") }) {
                    Text("الشكل")
                        .font(.footnote.weight(.semibold))
                        .opacity(0.6)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                    ForEach(SubtitleLook.allCases) { look in
                        PlayerPanelRow(selected: look == session.subtitleLook) {
                            session.setSubtitleLook(look)
                        } label: { Text(look.title) }
                    }
                }
                // In the black band under the picture (upright, or a film wider than the screen).
                Text("المكان")
                    .font(.footnote.weight(.semibold))
                    .opacity(0.6)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                PlayerPanelRow(selected: !session.subtitlesBelow) {
                    session.setSubtitlesBelow(false)
                } label: { Text("على الصورة") }
                PlayerPanelRow(selected: session.subtitlesBelow) {
                    session.setSubtitlesBelow(true)
                } label: { Text("تحت الصورة") }
            case .audio:
                ForEach(session.audioTracks) { track in
                    PlayerPanelRow(selected: track.isSelected) {
                        session.selectAudio(track)
                    } label: { Text(track.menuName).lineLimit(1) }
                }
            case .quality:
                ForEach(PlaybackQuality.allCases) { quality in
                    PlayerPanelRow(selected: quality == session.quality) {
                        session.setQuality(quality)
                        session.panel = nil
                    } label: { Text(quality.title) }
                }
            }
        }
    }

    private func subtitleRow(_ track: MPVTrack) -> some View {
        PlayerPanelRow(selected: track.isSelected) {
            session.selectSubtitle(track)
        } label: { Text(track.menuName).lineLimit(1) }
    }

    /// The profile's subtitle language first (Arabic by default), then «بدون», then the rest.
    private var orderedSubtitles: (preferred: [MPVTrack], others: [MPVTrack]) {
        let language = ProfileStore.shared.activeProfile?.preferredSubtitleLanguage ?? "ara"
        let tracks = session.subtitleTracks
        let preferred = tracks.filter { StreamPreference.sameLanguage($0.language, language) }
        return (preferred, tracks.filter { !preferred.contains($0) })
    }

    static func format(_ seconds: Double) -> String {
        ArabicFormat.clock(seconds: seconds)
    }
}

/// A panel over the picture: title, then its rows (scrolling when long).
private struct PlayerPanelCard<Content: View>: View {
    let title: String
    let wide: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) { content }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 10)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: wide ? 420 : .infinity, maxHeight: wide ? 460 : 340, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.35))
            RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
        // A tap inside never reaches the picture under it.
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {}
    }
}

/// A choice: a check for the chosen one.
private struct PlayerPanelRow<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .opacity(selected ? 1 : 0)
                label
                    .font(.callout.weight(selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(selected ? 0.12 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
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
        // Downloaded: the saved copy, with the profile's progress, without asking the server.
        if let file = Downloads.shared.localFile(item.ratingKey), let saved = Downloads.shared.entry(item.ratingKey) {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            await playWithMPV(saved.item.applying(client.userState), client: client, fromBeginning: fromBeginning, localFile: file)
            return
        }
        let full = (try? await client.metadata(item.ratingKey)) ?? item

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        if PlaybackSettings.engine == .mpv {
            await playWithMPV(full, client: client, fromBeginning: fromBeginning)
        } else {
            await playWithSystemPlayer(full, client: client, fromBeginning: fromBeginning)
        }
    }

    private func playWithMPV(_ item: PlexItem, client: PlexServerClient, fromBeginning: Bool, localFile: URL? = nil) async {
        let plan = localFile.map { PlaybackPlan(url: $0, isTranscode: false, sessionID: UUID().uuidString) }
            ?? client.playbackPlan(for: item, forceTranscode: PlaybackSettings.forceTranscode,
                                   maxBitrateKbps: PlaybackSettings.maxBitrateKbps, nativeEngine: true)
        guard let plan, let presenter = Self.topViewController() else { return }

        let layer = MPVMetalLayer()
        var config = MPVPlayer.Configuration()
        config.hdr = item.isHDR
        config.fastProfile = PlaybackSettings.fastProfile
        config.subtitleLook = PlaybackSettings.subtitleLook
        config.subtitleSize = PlaybackSettings.subtitleSize
        config.subtitlesBelow = PlaybackSettings.subtitlesBelow
        guard let mpv = MPVPlayer(layer: layer, configuration: config) else {
            await playWithSystemPlayer(item, client: client, fromBeginning: fromBeginning)
            return
        }

        let session = PlayerSession(item: item, client: client, player: mpv)
        if localFile != nil {
            let key = item.ratingKey
            session.sidecarURL = { stream in Downloads.shared.localSubtitle(key, stream: stream) }
        }
        // The session stops it on close, or when the quality panel replaces it.
        session.transcodeSessionID = plan.isTranscode ? plan.sessionID : nil
        let vc = MobilePlayerViewController(session: session, metalLayer: layer, hdr: item.isHDR)
        vc.onDismiss = { [weak self] in
            Task { @MainActor in
                await session.finish()
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

private extension View {
    /// A player button in the middle of the screen: a dark translucent circle behind the icon
    /// and a soft shadow, readable over bright and dark scenes alike.
    func centerControl(diameter: CGFloat) -> some View {
        frame(width: diameter, height: diameter)
            .background(Circle().fill(.black.opacity(0.4)))
            .contentShape(Circle())
            .shadow(color: .black.opacity(0.5), radius: 10)
    }
}
