import SwiftUI

/// Full-bleed featured carousel at the top of Home, modelled on the Apple TV app.
///
/// - Background and text slide at different speeds (parallax) when the slide changes.
/// - The buttons stay in place (only their labels change) so focus is never lost mid-transition.
/// - Moving past either end of the button row (click or swipe) pages to the previous/next slide,
///   via invisible focus targets at both ends.
/// - Auto-advances every 8 s; any interaction restarts the timer.
///
/// Animation geometry is computed in physical (left/right) coordinates inside a
/// left-to-right container; text and buttons get the app's layout direction back (RTL).
struct HeroCarousel: View {
    let items: [FeaturedItem]
    let client: PlexServerClient
    /// Height at the bottom of the hero covered by the "Continue Watching" row.
    var bottomInset: CGFloat
    /// Called when focus enters the hero (Home scrolls back to the top).
    var onFocusEnter: () -> Void = {}

    @Environment(\.layoutDirection) private var appDirection
    @Environment(BrowseReturnState.self) private var returnState
    @Environment(ProfileStore.self) private var store
    @State private var index = 0
    @State private var step = 1
    @State private var generation = 0
    @State private var interactions = 0
    @State private var backdrops: [String: UIImage] = [:]
    @State private var logos: [String: UIImage] = [:]
    @State private var showEpisodes: [String: PlexItem] = [:]
    @State private var isStartingPlayback = false
    @State private var didInitialFocus = false
    @FocusState private var focus: Control?

    enum Control: Hashable { case play, watchlist, info, next, edgeStart, edgeEnd }

    private static let autoAdvance: Duration = .seconds(8)
    private let screenWidth: CGFloat = 1920
    private let heroHeight: CGFloat = 1080

    private var isRTL: Bool { appDirection == .rightToLeft }
    private var current: FeaturedItem { items[min(index, items.count - 1)] }
    private var controlOrder: [Control] { items.count > 1 ? [.play, .watchlist, .info, .next] : [.play, .watchlist, .info] }

    /// +1 when the incoming slide should enter from the right edge of the screen.
    /// "Next" reads in the language's direction: from the right in LTR, from the left in RTL.
    private var entrySign: CGFloat { CGFloat(step) * (isRTL ? -1 : 1) }

