import AVFoundation
import Foundation
import Observation
import os

/// State + logic for one MPV playback, shared by the view controller (input) and the SwiftUI overlay.
@MainActor
@Observable
final class PlayerSession {
    enum SkipAction: Equatable {
        case recap(endSeconds: Double)
        case intro(endSeconds: Double)
        case credits(hasNext: Bool)

        var title: String {
            switch self {
            case .recap: return "تخطي الملخّص"
            case .intro: return "تخطي المقدمة"
            case .credits(let hasNext): return hasNext ? "الحلقة التالية" : "تخطي الختام"
            }
        }
        var icon: String {
            switch self {
            case .recap, .intro: return "forward.end.fill"
            case .credits(let hasNext): return hasNext ? "forward.end.alt.fill" : "forward.end.fill"
            }
        }
    }

    // Item info
    private(set) var item: PlexItem
    let client: PlexServerClient
    private(set) var nextEpisode: PlexItem?

    // Playback state
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPaused = false
    private(set) var isBuffering = true
    private(set) var audioTracks: [MPVTrack] = []
    private(set) var subtitleTracks: [MPVTrack] = []
    private(set) var errorMessage: String?

    // UI state
    var controlsVisible = true {
        didSet { if controlsVisible != oldValue { player.setSubtitleLifted(controlsVisible) } }
    }

    /// The four buttons under the info (Down shows them) and the panel one of them opened.
    enum Panel: String, CaseIterable, Identifiable {
        case episodes, subtitles, audio, quality
        var id: String { rawValue }
    }
    var buttonsActive = false
    var panel: Panel? {
        didSet {
            if let panel { lastPanel = panel }
            // However it closed (a choice too), the focus needs a place.
            if panel != oldValue { onRefocus?() }
        }
    }
    /// The buttons on screen, in order.
    var buttonPanels: [Panel] { Panel.allCases.filter { $0 != .episodes || item.isEpisode } }
    /// The button the remote is on while `buttonsActive` (not a system focus: on tvOS 27.3
    /// beta it didn't reach the buttons).
    var selectedButton: Panel = .subtitles

    func moveButton(by step: Int) {
        let list = buttonPanels
        let index = list.firstIndex(of: selectedButton) ?? 0
        selectedButton = list[min(max(0, index + step), list.count - 1)]
    }
    /// The button focus returns to when its panel closes.
    private(set) var lastPanel: Panel?
    /// Buttons or a panel have the remote: the video's own controls (±10, scrub) wait.
    var isPanelOpen: Bool { buttonsActive || panel != nil }
    /// The player screen asks for the focus again (a panel or the buttons closed): otherwise
    /// it's left nowhere and the next Menu press dismisses the whole player.
    @ObservationIgnored var onRefocus: (() -> Void)?

    /// Menu / Back while the buttons or a panel have the remote: one step back.
    func stepBack() {
        if panel != nil {
            panel = nil
        } else if buttonsActive {
            buttonsActive = false
            showControls()
        }
        onRefocus?()
    }

    /// The current episode's season (episodes panel), and the episode before it (remote ⏮).
    private(set) var seasonEpisodes: [PlexItem] = []
    private(set) var previousEpisode: PlexItem?
    private(set) var quality: PlaybackQuality = .original
    /// Plex transcode running for this player (stopped when it changes or the player closes).
    var transcodeSessionID: String?
    var scrubPosition: Double?
    private(set) var skipAction: SkipAction? {
        didSet { if skipAction != oldValue { skipDeferred = false } }
    }
    /// Down from the skip button: it stays on screen but the click is the video's again.
    var skipDeferred = false
    /// Intro / recap / credits: Plex markers, else chapter names (from Plex, then from the file via mpv).
    private(set) var segments: [SkipSegment] = []
    // Sources, best first: Plex markers, IntroDB / TheIntroDB, chapters mpv reads from the file,
    // chapters Plex reports.
    private var markerSegments: [SkipSegment] = []
    private var onlineSegments: [SkipSegment] = []
    private var fileChapterSegments: [SkipSegment] = []
    private var plexChapterSegments: [SkipSegment] = []
    /// Short message shown for a moment (e.g. after the intro was skipped automatically).
    private(set) var notice: String?
    private var noticeTask: Task<Void, Never>?

