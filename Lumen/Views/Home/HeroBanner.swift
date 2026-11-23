import SwiftUI

/// Apple TV app–style banner at the top of Home and of every library page (mirrored for
/// Arabic): full-screen artwork, the text block on the reading side (bottom-right), the rating
/// between laurels on the other side, page dots above the rows, and a glass chip with the page
/// name while the banner has focus. Auto-advances every 8 s while idle; loops.
struct HeroBanner: View {
    enum Control: Hashable { case play, add, info, next }

    let items: [BannerItem]
    let client: PlexServerClient
    /// «الرئيسية» on Home, the library name on a library page.
    let chipTitle: String
    var focus: FocusState<Control?>.Binding
    /// Height of the banner block in the page (the first row peeks under it); the artwork
    /// itself always covers the whole screen.
    static let height: CGFloat = 860

    @Environment(ProfileStore.self) private var store
    @State private var index = 0
    @State private var step = 1
    @State private var generation = 0
    @State private var textVisible = true
    @State private var interactions = 0
    @State private var playTargets: [String: PlexItem] = [:]
    @State private var isStartingPlayback = false

    private var current: BannerItem { items[min(index, items.count - 1)] }
    private var hasFocus: Bool { focus.wrappedValue != nil }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            textBlock
                .padding(.leading, CardKind.inset)
                .padding(.bottom, 110)
                .opacity(textVisible ? 1 : 0)
            rating
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, CardKind.inset)
                .padding(.bottom, 130)
                .opacity(textVisible ? 1 : 0)
            pageDots
                .frame(maxWidth: .infinity)
                .padding(.bottom, 36)
        }
        .frame(width: 1920, height: Self.height, alignment: .bottom)
        .overlay(alignment: .topLeading) { chip }
        .onChange(of: focus.wrappedValue) { _, _ in interactions += 1 }
        .onChange(of: items.map(\.id)) { _, ids in if index >= ids.count { index = 0 } }
        .task(id: current.id) { await resolvePlayTarget(current) }
        .task(id: "\(index)-\(interactions)") { await autoAdvance() }
    }

    // MARK: Layers

    /// Full screen (1920×1080) from the top of the block, so it runs behind the peeking row.
    private var backdrop: some View {
        ZStack {
            Color.black
            RemoteImage(url: client.imageURL(current.display.backdropPath, width: 1920, height: 1080))
                .frame(width: 1920, height: 1080)
                .id(current.id)
                .transition(.asymmetric(
                    insertion: .modifier(active: PushModifier(x: CGFloat(step) * -1920), identity: PushModifier(x: 0)),
                    removal: .modifier(active: PushModifier(x: CGFloat(step) * 1920 * 0.3), identity: PushModifier(x: 0))))
                .zIndex(Double(generation))
            // Dark only on the text side (bottom-right) and the bottom.
            LinearGradient(stops: [
                .init(color: .black.opacity(0.78), location: 0),
                .init(color: .black.opacity(0.45), location: 0.3),
                .init(color: .clear, location: 0.6),
            ], startPoint: .trailing, endPoint: .leading)
            LinearGradient(stops: [
                .init(color: .clear, location: 0.4),
                .init(color: .black.opacity(0.55), location: 0.72),
                .init(color: .black, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: 1920, height: 1080)
        .clipped()
        .environment(\.layoutDirection, .leftToRight)
        .frame(width: 1920, height: Self.height, alignment: .top)
        .allowsHitTesting(false)
    }

    private var textBlock: some View {
        let item = current.display
        return VStack(alignment: .leading, spacing: 16) {
            Text(current.label)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))

            BannerLogo(item: item, client: client)
                .frame(height: 170, alignment: .bottomLeading)

            HStack(spacing: 14) {
                Text(meta(item))
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                if let rating = item.normalizedContentRating {
                    Text(rating)
                        .font(.system(size: 18, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.7), lineWidth: 1.5))
                        .foregroundStyle(.white.opacity(0.85))
                }
                ForEach(qualityBadges(item), id: \.self) { badge in
                    Text(badge)
                        .font(.system(size: 18, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.18)))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }

            if let summary = item.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 560, alignment: .leading)
            }

            if let highlight = current.highlight {
                Text(highlight)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
            }

            buttons.padding(.top, 10)
        }
        .frame(maxWidth: 760, alignment: .leading)
        .shadow(color: .black.opacity(0.35), radius: 10)
    }

    private var buttons: some View {
        HStack(spacing: 20) {
            Button(action: play) {
                HStack(spacing: 12) {
                    Image(systemName: "play.fill")
                    Text(playTitle)
                }
            }
            .buttonStyle(GlassPillButtonStyle())
            .focused(focus, equals: .play)

            Button { store.toggleMyList(current.display.mediaInfo) } label: {
                Image(systemName: store.isOnMyList(current.display.ratingKey) ? "checkmark" : "plus")
            }
            .buttonStyle(GlassCircleButtonStyle())
            .focused(focus, equals: .add)

            NavigationLink(value: DetailRoute(item: current.display, sourceID: "banner|\(current.id)",
                                              context: BrowseContext(rowID: "banner-\(chipTitle)", items: items.map(\.display)))) {
                Image(systemName: "info")
            }
            .buttonStyle(GlassCircleButtonStyle())
            .focused(focus, equals: .info)

            if items.count > 1 {
                Button { go(+1) } label: { Image(systemName: "chevron.forward") }
                    .buttonStyle(GlassCircleButtonStyle())
                    .focused(focus, equals: .next)
            }
        }
        .focusSection()
    }

    /// The rating between laurels on the side opposite the text (MAL for anime, IMDb / TMDB…).
    @ViewBuilder
    private var rating: some View {
        if let r = current.display.ratingDisplay {
            HStack(spacing: 6) {
                Image(systemName: "laurel.leading").font(.system(size: 54, weight: .light))
                VStack(spacing: 2) {
                    Text(ArabicFormat.digits(String(format: "%.1f", r.value)).replacingOccurrences(of: ".", with: "٫"))
                        .font(.system(size: 40, weight: .bold))
                    if !r.source.isEmpty {
                        Text(r.source)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                Image(systemName: "laurel.trailing").font(.system(size: 54, weight: .light))
            }
            .foregroundStyle(.white.opacity(0.9))
            .environment(\.layoutDirection, .leftToRight)
            .shadow(color: .black.opacity(0.4), radius: 8)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 10) {
            ForEach(items.indices, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Color.white : Color.white.opacity(0.35))
                    .frame(width: i == index ? 28 : 9, height: 9)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: index)
        .opacity(items.count > 1 ? 1 : 0)
        .allowsHitTesting(false)
    }

    /// Glass chip with the page name, only while the banner has focus.
    private var chip: some View {
        Text(chipTitle)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background {
                Capsule().fill(.ultraThinMaterial)
                Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            }
            .padding(.top, 50)
            .padding(.leading, CardKind.inset)
            .opacity(hasFocus ? 1 : 0)
            .animation(.easeInOut(duration: 0.3).delay(hasFocus ? 0.35 : 0), value: hasFocus)
            .allowsHitTesting(false)
    }

    // MARK: Text

    private func meta(_ item: PlexItem) -> String {
        var parts = [item.isShow ? "مسلسل" : "فيلم"]
        parts += ArabicFormat.genres(item.genres.map(\.tag), limit: 2)
        if let year = item.year { parts.append(ArabicFormat.digits(year)) }
        return ArabicFormat.joined(parts)
    }

    /// Resolution and HDR of the file Play starts (movies; shows show none until resolved).
    private func qualityBadges(_ item: PlexItem) -> [String] {
        let target = playTargets[current.id] ?? item
        var out: [String] = []
        if target.media.first?.resolutionBadge == "4K" { out.append("4K") }
        switch target.dynamicRangeBadge {
        case "Dolby Vision": out.append("Dolby Vision")
        case "HDR10", "HLG": out.append("HDR")
        default: break
        }
        return out
    }

    private var playTitle: String {
        let item = current.display
        let target = playTargets[current.id]
        if item.isShow, let target {
            let started = store.progress(of: target) != nil || store.watchedEpisodeCount(under: item.ratingKey) > 0
            if started, let e = target.index { return "متابعة الحلقة \(ArabicFormat.digits(e))" }
            return "تشغيل"
        }
        return store.progress(of: item) != nil ? "متابعة" : "تشغيل"
    }

    // MARK: Actions

    private func go(_ delta: Int) {
        guard items.count > 1 else { return }
        step = delta
        let target = (index + delta + items.count) % items.count
        textVisible = false
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.35)) {
            generation += 1
            index = target
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.easeOut(duration: 0.3)) { textVisible = true }
        }
    }

    private func play() {
        guard !isStartingPlayback else { return }
        let item = current
        isStartingPlayback = true
        Task {
            defer { isStartingPlayback = false }
            var target = playTargets[item.id]
            if target == nil {
                target = item.display.isShow ? await client.episodeToPlay(showKey: item.display.ratingKey) : item.display
            }
            guard let target else { return }
            await PlaybackManager.shared.play(target, client: client)
        }
    }

    private func resolvePlayTarget(_ item: BannerItem) async {
        guard playTargets[item.id] == nil else { return }
        if item.display.isShow {
            if let episode = await client.episodeToPlay(showKey: item.display.ratingKey) { playTargets[item.id] = episode }
        } else {
            playTargets[item.id] = item.display
        }
    }

    private func autoAdvance() async {
        try? await Task.sleep(for: .seconds(8))
        guard !Task.isCancelled, items.count > 1, !PlaybackManager.shared.isPlaying else { return }
        go(+1)
    }
}