    var body: some View {
        ZStack {
            background
            scrim
            content
            pageIndicator
        }
        .frame(width: screenWidth, height: heroHeight)
        .clipped()
        .environment(\.layoutDirection, .leftToRight)
        .onChange(of: focus) { old, new in handleFocusChange(from: old, to: new) }
        .onChange(of: items.map(\.id)) { _, ids in
            if index >= ids.count { index = 0 }
        }
        .task(id: current.id) { await prepare() }
        .task(id: "\(index)-\(interactions)") { await autoAdvance() }
        .onAppear {
            // Back from a details page that paged through the suggestions: show the last one reached.
            if let id = returnState.take(for: "hero"), let i = items.firstIndex(where: { $0.id == id }) {
                index = i
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focus = .info }
            }
            guard !didInitialFocus else { return }
            didInitialFocus = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focus = .play }
        }
        .defaultFocus($focus, .play)
    }

    // MARK: Layers

    private var background: some View {
        ZStack {
            Color.black
            Group {
                if let image = backdrops[current.id] {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: screenWidth, height: heroHeight)
                } else {
                    RemoteImage(url: backdropURL(current))
                        .frame(width: screenWidth, height: heroHeight)
                }
            }
            .id(current.id)
            .transition(slide(insertion: screenWidth, removal: screenWidth * 0.35, removalOpacity: 0.5))
            .zIndex(Double(generation))
        }
        .frame(width: screenWidth, height: heroHeight)
        .clipped()
    }

    private var scrim: some View {
        ZStack {
            // Darkens the side the text sits on.
            LinearGradient(stops: [
                .init(color: .black.opacity(0.88), location: 0),
                .init(color: .black.opacity(0.6), location: 0.3),
                .init(color: .black.opacity(0.0), location: 0.7),
            ], startPoint: isRTL ? .trailing : .leading, endPoint: isRTL ? .leading : .trailing)
            // Darkens the bottom for the text and the Continue Watching row.
            LinearGradient(stops: [
                .init(color: .clear, location: 0.35),
                .init(color: .black.opacity(0.55), location: 0.65),
                .init(color: .black.opacity(0.95), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            // Keeps the tab bar readable.
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.22))
        }
        .allowsHitTesting(false)
    }

    private var content: some View {
        VStack(alignment: isRTL ? .trailing : .leading, spacing: 34) {
            ZStack(alignment: isRTL ? .bottomTrailing : .bottomLeading) {
                HeroInfo(item: current, client: client, logo: logos[current.id])
                    .environment(\.layoutDirection, appDirection)
                    .id(current.id)
                    .transition(slide(insertion: 320, removal: 160, removalOpacity: 0, insertionOpacity: 0))
                    .zIndex(Double(generation))
            }
            .frame(width: 1000, height: 470, alignment: isRTL ? .bottomTrailing : .bottomLeading)

            controls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isRTL ? .bottomTrailing : .bottomLeading)
        .padding(.horizontal, 110)
        .padding(.bottom, bottomInset + 70)
    }

    private var controls: some View {
        HStack(spacing: 22) {
            edgeTarget(.edgeStart)

            Button(action: play) {
                HStack(spacing: 12) {
                    Image(systemName: "play.fill")
                    Text(playTitle)
                }
            }
            .buttonStyle(HeroPillButtonStyle())
            .focused($focus, equals: .play)

            // «قائمتي» of the current profile.
            Button(action: toggleWatchlist) {
                Image(systemName: store.isOnMyList(current.display.ratingKey) ? "checkmark" : "plus")
            }
            .buttonStyle(HeroCircleButtonStyle())
            .focused($focus, equals: .watchlist)

            NavigationLink(value: DetailRoute(item: current.display, sourceID: "hero|\(current.id)",
                                              context: BrowseContext(rowID: "hero", items: items.map(\.display)))) {
                Image(systemName: "info")
            }
            .buttonStyle(HeroCircleButtonStyle())
            .focused($focus, equals: .info)

            if items.count > 1 {
                Button { go(+1) } label: {
                    Image(systemName: "chevron.forward")
                }
                .buttonStyle(HeroCircleButtonStyle())
                .focused($focus, equals: .next)
            }

            edgeTarget(.edgeEnd)
        }
        .environment(\.layoutDirection, appDirection)
        .focusSection()
    }

    private var pageIndicator: some View {
        HStack(spacing: 12) {
            ForEach(items.indices, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Color.white : Color.white.opacity(0.35))
                    .frame(width: i == index ? 30 : 10, height: 10)
            }
        }
        .environment(\.layoutDirection, appDirection)
        .animation(.easeInOut(duration: 0.35), value: index)
        .opacity(items.count > 1 ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, bottomInset + 26)
        .allowsHitTesting(false)
    }

    /// Invisible focus target just beyond the end of the button row.
    private func edgeTarget(_ control: Control) -> some View {
        Color.white.opacity(0.001)
            .frame(width: 6, height: 80)
            .focusable(items.count > 1)
            .focused($focus, equals: control)
    }

    // MARK: Transitions

    private func slide(insertion: CGFloat, removal: CGFloat, removalOpacity: Double, insertionOpacity: Double = 1) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: SlideModifier(x: entrySign * insertion, opacity: insertionOpacity),
                                 identity: SlideModifier(x: 0, opacity: 1)),
            removal: .modifier(active: SlideModifier(x: -entrySign * removal, opacity: removalOpacity),
                               identity: SlideModifier(x: 0, opacity: 1))
        )
    }

    // MARK: Actions

    private func go(_ delta: Int) {
        guard items.count > 1 else { return }
        // Set the direction first so the outgoing slide's removal transition picks it up.
        step = delta
        let target = (index + delta + items.count) % items.count
        DispatchQueue.main.async {
            withAnimation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.85)) {
                generation += 1
                index = target
            }
        }
    }

    private func handleFocusChange(from old: Control?, to new: Control?) {
        interactions += 1
        switch new {
        case .edgeEnd?:
            if let old, controlOrder.contains(old) { go(+1) }
            DispatchQueue.main.async { focus = controlOrder.last }
        case .edgeStart?:
            if let old, controlOrder.contains(old) { go(-1) }
            DispatchQueue.main.async { focus = .play }
        case .some(_) where old == nil:
            onFocusEnter()
        default:
            break
        }
    }

    private var playTarget: PlexItem? {
        current.playable ?? showEpisodes[current.id] ?? (current.display.isShow ? nil : current.display)
    }

    private var playTitle: String {
        let target = playTarget
        let verb = (target?.progress != nil && target?.isWatched == false) ? "استئناف" : "تشغيل"
        if current.display.isShow, let code = target?.episodeCode { return "\(verb) \(code)" }
        return verb
    }

    private func play() {
        guard !isStartingPlayback else { return }
        let item = current
        isStartingPlayback = true
        Task {
            defer { isStartingPlayback = false }
            var target = item.playable ?? showEpisodes[item.id]
            if target == nil {
                target = item.display.isShow ? await client.episodeToPlay(showKey: item.display.ratingKey) : item.display
            }
            guard let target else { return }
            await PlaybackManager.shared.play(target, client: client)
        }
    }

    private func toggleWatchlist() {
        store.toggleMyList(current.display.mediaInfo)
    }

    // MARK: Loading

    private func backdropURL(_ item: FeaturedItem) -> URL? {
        client.imageURL(item.display.backdropPath, width: 3840, height: 2160)
    }

    private func neighbors() -> [FeaturedItem] {
        guard !items.isEmpty else { return [] }
        let n = items.count
        var seen = Set<String>()
        return [index, index + 1, index - 1]
            .map { items[($0 % n + n) % n] }
            .filter { seen.insert($0.id).inserted }
    }

    private func loadArtwork(_ item: FeaturedItem) async {
        if backdrops[item.id] == nil, let url = backdropURL(item), let image = await ImageLoader.shared.image(for: url) {
            backdrops[item.id] = image
        }
        if logos[item.id] == nil,
           let url = client.imageURL(item.display.clearLogoPath, width: 1440, height: 480, png: true),
           let image = await ImageLoader.shared.image(for: url) {
            logos[item.id] = image
        }
    }

    private func prepare() async {
        let item = current
        // Current slide first, then its neighbours so a transition never shows a blank frame.
        for neighbor in neighbors() { await loadArtwork(neighbor) }
        // Keep only nearby 4K images in memory.
        let keep = Set(neighbors().map(\.id))
        backdrops = backdrops.filter { keep.contains($0.key) }
        logos = logos.filter { keep.contains($0.key) }

        if item.playable == nil, item.display.isShow, showEpisodes[item.id] == nil {
            showEpisodes[item.id] = await client.episodeToPlay(showKey: item.display.ratingKey)
        }
    }

    private func autoAdvance() async {
        try? await Task.sleep(for: Self.autoAdvance)
        guard !Task.isCancelled, items.count > 1, !PlaybackManager.shared.isPlaying else { return }
        await loadArtwork(items[(index + 1) % items.count])
        guard !Task.isCancelled else { return }
        go(+1)
    }
}