    /// Where intro data for this episode comes from (shown under the title in the player).
    var skipStatus: String {
        guard let intro = segments.first(where: { $0.kind == .intro }) else {
            return item.isEpisode ? "لا توجد علامات مقدمة لهذه الحلقة" : ""
        }
        let range = "\(Self.clock(intro.startSeconds))–\(Self.clock(intro.endSeconds))"
        let source: String
        switch intro.source {
        case .plexMarker: source = "المقدمة: من Plex"
        case .online: source = "المقدمة: من قاعدة بيانات المقدمات"
        case .chapter: source = "المقدمة: من فصول الملف"
        }
        return source + ArabicFormat.separator + "\u{2066}\(range)\u{2069}"
    }

    private static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return ArabicFormat.digits(String(format: "%d:%02d", s / 60, s % 60))
    }

    private func show(notice text: String) {
        noticeTask?.cancel()
        notice = text
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// Where a play / skip command came from.
    enum CommandSource: String { case press = "UIPress", remote = "MPRemoteCommand" }
    private enum CommandKind: String { case playPause, skip }
    private static let log = Logger(subsystem: "com.fahad00x.lumen", category: "remote")
    @ObservationIgnored private var lastAccepted: [CommandKind: (source: CommandSource, time: TimeInterval)] = [:]
    @ObservationIgnored private lazy var nowPlaying = NowPlayingController(session: self)
    private let generation = PlaybackManager.shared.playbackGeneration

    /// Asks the hosting view controller to close the player.
    var onRequestClose: (() -> Void)?

    let player: MPVPlayer
    /// Progress, watched marks and track choices go to the active profile (never to Plex).
    private let store = ProfileStore.shared
    private var sessionID = UUID().uuidString
    private var lastReport = Date.distantPast
    private var autoSkippedIntroFor: String?
    private var hideTask: Task<Void, Never>?
    private var isSwitching = false
    private var finished = false

    init(item: PlexItem, client: PlexServerClient, player: MPVPlayer) {
        self.item = item
        self.client = client
        self.player = player
        markerSegments = item.markerSegments
        plexChapterSegments = item.plexChapterSegments
        rebuildSegments()
        player.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    var title: String { item.isEpisode ? (item.grandparentTitle ?? item.title) : item.title }
    /// "الموسم ١  •  الحلقة ١ — <title>" for an episode, the year for a movie.
    var subtitle: String? { item.isEpisode ? item.cardSubtitle : item.year.map { ArabicFormat.digits($0) } }

    // MARK: Start / stop

    func start(url: URL, fromBeginning: Bool) {
        let resume = fromBeginning ? 0 : Double(item.viewOffset ?? 0) / 1000
        player.load(url, start: resume > 5 ? resume : 0)
        player.setSubtitleLifted(controlsVisible)
        if item.duration.map({ $0 > 0 }) == true { duration = Double(item.duration!) / 1000 }
        if resume > 5 { position = resume }
        nowPlaying.start()
        loadEpisodes(for: item)
        loadOnlineSegments(for: item)
        scheduleHide()
    }

    /// Reports the final position, marks watched when appropriate, and tears down mpv.
    func finish() async {
        guard !finished else { return }
        finished = true
        hideTask?.cancel()
        nowPlaying.stop()
        let pos = player.position > 0 ? player.position : position
        let generation = self.generation
        // Not awaited: closing never waits for mpv. The audio session is released once mpv
        // is gone, unless another playback started in the meantime.
        player.shutdown {
            guard PlaybackManager.shared.playbackGeneration == generation else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                Self.log.error("audio session release failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        await reportStopped(item: item, positionSeconds: pos)
        if let transcode = transcodeSessionID {
            transcodeSessionID = nil
            await client.stopTranscode(sessionID: transcode)
        }
    }

    private func reportStopped(item: PlexItem, positionSeconds: Double) async {
        let durationMs = item.duration ?? Int(duration * 1000)
        // Saved for the profile first, so it's kept even if the server can't be reached.
        let credits = (item.ratingKey == self.item.ratingKey ? segments : item.skipSegments)
            .first { $0.kind == .credits }.map(\.startSeconds)
        let watchedThreshold = credits ?? (Double(durationMs) / 1000 * 0.9)
        if durationMs > 0, positionSeconds >= watchedThreshold - 1 {
            store.setWatched([item.mediaInfo], watched: true)
        } else if positionSeconds > 10 {
            store.recordProgress(item.mediaInfo, offsetMs: Int(positionSeconds * 1000), durationMs: durationMs)
        }
        store.flush()
        await client.reportTimeline(item: item, state: "stopped", timeMs: Int(positionSeconds * 1000),
                                    durationMs: durationMs, sessionID: sessionID)
    }

    // MARK: Controls

    func togglePause() {
        player.isPaused.toggle()
        showControls()
    }

    private var canControl: Bool { !finished && errorMessage == nil }

    /// Siri Remote presses can arrive twice: as a UIPress and as a system command. The second
    /// one, from the other source within 0.3 s, is dropped; quick presses from one source all count.
    private func accept(_ kind: CommandKind, _ detail: String, from source: CommandSource) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let last = lastAccepted[kind]
        let duplicate = last.map { $0.source != source && now - $0.time < 0.3 } ?? false
        if !duplicate { lastAccepted[kind] = (source, now) }
        Self.log.debug("\(detail, privacy: .public) from \(source.rawValue, privacy: .public)\(duplicate ? " (duplicate)" : "", privacy: .public)")
        return !duplicate
    }

    /// Returns false when the player can't take the command.
    @discardableResult
    func togglePause(from source: CommandSource) -> Bool {
        guard canControl else { return false }
        if accept(.playPause, "toggle", from: source) { togglePause() }
        return true
    }

    /// Play / pause to an exact state (repeating it changes nothing).
    @discardableResult
    func setPaused(_ paused: Bool, from source: CommandSource) -> Bool {
        guard canControl else { return false }
        if accept(.playPause, paused ? "pause" : "play", from: source) {
            player.isPaused = paused
            showControls()
        }
        return true
    }

    @discardableResult
    func skip(by seconds: Double, from source: CommandSource) -> Bool {
        guard canControl, duration > 0 else { return false }
        if accept(.skip, seconds > 0 ? "+10" : "-10", from: source) { seek(by: seconds) }
        return true
    }

    /// Scrubber of the Now Playing card.
    @discardableResult
    func jump(to seconds: Double, from source: CommandSource) -> Bool {
        guard canControl, duration > 0, seconds.isFinite else { return false }
        seek(to: min(max(0, seconds), max(0, duration - 1)))
        return true
    }

    func seek(by seconds: Double) {
        // Unknown duration: clamping would jump back to the start.
        guard duration > 0 else { return }
        let target = min(max(0, position + seconds), max(0, duration - 1))
        position = target
        player.seek(to: target)
        nowPlaying.update()
        showControls()
    }

    func seek(to seconds: Double) {
        position = seconds
        player.seek(to: seconds)
        nowPlaying.update()
        showControls()
    }

    func beginScrub() {
        scrubPosition = position
        showControls(autoHide: false)
    }

    /// Moves the scrub by `delta` seconds from where it is (not from where it began).
    func moveScrub(by delta: Double) {
        guard let current = scrubPosition else { return }
        scrubPosition = min(max(0, current + delta), max(0, duration - 1))
    }

    func commitScrub() {
        guard let target = scrubPosition else { return }
        scrubPosition = nil
        seek(to: target)
    }

    /// Ends at a given position (the iPhone's slider).
    func commitScrub(to target: Double) {
        scrubPosition = nil
        seek(to: min(max(0, target), max(0, duration - 1)))
    }

    func cancelScrub() { scrubPosition = nil; scheduleHide() }

    func performSkip() {
        guard let action = skipAction else { return }
        switch action {
        case .recap(let end), .intro(let end):
            seek(to: end)
        case .credits(let hasNext):
            if hasNext { Task { await playNext() } } else { onRequestClose?() }
        }
        skipAction = nil
    }

    /// Chosen from the track panel: applied now and remembered for this profile
    /// (for this file, and as its preferred language).
    func selectAudio(_ track: MPVTrack) {
        player.selectAudio(track.id)
        refreshTracks()
        let stream = item.audioStreams.first { $0.index != nil && $0.index == track.ffIndex }
        store.chooseAudio(item.mediaInfo, streamID: stream?.id, language: stream?.languageCode ?? track.language)
    }

    /// iPhone / iPad: text subtitles under the picture: applied now and for every file after.
    private(set) var subtitlesBelow = PlaybackSettings.subtitlesBelow
    func setSubtitlesBelow(_ below: Bool) {
        subtitlesBelow = below
        PlaybackSettings.subtitlesBelow = below
        player.setSubtitlesBelow(below)
    }

    /// Look of styled subtitles: applied now and for every file after.
    private(set) var subtitleLook = PlaybackSettings.subtitleLook
    func setSubtitleLook(_ look: SubtitleLook) {
        subtitleLook = look
        PlaybackSettings.subtitleLook = look
        player.setSubtitleLook(look)
    }

    func selectSubtitle(_ track: MPVTrack?) {
        player.selectSubtitle(track?.id)
        refreshTracks()
        guard let track else {
            store.chooseSubtitle(item.mediaInfo, streamID: nil, language: nil)
            return
        }
        let stream: PlexStream?
        if track.isExternal {
            stream = item.subtitleStreams.first { s in
                s.key != nil && (s.title ?? s.displayTitle) == track.title
                    && StreamPreference.sameLanguage(s.languageCode, track.language)
            } ?? item.subtitleStreams.first { $0.key != nil && StreamPreference.sameLanguage($0.languageCode, track.language) }
        } else {
            stream = item.subtitleStreams.first { $0.key == nil && $0.index != nil && $0.index == track.ffIndex }
        }
        store.chooseSubtitle(item.mediaInfo, streamID: stream?.id, language: stream?.languageCode ?? track.language)
    }

    func showControls(autoHide: Bool = true) {
        controlsVisible = true
        if autoHide { scheduleHide() } else { hideTask?.cancel() }
    }

    func hideControls() {
        hideTask?.cancel()
        controlsVisible = false
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, !self.isPaused, !self.isPanelOpen, self.scrubPosition == nil else { return }
            self.controlsVisible = false
        }
    }

    // MARK: Next episode

    func playNext() async {
        guard let next = nextEpisode else { onRequestClose?(); return }
        await play(episode: next)
    }

    func playPrevious() async {
        guard let previous = previousEpisode else { return }
        await play(episode: previous)
    }

    /// Another episode without leaving the player (next, previous, or the episodes panel).
    func play(episode next: PlexItem) async {
        guard !isSwitching, next.ratingKey != item.ratingKey else { return }
        isSwitching = true
        defer { isSwitching = false }

        let previous = item
        let previousPosition = position
        Task { await reportStopped(item: previous, positionSeconds: max(previousPosition, Double(previous.duration ?? 0) / 1000)) }

        let detailed = (try? await client.metadata(next.ratingKey)) ?? next
        guard let plan = plan(for: detailed, quality: quality) else {
            onRequestClose?()
            return
        }
        replaceTranscode(with: plan)
        item = detailed
        markerSegments = detailed.markerSegments
        plexChapterSegments = detailed.plexChapterSegments
        onlineSegments = []
        fileChapterSegments = []
        rebuildSegments()
        loadOnlineSegments(for: detailed)
        sessionID = UUID().uuidString
        position = 0
        duration = Double(detailed.duration ?? 0) / 1000
        isBuffering = true
        skipAction = nil
        nextEpisode = nil
        audioTracks = []
        subtitleTracks = []
        player.load(plan.url, start: 0)
        nowPlaying.itemChanged()
        showControls()
        loadEpisodes(for: detailed)
    }

    // MARK: Quality

    /// Same position, new source: the original file or a Plex transcode capped at `quality`.
    func setQuality(_ quality: PlaybackQuality) {
        guard quality != self.quality, let plan = plan(for: item, quality: quality) else { return }
        let resumeAt = max(player.position, position)
        self.quality = quality
        replaceTranscode(with: plan)
        isBuffering = true
        audioTracks = []
        subtitleTracks = []
        player.load(plan.url, start: resumeAt)
        position = resumeAt
        nowPlaying.update()
    }

    private func plan(for item: PlexItem, quality: PlaybackQuality) -> PlaybackPlan? {
        client.playbackPlan(for: item,
                            forceTranscode: quality != .original || PlaybackSettings.forceTranscode,
                            maxBitrateKbps: quality.maxBitrateKbps ?? PlaybackSettings.maxBitrateKbps,
                            nativeEngine: true,
                            resolution: quality.resolution)
    }

    /// The previous transcode (if any) is stopped on the server once the new source is chosen.
    private func replaceTranscode(with plan: PlaybackPlan) {
        if let old = transcodeSessionID { Task { await client.stopTranscode(sessionID: old) } }
        transcodeSessionID = plan.isTranscode ? plan.sessionID : nil
    }

    // MARK: Episodes

    /// The season of `episode` and its neighbours across the whole show.
    private func loadEpisodes(for episode: PlexItem) {
        guard episode.isEpisode, let show = episode.grandparentRatingKey else {
            seasonEpisodes = []
            previousEpisode = nil
            nextEpisode = nil
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let all = await client.allLeaves(show)
            guard item.ratingKey == episode.ratingKey else { return }
            seasonEpisodes = all.filter { $0.parentIndex == episode.parentIndex }
            if let i = all.firstIndex(where: { $0.ratingKey == episode.ratingKey }) {
                previousEpisode = i > 0 ? all[i - 1] : nil
                nextEpisode = i + 1 < all.count ? all[i + 1] : nil
            }
            nowPlaying.update()
        }
    }

    // MARK: mpv events

    private func handle(_ event: MPVPlayer.Event) {
        switch event {
        case .property(let name, let value):
            switch name {
            case "time-pos":
                if let v = value as? Double { position = v; tick() }
            case "duration":
                if let v = value as? Double, v > 0, abs(v - duration) > 0.5 {
                    duration = v
                    nowPlaying.update()
                }
            case "pause":
                isPaused = (value as? Bool) ?? false
                nowPlaying.update()
                if isPaused { showControls(autoHide: false) } else { scheduleHide() }
                Task { await report(force: true) }
            case "paused-for-cache":
                isBuffering = (value as? Bool) ?? false
                nowPlaying.update()
            case "track-list/count", "aid", "sid":
                refreshTracks()
            default:
                break
            }
        case .fileLoaded:
            isBuffering = false
            errorMessage = nil
            nowPlaying.update()
            addExternalSubtitles()
            applyPreferredStreams()
            refreshTracks()
            addChapterSegments()
        case .endFile(let reachedEOF, let error):
            if let error {
                errorMessage = "تعذّر تشغيل الملف: \(error)"
                nowPlaying.update()
                showControls(autoHide: false)
            } else if reachedEOF {
                if nextEpisode != nil && UserDefaults.standard.object(forKey: PlaybackSettings.autoPlayNextKey) as? Bool ?? true {
                    Task { await playNext() }
                } else {
                    position = duration
                    onRequestClose?()
                }
            }
        }
    }

    private func tick() {
        updateSkipAction()
        Task { await report(force: false) }
    }

    /// Chapters mpv reads straight from the file fill in what Plex doesn't know about.
    private func addChapterSegments() {
        let fromFile = SkipSegmentFinder.segments(fromChapters: player.chapters(),
                                                  durationMs: Int(max(duration, player.duration) * 1000))
        fileChapterSegments = fromFile
        rebuildSegments()
    }

    private func rebuildSegments() {
        let chapters = SkipSegmentFinder.merge(fileChapterSegments, plexChapterSegments)
        segments = SkipSegmentFinder.merge(markerSegments, SkipSegmentFinder.merge(onlineSegments, chapters))
    }

    /// Community intro databases (what Infuse uses when the server has no markers).
    private func loadOnlineSegments(for episode: PlexItem) {
        Task { [weak self] in
            guard let self else { return }
            var show: PlexItem?
            if episode.isEpisode, let key = episode.grandparentRatingKey {
                show = await client.cachedMetadata(key)
            }
            guard let query = OnlineSkipSegments.query(for: episode, show: show) else { return }
            let found = await OnlineSkipSegments.fetch(query)
            guard item.ratingKey == episode.ratingKey, !found.isEmpty else { return }
            onlineSegments = found
            rebuildSegments()
        }
    }

    private func updateSkipAction() {
        let ms = Int(position * 1000)
        let current = segments.first { segment in
            switch segment.kind {
            case .intro, .recap:
                // Chapters are sometimes set a few seconds after the song starts: show the button
                // 12 s early for them (pressing it still lands exactly at the end).
                let lead = segment.source == .chapter ? 12_000 : 0
                return ms >= segment.startMs - lead && ms < segment.endMs - 1000
            case .credits: return ms >= segment.startMs && ms < max(segment.endMs, segment.startMs + 1000)
            }
        }
        switch current?.kind {
        case .intro?:
            let end = current!.endSeconds
            let reachedStart = ms >= current!.startMs
            // Once per episode, so seeking back into the intro lets you watch it.
            // Auto-skip waits for the exact start, so nothing before the intro is cut.
            if reachedStart, UserDefaults.standard.bool(forKey: PlaybackSettings.autoSkipIntroKey),
               autoSkippedIntroFor != item.ratingKey {
                autoSkippedIntroFor = item.ratingKey
                seek(to: end)
                show(notice: "تم تخطي المقدمة")
                return
            }
            setSkipAction(.intro(endSeconds: end))
        case .recap?:
            setSkipAction(.recap(endSeconds: current!.endSeconds))
        case .credits?:
            setSkipAction(.credits(hasNext: nextEpisode != nil))
        case nil:
            setSkipAction(nil)
        }
    }

    /// Runs on every playhead tick: assigning an observed property notifies its views even when
    /// the value is the same, so the player's controls were rebuilt every frame (and quick taps
    /// on them got lost). Only a real change is assigned.
    private func setSkipAction(_ action: SkipAction?) {
        if action != skipAction { skipAction = action }
    }

    /// Every 10 s while playing, and on pause: saves the position for the profile, then
    /// sends Plex the playback timeline.
    private func report(force: Bool) async {
        guard !finished, force || Date().timeIntervalSince(lastReport) >= 10 else { return }
        lastReport = Date()
        if position > 10 {
            store.recordProgress(item.mediaInfo, offsetMs: Int(position * 1000),
                                 durationMs: item.duration ?? Int(duration * 1000))
        }
        await client.reportTimeline(item: item, state: isPaused ? "paused" : "playing",
                                    timeMs: Int(position * 1000),
                                    durationMs: item.duration ?? Int(duration * 1000),
                                    sessionID: sessionID)
    }

    private func refreshTracks() {
        let tracks = player.tracks()
        audioTracks = tracks.filter { $0.kind == .audio }
        subtitleTracks = tracks.filter { $0.kind == .sub }
    }

    /// Plex sidecar subtitles (.srt/.ass next to the file) aren't inside the container,
    /// so hand them to mpv explicitly.
    private var preferredStreams: StreamPreference.Choice {
        StreamPreference.resolve(for: item, state: store.state(for: item.ratingKey), profile: store.activeProfile)
    }

    /// Where a sidecar subtitle comes from (the iPhone: a downloaded copy); nil: the server.
    var sidecarURL: ((PlexStream) -> URL?)?

    private func addExternalSubtitles() {
        let chosen = preferredStreams.subtitle?.id
        let ratingKey = item.ratingKey
        for stream in item.subtitleStreams {
            // A downloaded copy can also carry the file's own subtitles as files of their own.
            guard let url = sidecarURL?(stream) ?? stream.key.flatMap({ client.url($0, includeToken: true) }) else { continue }
            let add = { [player] (source: URL) in
                player.addSubtitle(source, title: stream.title ?? stream.displayTitle, language: stream.languageCode,
                                   select: stream.id == chosen)
            }
            guard VisualOrderSubtitle.applies(to: stream) else { add(url); continue }
            // Arabic SRT: read it first, in case it is written for left-to-right players.
            Task { [weak self] in
                let source = await VisualOrderSubtitle.prepared(url, streamID: stream.id)
                guard let self, self.item.ratingKey == ratingKey else { return }
                add(source)
            }
        }
    }

    /// Applies the profile's tracks: its choice for this file (⋯ menu or track panel), else its
    /// preferred languages, else the file's defaults.
    private func applyPreferredStreams() {
        let choice = preferredStreams
        let tracks = player.tracks()
        if let audio = choice.audio, let index = audio.index,
           let track = tracks.first(where: { $0.kind == .audio && !$0.isExternal && $0.ffIndex == index }) {
            player.selectAudio(track.id)
        }
        if let sub = choice.subtitle {
            if sub.key == nil, let index = sub.index,
               let track = tracks.first(where: { $0.kind == .sub && !$0.isExternal && $0.ffIndex == index }) {
                player.selectSubtitle(track.id)
            }
        } else {
            player.selectSubtitle(nil)
        }
    }
}

/// Many Arabic SRT files are written for players that lay every line out left to right: the
/// punctuation at the end of a sentence is typed at its start («!مستقبل مشرق للجميع») and the
/// dialogue dash at its end («ماذا؟ -»). mpv lays Arabic lines out right to left, which flips that
/// punctuation to the wrong side. Such a file gets a left-to-right mark (U+200E) at the start of
/// each Arabic line, so it shows the way it was written. Correctly written files are left as they are.
enum VisualOrderSubtitle {
    private static let rtlLanguages: Set<String> = ["ar", "ara", "fa", "fas", "per", "he", "heb", "iw", "ur", "urd"]

    static func applies(to stream: PlexStream) -> Bool {
        guard let language = stream.languageCode?.lowercased(), rtlLanguages.contains(language) else { return false }
        let codec = stream.codec?.lowercased()
        return codec == "srt" || codec == "subrip"
    }

    /// A local copy with the marks when the file is written in visual order; else `url` itself.
    static func prepared(_ url: URL, streamID: Int) async -> URL {
        guard let data = try? await URLSession.shared.data(from: url).0,
              let text = decode(data), isVisualOrder(text) else { return url }
        let marked = text.components(separatedBy: "\n")
            .map { hasRTL($0) ? "\u{200E}" + $0 : $0 }
            .joined(separator: "\n")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subtitles", isDirectory: true)
        let file = folder.appendingPathComponent("\(streamID).srt")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(marked.utf8).write(to: file, options: .atomic)
            return file
        } catch {
            return url
        }
    }

    private static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        let arabic = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsArabic.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: arabic))
    }

    /// Arabic lines whose sentence punctuation sits at the start (or whose dash sits at the end)
    /// outnumber those written the usual way.
    static func isVisualOrder(_ text: String) -> Bool {
        let punctuation = Set(".!?,:;…\"")
        var visual = 0, logical = 0
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "<[^>]*>|\\{[^}]*\\}", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard hasRTL(line), let first = line.first, let last = line.last else { continue }
            if punctuation.contains(first) || line.hasSuffix(" -") { visual += 1 }
            if punctuation.contains(last) || line.hasPrefix("- ") { logical += 1 }
        }
        return visual >= 3 && visual > logical * 2
    }

    private static func hasRTL(_ line: String) -> Bool {
        line.unicodeScalars.contains { (0x0590...0x08FF).contains($0.value) || (0xFB1D...0xFEFC).contains($0.value) }
    }
}
