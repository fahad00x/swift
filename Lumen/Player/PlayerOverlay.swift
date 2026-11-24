import SwiftUI

/// On-screen controls drawn over the video (Infuse layout, mirrored for Arabic): the info on
/// the reading side, four glass buttons on the other, a thin full-width progress bar under
/// them. Up shows the buttons; each opens its panel above it. Nothing sits at the top of
/// the screen, where styled (ASS) subtitles often place signs and titles.
struct PlayerOverlay: View {
    let session: PlayerSession

    var body: some View {
        ZStack {
            if session.isBuffering && session.errorMessage == nil {
                ProgressView().scaleEffect(1.6)
            }

            if let error = session.errorMessage {
                errorCard(error)
            } else {
                if session.controlsVisible || session.scrubPosition != nil || session.isPanelOpen {
                    PlayerChrome(session: session)
                        .transition(.opacity)
                }
                if let skip = session.skipAction, !session.isPanelOpen {
                    skipButton(skip)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: session.controlsVisible)
        .animation(.easeInOut(duration: 0.2), value: session.isPanelOpen)
        .animation(.easeInOut(duration: 0.2), value: session.panel)
        .animation(.easeInOut(duration: 0.25), value: session.skipAction)
        .ignoresSafeArea()
    }

    // MARK: Skip

    /// On the buttons' side, above them when the controls show (never over the info).
    private func skipButton(_ action: PlayerSession.SkipAction) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 14) {
                    Image(systemName: action.icon)
                    Text(action.title)
                }
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.black)
                .environment(\.colorScheme, .light)
                .padding(.horizontal, 36)
                .padding(.vertical, 18)
                .background(Capsule().fill(.white))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
            }
            .environment(\.layoutDirection, .leftToRight)
            .padding(.horizontal, PlayerChrome.sideInset)
            .padding(.bottom, session.controlsVisible ? 300 : 110)
        }
        .transition(.opacity)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 70)).foregroundStyle(.yellow)
            Text(message).multilineTextAlignment(.center).frame(maxWidth: 1100)
            Text("اضغط للرجوع").foregroundStyle(.secondary)
        }
        .padding(60)
        .background(RoundedRectangle(cornerRadius: 30).fill(.black.opacity(0.8)))
    }

    static func format(_ seconds: Double) -> String {
        ArabicFormat.clock(seconds: seconds)
    }
}

// MARK: - Bottom chrome

private struct PlayerChrome: View {
    let session: PlayerSession

    static let sideInset: CGFloat = 80
    @FocusState private var focus: Focus?

    enum Focus: Hashable {
        case button(PlayerSession.Panel)
        case row(String)
    }

