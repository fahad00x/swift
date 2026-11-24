import SwiftUI

/// On-screen controls drawn over the MPV video layer.
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
                if session.controlsVisible || session.scrubPosition != nil {
                    transport.transition(.opacity)
                }
                if session.isPaused && !session.isPanelOpen {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 90))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(radius: 20)
                }
                if let skip = session.skipAction, !session.isPanelOpen {
                    skipButton(skip)
                }
                // TEMPORARY (remote test build): where the last command came from.
                Text(verbatim: session.commandLog)
                    .font(.system(size: 20, design: .monospaced))
                    .foregroundStyle(.yellow)
                    .padding(40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .environment(\.layoutDirection, .leftToRight)
                    .allowsHitTesting(false)
                if session.isPanelOpen {
                    TracksPanel(session: session)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: session.controlsVisible)
        .animation(.easeInOut(duration: 0.25), value: session.isPanelOpen)
        .animation(.easeInOut(duration: 0.25), value: session.skipAction)
        .ignoresSafeArea()
    }

    // MARK: Transport bar

    private var transport: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 220)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(session.title).font(.title2.weight(.bold))
                        if let subtitle = session.subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 90).padding(.top, 60)
                }
            Spacer()
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 300)
                VStack(spacing: 16) {
                    timeline
                    HStack(spacing: 0) {
                        Text(Self.format(session.scrubPosition ?? session.position))
                        Spacer()
                        // Hint only while the panel is closed (it's what the swipe opens).
                        Text("اسحب للأسفل: الصوت والترجمة")
                            .foregroundStyle(.secondary)
                            .opacity(session.isPanelOpen ? 0 : 1)
                        Spacer()
                        // Remaining time, then (as its own label) when the video ends.
                        Text("-" + Self.format(max(0, session.duration - (session.scrubPosition ?? session.position))))
                        Text(ArabicFormat.separator).foregroundStyle(.secondary)
                        Text("ينتهي \(endTime)")
                            .foregroundStyle(.secondary)
                            .environment(\.layoutDirection, .rightToLeft)
                    }
                    .font(.caption.monospacedDigit())
                    .environment(\.layoutDirection, .leftToRight)
                }
                .padding(.horizontal, 90)
                .padding(.bottom, 70)
            }
        }
    }

    private var timeline: some View {
        GeometryReader { geo in
            let total = max(session.duration, 1)
            let played = min(1, session.position / total)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Color.white).frame(width: geo.size.width * played)
                ForEach(markerRanges(total: total), id: \.0) { range in
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.8))
                        .frame(width: max(4, geo.size.width * (range.1 - range.0)))
                        .offset(x: geo.size.width * range.0)
                }
                if let scrub = session.scrubPosition {
                    let x = geo.size.width * min(1, scrub / total)
                    VStack(spacing: 6) {
                        Text(Self.format(scrub))
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Capsule().fill(.black.opacity(0.7)))
                            .fixedSize()
                        Capsule().fill(Color.accentColor).frame(width: 6, height: 30)
                    }
                    .position(x: x, y: -12)
                }
            }
        }
        .frame(height: 10)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func markerRanges(total: Double) -> [(Double, Double)] {
        session.segments.map { segment in
            (segment.startSeconds / total, min(1, segment.endSeconds / total))
        }
    }

    private var endTime: String {
        let remaining = max(0, session.duration - session.position)
        return ArabicFormat.time(Date().addingTimeInterval(remaining))
    }

    // MARK: Skip

    private func skipButton(_ action: PlayerSession.SkipAction) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 14) {
                    Image(systemName: action.icon)
                    Text(action.title)
                }
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.black)
                .environment(\.colorScheme, .light)
                .padding(.horizontal, 36)
                .padding(.vertical, 20)
                .background(Capsule().fill(.white))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                .overlay(alignment: .bottom) {
                    Text("اضغط على الريموت")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                        .offset(y: 44)
                }
            }
            .padding(.horizontal, 90)
            .padding(.bottom, session.controlsVisible ? 230 : 120)
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
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

/// Audio / subtitle chooser, opened by swiping down (like Infuse's info panel).
private struct TracksPanel: View {
    let session: PlayerSession

    var body: some View {
        VStack {
            HStack(alignment: .top, spacing: 60) {
                column(title: "الصوت", systemImage: "speaker.wave.2.fill") {
                    ForEach(session.audioTracks) { track in
                        row(track.displayName, selected: track.isSelected) { session.selectAudio(track) }
                    }
                }
                column(title: "الترجمة", systemImage: "captions.bubble.fill") {
                    row("إيقاف", selected: !session.subtitleTracks.contains(where: \.isSelected)) {
                        session.selectSubtitle(nil)
                    }
                    ForEach(session.subtitleTracks) { track in
                        row(track.displayName, selected: track.isSelected) {
                            session.selectSubtitle(track)
                        }
                    }
                }
            }
            .padding(50)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .padding(.horizontal, 80)
            .padding(.top, 50)
            Spacer()
        }
    }

    private func column<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: systemImage).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) { content() }
                    .padding(.vertical, 10)
            }
            .frame(maxHeight: 420)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: "checkmark").opacity(selected ? 1 : 0)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