private struct PushModifier: ViewModifier {
    var x: CGFloat
    func body(content: Content) -> some View { content.offset(x: x) }
}

/// Clear logo, else the title in large type.
private struct BannerLogo: View {
    let item: PlexItem
    let client: PlexServerClient
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 620, maxHeight: 170, alignment: .bottomLeading)
            } else if failed {
                Text(item.title)
                    .font(.system(size: 76, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 760, alignment: .leading)
            } else {
                Color.clear.frame(width: 10, height: 170)
            }
        }
        .task(id: item.ratingKey) {
            image = nil
            failed = false
            guard let url = client.imageURL(item.clearLogoPath, width: 1240, height: 340, png: true) else {
                failed = true
                return
            }
            image = await ImageLoader.shared.image(for: url)
            failed = image == nil
        }
    }
}

// MARK: - Glass buttons

/// Translucent pill; focused: white fill, dark glyph, slight scale.
struct GlassPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { PillBody(configuration: configuration) }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .environment(\.colorScheme, isFocused ? .light : .dark)
                .padding(.horizontal, 40)
                .frame(height: 76)
                .background {
                    if isFocused {
                        Capsule().fill(Color.white)
                    } else {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    }
                }
                .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.06 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 16, y: 8)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}

/// Translucent round button (+, ⓘ, ›); focused: white fill, dark glyph, slight scale.
struct GlassCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { CircleBody(configuration: configuration) }

    private struct CircleBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .environment(\.colorScheme, isFocused ? .light : .dark)
                .frame(width: 76, height: 76)
                .background {
                    if isFocused {
                        Circle().fill(Color.white)
                    } else {
                        Circle().fill(.ultraThinMaterial)
                        Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    }
                }
                .scaleEffect(configuration.isPressed ? 0.94 : (isFocused ? 1.08 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 14, y: 8)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}

extension Animation {
    /// Apple TV app scrolling: very fast start, long smooth ease-out, no overshoot.
    static var appleScroll: Animation { .spring(response: 0.5, dampingFraction: 1.0) }
}