    private var panels: [PlayerSession.Panel] {
        PlayerSession.Panel.allCases.filter { $0 != .episodes || session.item.isEpisode }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Dark only at the bottom; the picture above stays clear.
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.25), location: 0.45),
                .init(color: .black.opacity(0.55), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: 420)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)

            VStack(spacing: 22) {
                HStack(alignment: .bottom, spacing: 40) {
                    info
                    Spacer(minLength: 40)
                    buttons
                }
                VStack(spacing: 18) {
                    timeline
                    times
                }
            }
            .padding(.horizontal, Self.sideInset)
            .padding(.bottom, 56)

            if let panel = session.panel {
                panelView(panel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.horizontal, Self.sideInset - 10)
                    .padding(.bottom, 250)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
            }
        }
        .onChange(of: session.buttonsActive) { _, active in
            focus = active ? .button(session.panel ?? panels.first ?? .subtitles) : nil
        }
        .onChange(of: session.panel) { old, new in
            if let new {
                DispatchQueue.main.async { focus = .row(selectedRowID(new) ?? "") }
            } else if let old, session.buttonsActive {
                DispatchQueue.main.async { focus = .button(old) }
            }
        }
        .onAppear {
            if session.buttonsActive { focus = .button(panels.first ?? .subtitles) }
        }

    }

    // MARK: Info

    /// «S1 • E3 – عنوان الحلقة» small, the show big (two lines at most). A movie: its title.
    private var info: some View {
        let item = session.item
        return VStack(alignment: .leading, spacing: 8) {
            if item.isEpisode {
                Text(episodeLine(item))
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
            }
            Text(item.isEpisode ? (item.grandparentTitle ?? item.title) : item.title)
                .font(.system(size: 52, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.leading)
        }
        .shadow(color: .black.opacity(0.4), radius: 10)
        .frame(maxWidth: 1100, alignment: .leading)
    }

    private func episodeLine(_ episode: PlexItem) -> String {
        var code: [String] = []
        if let season = episode.parentIndex { code.append("S\(season)") }
        if let number = episode.index { code.append("E\(number)") }
        let prefix = code.isEmpty ? "" : "\u{2068}" + code.joined(separator: " • ") + "\u{2069}"
        let title = episode.title.isEmpty ? "" : "\u{2068}\(episode.title)\u{2069}"
        return [prefix, title].filter { !$0.isEmpty }.joined(separator: " – ")
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 24) {
            ForEach(panels) { panel in
                Button { session.panel = panel } label: {
                    Image(systemName: icon(panel))
                }
                .buttonStyle(GlassRoundButtonStyle(open: session.panel == panel))
                .focused($focus, equals: .button(panel))
                .disabled(!session.buttonsActive)
            }
        }
        .focusSection()
        // Where the focus lands when the player screen asks for it again (a panel closed).
        .defaultFocus($focus, .button(session.lastPanel ?? panels.first ?? .subtitles))
    }

    private func icon(_ panel: PlayerSession.Panel) -> String {
        switch panel {
        case .episodes: return "list.and.film"
        case .subtitles: return "captions.bubble"
        case .audio: return "waveform"
        case .quality: return "slider.horizontal.3"
        }
    }

    // MARK: Progress

    /// Full width, 10 pt; only what's been watched (no intro / credits marks), a
    /// small tick at the playhead. Time runs left to right, as in every player.
    private var timeline: some View {
        GeometryReader { geo in
            let played = playedFraction
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.32)).frame(height: 10)
                Capsule().fill(Color.white.opacity(0.62)).frame(width: max(10, geo.size.width * played), height: 10)
            }
            .frame(height: 10)
            // The playhead tick rises above the bar without making it thicker.
            .overlay(alignment: .leading) {
                // Playing: as tall as the bar; paused: taller; scrubbing: tallest.
                let tick: CGFloat = session.scrubPosition != nil ? 32 : (session.isPaused ? 20 : 10)
                Rectangle().fill(Color.white)
                    .frame(width: 2.5, height: tick)
                    .offset(x: geo.size.width * played - 1.25, y: -(tick - 10) / 2)
                    .animation(.easeOut(duration: 0.2), value: tick)
            }
        }
        .frame(height: 10)
        .environment(\.layoutDirection, .leftToRight)
    }

    private var playedFraction: Double {
        min(1, max(0, (session.scrubPosition ?? session.position) / max(session.duration, 1)))
    }

    /// Elapsed under the playhead (moves with it, kept on screen), «-23:38» at the right end.
    private var times: some View {
        let shown = session.scrubPosition ?? session.position
        return GeometryReader { geo in
            let remaining = Text("\u{2066}-" + PlayerOverlay.format(max(0, session.duration - shown)) + "\u{2069}")
            let elapsed = Text("\u{2066}" + PlayerOverlay.format(shown) + "\u{2069}")
            ZStack(alignment: .topLeading) {
                remaining
                    .frame(maxWidth: .infinity, alignment: .trailing)
                elapsed
                    .fixedSize()
                    .frame(width: 140)
                    .position(x: min(max(70, geo.size.width * playedFraction), geo.size.width - 230), y: 14)
            }
        }
        .frame(height: 30)
        .font(.system(size: 24, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.9))
        .environment(\.layoutDirection, .leftToRight)
    }

    // MARK: Panels

    private func selectedRowID(_ panel: PlayerSession.Panel) -> String? {
        switch panel {
        case .episodes:
            return "ep-" + session.item.ratingKey
        case .subtitles:
            return session.subtitleTracks.first(where: \.isSelected).map { "sub-\($0.id)" } ?? "sub-off"
        case .audio:
            return session.audioTracks.first(where: \.isSelected).map { "aud-\($0.id)" }
        case .quality:
            return "q-" + session.quality.rawValue
        }
    }

    @ViewBuilder
    private func panelView(_ panel: PlayerSession.Panel) -> some View {
        switch panel {
        case .episodes:
            PanelCard(title: "الحلقات", width: 760) {
                ForEach(session.seasonEpisodes) { episode in
                    PanelRow(selected: episode.ratingKey == session.item.ratingKey) {
                        Task { await session.play(episode: episode) }
                        session.panel = nil
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(episodeLine(episode)).lineLimit(1)
                            Text(episode.grandparentTitle ?? "")
                                .font(.system(size: 20))
                                .opacity(0.6)
                                .lineLimit(1)
                        }
                    }
                    .focused($focus, equals: .row("ep-" + episode.ratingKey))
                }
            }
        case .subtitles:
            PanelCard(title: "الترجمة", width: 680) {
                ForEach(orderedSubtitles.preferred) { track in subtitleRow(track) }
                PanelRow(selected: !session.subtitleTracks.contains(where: \.isSelected)) {
                    session.selectSubtitle(nil)
                } label: {
                    Text("بدون")
                }
                .focused($focus, equals: .row("sub-off"))
                ForEach(orderedSubtitles.others) { track in subtitleRow(track) }
            }
        case .audio:
            PanelCard(title: "الصوت", width: 680) {
                ForEach(session.audioTracks) { track in
                    PanelRow(selected: track.isSelected) {
                        session.selectAudio(track)
                    } label: {
                        Text(track.menuName).lineLimit(1)
                    }
                    .focused($focus, equals: .row("aud-\(track.id)"))
                }
            }
        case .quality:
            PanelCard(title: "الجودة", width: 520) {
                ForEach(PlaybackQuality.allCases) { quality in
                    PanelRow(selected: quality == session.quality) {
                        session.setQuality(quality)
                        session.panel = nil
                    } label: {
                        Text(quality.title)
                    }
                    .focused($focus, equals: .row("q-" + quality.rawValue))
                }
            }
        }
    }

    private func subtitleRow(_ track: MPVTrack) -> some View {
        PanelRow(selected: track.isSelected) {
            session.selectSubtitle(track)
        } label: {
            Text(track.menuName).lineLimit(1)
        }
        .focused($focus, equals: .row("sub-\(track.id)"))
    }

    /// The profile's subtitle language first (Arabic by default), then «بدون», then the rest.
    private var orderedSubtitles: (preferred: [MPVTrack], others: [MPVTrack]) {
        let language = ProfileStore.shared.activeProfile?.preferredSubtitleLanguage ?? "ara"
        let tracks = session.subtitleTracks
        let preferred = tracks.filter { StreamPreference.sameLanguage($0.language, language) }
        return (preferred, tracks.filter { !preferred.contains($0) })
    }
}