private struct SlideModifier: ViewModifier {
    var x: CGFloat
    var opacity: Double

    func body(content: Content) -> some View {
        content.offset(x: x).opacity(opacity)
    }
}

// MARK: - Text block

private struct HeroInfo: View {
    let item: FeaturedItem
    let client: PlexServerClient
    let logo: UIImage?

    private var quality: PlexItem { item.playable ?? item.display }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(item.eyebrow)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))

            HeroLogo(item: item.display, client: client, preloaded: logo)

            HStack(spacing: 14) {
                Text(metaParts.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                ForEach(badges, id: \.self) { Badge(text: $0) }
            }

            if let summary = item.display.summary, !summary.isEmpty {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 920, alignment: .leading)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 12)
    }

    private var metaParts: [String] {
        let d = item.display
        var parts: [String] = [d.isShow ? "مسلسل" : "فيلم"]
        if let genre = d.genres.first?.tag { parts.append(genre) }
        if let year = d.year { parts.append(String(year)) }
        if d.isShow {
            if let seasons = d.childCount { parts.append(Self.seasons(seasons)) }
        } else if let duration = d.durationText {
            parts.append(duration)
        }
        return parts
    }

    private var badges: [String] {
        var out: [String] = []
        if let rating = item.display.contentRating, !rating.isEmpty { out.append(rating) }
        if quality.media.first?.resolutionBadge == "4K" { out.append("4K") }
        switch quality.dynamicRangeBadge {
        case "Dolby Vision": out.append("Dolby Vision")
        case "HDR10", "HLG": out.append("HDR")
        default: break
        }
        return out
    }

    static func seasons(_ n: Int) -> String {
        switch n {
        case 1: return "موسم واحد"
        case 2: return "موسمان"
        case 3...10: return "\(n) مواسم"
        default: return "\(n) موسماً"
        }
    }
}

/// Clear logo when Plex has one; otherwise the title in large bold type.
private struct HeroLogo: View {
    let item: PlexItem
    let client: PlexServerClient
    @State private var image: UIImage?
    @State private var failed = false

    init(item: PlexItem, client: PlexServerClient, preloaded: UIImage?) {
        self.item = item
        self.client = client
        _image = State(initialValue: preloaded)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 720, maxHeight: 230, alignment: .bottomLeading)
            } else if failed || item.clearLogoPath == nil {
                Text(item.title)
                    .font(.system(size: 92, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.55)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 1000, alignment: .leading)
            } else {
                Color.clear.frame(width: 10, height: 200)
            }
        }
        .task(id: item.ratingKey) {
            guard image == nil else { return }
            guard let url = client.imageURL(item.clearLogoPath, width: 1440, height: 480, png: true) else {
                failed = true
                return
            }
            image = await ImageLoader.shared.image(for: url)
            failed = image == nil
        }
    }
}

// MARK: - Button styles

/// White capsule (Play / Resume).
struct HeroPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.headline)
                .foregroundStyle(.black)
                .padding(.horizontal, 46)
                .frame(height: 76)
                .background(Capsule().fill(Color.white.opacity(isFocused ? 1 : 0.88)))
                .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.1 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 18, y: 10)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}

/// Small round icon button (+, i, >).
struct HeroCircleButtonStyle: ButtonStyle {
    var dimmed = false

    func makeBody(configuration: Configuration) -> some View {
        CircleBody(configuration: configuration, dimmed: dimmed)
    }

    private struct CircleBody: View {
        let configuration: ButtonStyleConfiguration
        let dimmed: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .frame(width: 76, height: 76)
                .background(Circle().fill(isFocused ? Color.white : Color.white.opacity(0.2)))
                .opacity(dimmed && !isFocused ? 0.45 : 1)
                .scaleEffect(configuration.isPressed ? 0.94 : (isFocused ? 1.12 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 14, y: 8)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}