// MARK: - Pieces

/// Infuse's round glass button: dark smoked glass with a light top edge; focused, lighter
/// glass with a bright rim and a slight lift. The glyph stays white either way.
private struct GlassRoundButtonStyle: ButtonStyle {
    var open: Bool

    func makeBody(configuration: Configuration) -> some View { RoundBody(configuration: configuration, open: open) }

    private struct RoundBody: View {
        let configuration: ButtonStyleConfiguration
        let open: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white.opacity(isFocused ? 1 : 0.92))
                .frame(width: 63, height: 63)
                .background {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(isFocused ? Color.white.opacity(0.3) : Color.black.opacity(open ? 0.25 : 0.42))
                    // The shine: a light rim, strongest at the top.
                    Circle().strokeBorder(
                        LinearGradient(colors: [.white.opacity(isFocused ? 0.75 : 0.32),
                                                .white.opacity(isFocused ? 0.25 : 0.04),
                                                .white.opacity(isFocused ? 0.45 : 0.12)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: isFocused ? 1.6 : 1)
                }
                .environment(\.colorScheme, .dark)
                .scaleEffect(configuration.isPressed ? 0.95 : (isFocused ? 1.1 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.35 : 0.15), radius: isFocused ? 12 : 4, y: isFocused ? 6 : 2)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

/// Glass panel above the buttons: a title and a scrolling list.
private struct PanelCard<Content: View>: View {
    let title: String
    let width: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 22)
                .padding(.top, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) { content() }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
            }
            .frame(maxHeight: 520)
            .clipped()
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 18)
        .frame(width: width, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color(white: 0.22).opacity(0.7))
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .focusSection()
    }
}

/// One choice: ✓ on the current one; focused: white pill, dark text.
private struct PanelRow<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .opacity(selected ? 1 : 0)
                label()
                Spacer(minLength: 0)
            }
            .font(.system(size: 26, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PanelRowStyle())
    }
}

private struct PanelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { RowBody(configuration: configuration) }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? Color.white : Color.clear))
                .scaleEffect(isFocused ? 1.02 : 1)
                .animation(.easeOut(duration: 0.12), value: isFocused)
        }
    }
}
