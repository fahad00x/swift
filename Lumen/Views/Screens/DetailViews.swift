import SwiftUI

/// Apple TV app–style details page, mirrored for Arabic.
///
/// BROWSING (focus on the page itself, not a button): the title's artwork is a rounded card
/// (100 pt side margins, 32 pt from the top, running past the bottom edge) with the text on the
/// reading side (right) and the cast on the other. The row's neighbouring titles peek at the
/// sides; Left / Right slide the strip to the next / previous one (next comes from the left).
///
/// BUTTONS (Down to Play): the card grows to the full screen (~0.2 s). The top of the first
/// episodes row peeks at the bottom (y≈970).
///
/// EPISODES (Down, or the episodes button): a real vertical scroll (~0.8 s ease-out): the rows
/// rise to y≈240, the text slides off the top, the logo becomes a small title, and the same
/// backdrop blurs and darkens. Up from the seasons, or Back, is the exact reverse.
///
/// The backdrop is one stable image per title (never reloaded or cycled while idle).
struct DetailPage: View {
    let client: PlexServerClient
    /// Row the page was opened from; Left / Right page through it (no wrap-around).
    let context: BrowseContext?
    /// Zoom source of the card that opened the page (when there is no row context).
    let sourceID: String?

    @Environment(\.detailNamespace) private var zoomNamespace
    @Environment(BrowseReturnState.self) private var returnState
    @Environment(ProfileStore.self) private var store
    @Environment(\.contentFilter) private var filter
    @Environment(\.dismiss) private var dismiss
    @Environment(ShellState.self) private var shell: ShellState?

    /// The row item currently shown (movie, show, season or episode).
    @State private var current: PlexItem
    @State private var metadataCache: [String: PlexItem] = [:]
    @State private var logos: [String: UIImage] = [:]
    /// ratingKey → what the title contains (TMDB), once looked up.
    @State private var advisory: [String: [ContentFlag]] = [:]

    @State private var item: PlexItem?
    @State private var playTarget: PlexItem?
    @State private var seasons: [PlexItem] = []
    @State private var selectedSeasonKey: String?
    @State private var episodesBySeason: [String: [PlexItem]] = [:]
    @State private var related: [PlexItem] = []
    @State private var extras: [PlexItem] = []
    @State private var revealed = false
    /// Focus is on the page itself (paging between titles): the artwork is a card. Off once
    /// focus reaches the buttons or the rows: full screen.
    @State private var browsing: Bool
    /// Scrolled down to the episodes (and below).
    @State private var scrolled = false
    /// The scroll to the episodes finished (Up to the top works only then, so focus landing
    /// on the top strip while it moves doesn't scroll back again).
    @State private var episodesReady = false
    @State private var audioSelection = -1
    @State private var subtitleSelection = -1
    /// Selection last loaded from the profile (changes from the menu differ from it).
    @State private var shownStreams: (audio: Int, subtitle: Int) = (-1, -1)

    @FocusState private var heroFocus: HeroButton?
    @FocusState private var seasonFocus: String?
    @FocusState private var lowerFocus: String?

    enum HeroButton: Hashable { case browse, play, watchlist, episodes, down, backToTop }

    /// Side inset of rows on the full-screen episodes view.
    static let sideInset: CGFloat = CardKind.inset

    // Card geometry (px at 1920×1080).
    private static let screen = CGSize(width: 1920, height: 1080)
    private static let cardMargin: CGFloat = 100
    private static let cardTop: CGFloat = 32
    private static let cardGap: CGFloat = 22
    private static let cardRadius: CGFloat = 36
    private static var cardWidth: CGFloat { screen.width - 2 * cardMargin }
    /// Runs 32 pt past the bottom edge.
    private static var cardHeight: CGFloat { screen.height }
    private static var pitch: CGFloat { cardWidth + cardGap }
    /// Text 40 pt inside the card edge.
    private static var textInset: CGFloat { cardMargin + 40 }

    // Vertical scroll (px at 1920×1080).
    /// Top of the first episodes row: peeking at the top state, near the top once scrolled.
    private static let peekTop: CGFloat = 970
    private static let episodesTop: CGFloat = 240
    private static var scrollDistance: CGFloat { peekTop - episodesTop }
    /// Height of the season labels line.
    private static let labelsHeight: CGFloat = 64
    private static let rowSpacing: CGFloat = 34
    /// From the top of the rows block to the top of the first row's images. Shows: top strip 8
    /// + season labels + spacing + the row's own top padding 24. Movies: top strip 8 + the
    /// «ذات صلة» header + padding 24 (or the extras header 36 + padding 34).
    private var leadIn: CGFloat {
        if item?.isShow ?? current.isShow { return 8 + Self.labelsHeight + Self.rowSpacing + 24 }
        if !related.isEmpty { return 8 + Self.labelsHeight + 24 }
        return 8 + 36 + 34
    }
    private static let lowerTopID = "detail-lower-top"
    /// ~0.8 s ease-out, most of the motion in the first 0.4 s.
    private static func scrollCurve(_ duration: Double) -> Animation {
        .timingCurve(0.16, 1, 0.3, 1, duration: duration)
    }

    init(client: PlexServerClient, entry: PlexItem, context: BrowseContext? = nil, sourceID: String? = nil) {
        self.client = client
        self.context = context
        self.sourceID = sourceID
        _current = State(initialValue: entry)
        _browsing = State(initialValue: (context?.items.count ?? 0) > 1)
    }

    /// The page can page between titles of a row (otherwise there's no card state).
    private var canBrowse: Bool { (context?.items.count ?? 0) > 1 }
    /// The current artwork fills the screen.
    private var fullScreen: Bool { scrolled || !browsing }

    /// Movie or show the page describes (episodes and seasons open their show).
    private var ratingKey: String { displayKey(current) }
    private var initialSeasonKey: String? {
        switch current.type {
        case "episode": return current.parentRatingKey
        case "season": return current.ratingKey
        default: return nil
        }
    }
    /// Episode the Play button should start (e.g. opened from Continue Watching).
    private var preferredEpisode: PlexItem? { current.isEpisode ? current : nil }

    private var currentIndex: Int? { context?.items.firstIndex { $0.id == current.id } }
    private var hasPrevious: Bool { (currentIndex ?? 0) > 0 }
    private var hasNext: Bool {
        guard let context, let i = currentIndex else { return false }
        return i + 1 < context.items.count
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Flat dark grey behind the cards.
            Color(red: 0.149, green: 0.149, blue: 0.149)

            cardStrip

            if canBrowse { browseTarget }

            if let item {
                // Near-invisible (not 0) until revealed, so the buttons can take focus at once
                // and focus never escapes to the sidebar. Slides off the top when scrolled.
                cardText(item)
                    .opacity(scrolled ? 0 : (revealed ? 1 : 0.02))
                    .offset(y: (revealed ? 0 : 24) - (scrolled ? Self.scrollDistance : 0))

                // The rows: the first one peeks at the bottom, then scrolls up under the title.
                lowerContent(item)
                    .offset(y: (scrolled ? Self.episodesTop : Self.peekTop) - leadIn)
                    .opacity(revealed ? 1 : 0)
                    // Focusable only once scrolled (Down from the buttons scrolls first): at the
                    // top the peeking row is display-only, so Down from the card lands on Play and
                    // scrolling back up hands focus back to the buttons.
                    .disabled(!scrolled)

                // Rows scroll up under the small title: a dark fade keeps it readable.
                LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.4), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 190)
                    .opacity(scrolled ? 1 : 0)
                    .allowsHitTesting(false)

                // The logo as a small title at the top once scrolled.
                LogoView(image: logos[item.ratingKey], title: item.title,
                         maxSize: CGSize(width: 260, height: 70), fontSize: 36)
                    .frame(height: 70)
                    .padding(.top, 30)
                    .opacity(scrolled ? 1 : 0)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: Self.screen.width, height: Self.screen.height)
        .ignoresSafeArea()
        .onExitCommand(perform: exitAction)
        .onChange(of: audioSelection) { _, id in
            guard id > 0, id != shownStreams.audio else { return }
            shownStreams.audio = id
            saveStreams(audio: id)
        }
        .onChange(of: subtitleSelection) { _, id in
            guard id >= 0, id != shownStreams.subtitle else { return }
            shownStreams.subtitle = id
            saveStreams(subtitle: id)
        }
        .onChange(of: seasonFocus) { _, key in
            if let key {
                selectedSeasonKey = key
                setScrolled(true)
            }
        }
        .onChange(of: lowerFocus) { _, key in
            if key != nil { setScrolled(true) }
        }
        .onChange(of: heroFocus) { old, new in handleHeroFocus(from: old, to: new) }
        .task(id: current.id) {
            // Artwork alone first, then the text fades in (+0.3 s) once the data is ready.
            let start = Date()
            await PlexResponseCache.$policy.withValue(.cacheOnly) { await load() }
            let cacheMiss = item == nil || item?.ratingKey != ratingKey
            if cacheMiss { await load() }
            let minimum = 0.65
            let wait = minimum - Date().timeIntervalSince(start)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { revealed = true }
            if heroFocus == nil, !scrolled { heroFocus = canBrowse ? .browse : .play }
            if !cacheMiss { await load() }
            await preloadNeighbours()
        }
        .zoomDestination(id: zoomSourceID,
                         namespace: (context?.rowID.hasPrefix("banner") ?? false) ? nil : zoomNamespace)
        .onReceive(NotificationCenter.default.publisher(for: .plexPlaybackDidEnd)) { _ in
            Task { await load() }
        }
        .defaultFocus($heroFocus, canBrowse ? .browse : .play)
        .onAppear {
            shell?.pushedPages += 1
            // Back lands on the same poster (or the last one reached by paging).
            if let context { returnState.set(rowID: context.rowID, itemID: current.id) }
        }
        .onDisappear { shell?.pushedPages = max(0, (shell?.pushedPages ?? 1) - 1) }
    }

    /// Back goes one step back: from the episodes to the top, from the top to the poster.
    private func exitAction() {
        if scrolled {
            lowerFocus = nil
            seasonFocus = nil
            setScrolled(false)
            // Once the buttons are visible again (they can't take focus while invisible).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { heroFocus = .play }
        } else {
            dismiss()
        }
    }

    /// Top ↔ episodes: a real vertical scroll (~0.8 s down, ~0.75 s back up, ease-out).
    private func setScrolled(_ value: Bool) {
        guard scrolled != value else { return }
        episodesReady = false
        withAnimation(Self.scrollCurve(value ? 0.8 : 0.75)) {
            scrolled = value
            if value { browsing = false }
        }
        if value {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if scrolled { episodesReady = true } }
        }
    }

    /// Card (browsing) ↔ full screen (buttons and below), ~0.2 s.
    private func setBrowsing(_ value: Bool) {
        guard browsing != value else { return }
        withAnimation(.easeOut(duration: 0.2)) { browsing = value }
    }

    // MARK: - Cards

    /// Invisible focus target over the top of the card: focus here means browsing between
    /// titles (card state); Left / Right page through the row; Down goes to the buttons.
    private var browseTarget: some View {
        // Above the button row (reading side, physical right), so Down lands on Play.
        Color.white.opacity(0.001)
            .frame(width: Self.browseWidth, height: 420)
            .focusable(!scrolled)
            .focused($heroFocus, equals: .browse)
            .onMoveCommand { direction in
                // Physical directions: in Arabic the next title comes from the left.
                switch direction {
                case .left: page(+1)
                case .right: page(-1)
                case .down: heroFocus = .play
                default: break
                }
            }
            // Physical right edge, over the buttons (explicit layout: an x offset flips in RTL).
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, Self.textInset)
            .padding(.top, Self.cardTop + 80)
            .environment(\.layoutDirection, .leftToRight)
    }

    /// Width of the browsing focus target: about the button row's.
    private static let browseWidth: CGFloat = 560

    /// The current card and its neighbours as one strip (physical coordinates: in Arabic the
    /// next title sits on the left). Off the browsing state the current card fills the screen.
    private var cardStrip: some View {
        let items = context?.items ?? [current]
        let i = currentIndex ?? 0
        let window = items.indices.filter { abs($0 - i) <= 2 }.map { items[$0] }
        return ZStack(alignment: .top) {
            ForEach(window, id: \.id) { entry in
                let offset = (items.firstIndex { $0.id == entry.id } ?? i) - i
                let isCurrent = entry.id == current.id
                let full = isCurrent && fullScreen
                DetailCardArt(url: artURL(for: entry), lowURL: lowArtURL(for: entry),
                              scrolled: isCurrent && scrolled, dimmed: !isCurrent)
                    .frame(width: full ? Self.screen.width : Self.cardWidth,
                           height: full ? Self.screen.height : Self.cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: full ? 0 : Self.cardRadius, style: .continuous))
                    .offset(x: -CGFloat(offset) * Self.pitch, y: full ? 0 : Self.cardTop)
                    .opacity(fullScreen && !isCurrent ? 0 : 1)
                    .zIndex(isCurrent ? 1 : 0)
            }
        }
        .frame(width: Self.screen.width, height: Self.screen.height, alignment: .top)
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false)
    }

    /// Small version of the main backdrop (often already in memory from the banner / rows),
    /// drawn first so the card never opens black.
    private func lowArtURL(for entry: PlexItem) -> URL? {
        let key = displayKey(entry)
        let path = metadataCache[key]?.backdropPath ?? (entry.isEpisode ? (entry.grandparentArt ?? entry.art) : entry.backdropPath)
        return client.imageURL(path, width: 480, height: 270)
    }

    /// The title's main backdrop: one stable image per title (never cycled), so the artwork
    /// never reloads while idle.
    private func artURL(for entry: PlexItem) -> URL? {
        let key = displayKey(entry)
        let path = metadataCache[key]?.backdropPath ?? (entry.isEpisode ? (entry.grandparentArt ?? entry.art) : entry.backdropPath)
        return client.imageURL(path, width: 1920, height: 1080)
    }

    /// Text block (right) and cast (left) at the bottom of the card.
    private func cardText(_ item: PlexItem) -> some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 16) {
                LogoView(image: logos[item.ratingKey], title: item.title,
                         maxSize: CGSize(width: 680, height: 200), fontSize: 80)
                    .frame(height: 200, alignment: .bottomLeading)

                HStack(spacing: 12) {
                    Text(genreLine(item))
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                    if let rating = item.normalizedContentRating { AgeBadge(text: rating) }
                }

                // What the age rating means, then what this title contains (TMDB).
                if let meaning = RatingGuide.explain(item.normalizedContentRating) {
                    Text(meaning)
                        .font(.system(size: 21))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                if let flags = advisory[item.ratingKey], !flags.isEmpty {
                    ContentFlagsRow(flags: flags)
                }

                if let summary = item.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 680, alignment: .leading)
                }

                HStack(spacing: 10) {
                    Text(techLine(item))
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                    ForEach(badges, id: \.self) { MediaBadge(text: $0) }
                }

                buttons(item).padding(.top, 8)

                // Down from the buttons scrolls to the episodes.
                Color.white.opacity(0.001)
                    .frame(width: 900, height: 8)
                    // Only from the buttons (from browsing, Down goes to Play).
                    .focusable(revealed && !scrolled && !browsing)
                    .focused($heroFocus, equals: .down)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Self.textInset)

            if !item.roles.isEmpty {
                VStack(alignment: .trailing, spacing: 6) {
                    Text("بطولة")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    ForEach(item.roles.prefix(3)) { role in
                        Text(role.tag)
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, Self.textInset)
                .padding(.bottom, 120)
            }
        }
        // Ends above the first episodes row peeking at y≈970.
        .padding(.bottom, Self.screen.height - Self.peekTop + 36)
        .frame(width: Self.screen.width, height: Self.screen.height, alignment: .bottom)
        .shadow(color: .black.opacity(0.35), radius: 10)
    }

    private func buttons(_ item: PlexItem) -> some View {
        HStack(spacing: 20) {
            Button { play(playTarget) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "play.fill")
                    Text(playTitle)
                }
            }
            .nativePillButton()
            .focused($heroFocus, equals: .play)
            // Long press: audio, subtitles, watched mark, play from the start.
            .contextMenu { moreMenu(item) }

            // «قائمتي» of the current profile.
            Button(action: toggleWatchlist) {
                Image(systemName: store.isOnMyList(item.ratingKey) ? "checkmark" : "plus")
            }
            .nativeCircleButton()
            .focused($heroFocus, equals: .watchlist)

            Button {
                setScrolled(true)
                focusEpisodes()
            } label: {
                Image(systemName: item.isShow ? "list.bullet.rectangle" : "rectangle.stack")
            }
            .nativeCircleButton()
            .focused($heroFocus, equals: .episodes)
        }
        .focusSection()
    }

    private func handleHeroFocus(from old: HeroButton?, to new: HeroButton?) {
        switch new {
        case .browse?:
            setBrowsing(true)
        case .play?, .watchlist?, .episodes?:
            setBrowsing(false)
        case .down?:
            setScrolled(true)
            focusEpisodes()
        case .backToTop?:
            setScrolled(false)
            DispatchQueue.main.async { heroFocus = .play }
        case nil:
            break
        }
    }

    /// After scrolling down: focus the episode Play starts; a movie (or a show without
    /// episodes) its first related title, else its first extra.
    private func focusEpisodes() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if let entry = entryEpisode(currentEpisodes) {
                lowerFocus = "ep-\(entry.id)"
            } else if let first = related.uniqued().first {
                lowerFocus = "rel-\(first.id)"
            } else if let first = extras.first {
                lowerFocus = "extra-\(first.id)"
            }
        }
    }

    /// Slides to a sibling of the row (~0.86 s): the text fades out, the cards slide as a
    /// strip, the new text fades in. Stops at the row's ends.
    private func page(_ delta: Int) {
        guard !scrolled, let context, let i = currentIndex, context.items.indices.contains(i + delta) else { return }
        let next = context.items[i + delta]
        withAnimation(.easeOut(duration: 0.2)) { revealed = false }
        returnState.set(rowID: context.rowID, itemID: next.id)
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.55, dampingFraction: 1.0)) { current = next }
        }
    }

    private var zoomSourceID: String {
        if let context { return context.sourceID(for: current) }
        return sourceID ?? current.id
    }

    /// Key of the movie/show whose artwork represents an item.
    private func displayKey(_ item: PlexItem) -> String {
        switch item.type {
        case "episode": return item.grandparentRatingKey ?? item.ratingKey
        case "season": return item.parentRatingKey ?? item.ratingKey
        default: return item.ratingKey
        }
    }

    /// Metadata and artwork of the previous and next titles, so paging never shows a blank card.
    private func preloadNeighbours() async {
        guard let context, let i = currentIndex else { return }
        for j in [i + 1, i - 1] where context.items.indices.contains(j) {
            let neighbour = context.items[j]
            let key = displayKey(neighbour)
            if metadataCache[key] == nil, let meta = try? await client.metadata(key) { metadataCache[key] = meta }
            if let url = artURL(for: neighbour) { _ = await ImageLoader.shared.image(for: url) }
            await loadLogo(key)
        }
    }

    @ViewBuilder
    private func moreMenu(_ item: PlexItem) -> some View {
        if let target = playTarget, target.primaryPart?.id != nil {
            if !target.audioStreams.isEmpty {
                Picker("الصوت", selection: $audioSelection) {
                    ForEach(target.audioStreams) { Text($0.label).tag($0.id) }
                }
            }
            Picker("الترجمة", selection: $subtitleSelection) {
                Text("بدون ترجمة").tag(0)
                ForEach(target.subtitleStreams) { Text($0.label).tag($0.id) }
            }
        }
        // Changes the current profile's data only (nothing is sent to Plex).
        Button(item.isWatched ? "تحديد كغير مُشاهَد" : "تحديد كمُشاهَد",
               systemImage: item.isWatched ? "eye.slash" : "checkmark.circle") {
            Task { await setWatched(item, !item.isWatched) }
        }
        if playTarget != nil {
            Button("التشغيل من البداية", systemImage: "arrow.counterclockwise") {
                play(playTarget, fromBeginning: true)
            }
        }
    }

    // MARK: - Episodes view

    private var currentEpisodes: [PlexItem] {
        (selectedSeasonKey.flatMap { episodesBySeason[$0] } ?? []).uniqued()
    }

    /// Episode focus lands on when entering the row: the one Play starts, else the first unwatched.
    private func entryEpisode(_ episodes: [PlexItem]) -> PlexItem? {
        episodes.first { $0.ratingKey == playTarget?.ratingKey }
            ?? episodes.first { !$0.isWatched }
            ?? episodes.first
    }

    /// The rows under the title: season labels, episodes, «ذات صلة», extras. Always in the
    /// page (the first row peeks at the top state); the whole block scrolls up to the episodes,
    /// and rows further down scroll inside it.
    private func lowerContent(_ item: PlexItem) -> some View {
        VStack(spacing: 0) {
            // Up from the seasons lands here and scrolls back to the top.
            Color.white.opacity(0.001)
                .frame(width: Self.screen.width, height: 8)
                .focusable(scrolled && episodesReady)
                .focused($heroFocus, equals: .backToTop)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Self.rowSpacing) {
                        if item.isShow {
                            // Hidden (and not focusable) at the top state: only the episodes peek.
                            Group {
                                if seasons.isEmpty { Color.clear } else { seasonLabels }
                            }
                            .frame(height: Self.labelsHeight)
                            .opacity(scrolled ? 1 : 0)
                            .disabled(!scrolled)
                            episodesRow(item)
                        }
                        if !related.isEmpty { relatedRow(item) }
                        if !item.isShow && !extras.isEmpty { extrasRow }
                        if !item.roles.isEmpty { castRow(item) }
                        infoBlock(item)
                    }
                    .padding(.bottom, 120)
                    .id(Self.lowerTopID)
                }
                .scrollClipDisabled()
                .onChange(of: scrolled) { _, value in
                    // Back at the top: the episodes row peeks again, whatever row was reached.
                    if !value { withAnimation(Self.scrollCurve(0.75)) { proxy.scrollTo(Self.lowerTopID, anchor: .top) } }
                }
            }
        }
        .frame(width: Self.screen.width,
               height: Self.screen.height - (Self.episodesTop - leadIn), alignment: .top)
    }

    /// «الموسم ١  الموسم ٢»: grey labels, the current / focused one white.
    private var seasonLabels: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 44) {
                ForEach(seasons) { season in
                    Button { selectedSeasonKey = season.ratingKey } label: {
                        Text(seasonTitle(season))
                    }
                    .buttonStyle(SeasonLabelStyle(isSelected: season.ratingKey == selectedSeasonKey))
                    .focused($seasonFocus, equals: season.ratingKey)
                }
            }
            .padding(.horizontal, Self.sideInset)
            .padding(.vertical, 10)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    private func episodesRow(_ item: PlexItem) -> some View {
        let episodes = currentEpisodes
        let entry = entryEpisode(episodes)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(episodes) { episode in
                        Button { play(episode) } label: {
                            EpisodeCard(episode: episode, client: client, contentRating: item.normalizedContentRating)
                        }
                        .buttonStyle(.borderless)
                        .focused($lowerFocus, equals: "ep-\(episode.id)")
                        .contextMenu {
                            let watched = store.state(for: episode.ratingKey)?.watched ?? episode.isWatched
                            Button(watched ? "تحديد كغير مُشاهَد" : "تحديد كمُشاهَد",
                                   systemImage: watched ? "eye.slash" : "checkmark.circle") {
                                Task { await setWatched(episode, !watched) }
                            }
                            Button(store.isOnMyList(item.ratingKey) ? "إزالة من قائمتي" : "إضافة إلى قائمتي",
                                   systemImage: store.isOnMyList(item.ratingKey) ? "minus" : "plus") {
                                store.toggleMyList(item.mediaInfo)
                            }
                            Button("التشغيل من البداية", systemImage: "arrow.counterclockwise") {
                                play(episode, fromBeginning: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, Self.sideInset)
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
            .onAppear {
                // Show the episode you're up to, not the start of the season.
                if let entry { proxy.scrollTo(entry.id, anchor: .center) }
            }
        }
        .focusSection()
        .defaultFocus($lowerFocus, entry.map { "ep-\($0.id)" }, priority: .userInitiated)
        .id(selectedSeasonKey)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.25), value: selectedSeasonKey)
    }

    /// «ذات صلة»: posters with the page's own focus (Down from a movie's buttons lands on the
    /// first one). The header shows once scrolled, so at the top only the posters peek.
    private func relatedRow(_ item: PlexItem) -> some View {
        let items = related.uniqued()
        let context = BrowseContext(rowID: "related-\(item.ratingKey)", items: items)
        return VStack(alignment: .leading, spacing: 0) {
            Text("ذات صلة")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))
                .frame(height: Self.labelsHeight, alignment: .bottom)
                .padding(.horizontal, Self.sideInset)
                .opacity(scrolled ? 1 : 0)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: CardKind.spacing) {
                    ForEach(items) { entry in
                        MediaCardLink(item: entry, client: client,
                                      sourceID: context.sourceID(for: entry), context: context)
                            .focused($lowerFocus, equals: "rel-\(entry.id)")
                    }
                }
                .padding(.horizontal, Self.sideInset)
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }

    /// «طاقم العمل»: round photos with the name and the character (focusable, so the page
    /// can scroll to them).
    private func castRow(_ item: PlexItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("طاقم العمل")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, Self.sideInset)
                .opacity(scrolled ? 1 : 0)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 44) {
                    ForEach(item.roles.prefix(20)) { role in
                        Button {} label: { CastCircle(role: role, client: client) }
                            .buttonStyle(CastButtonStyle())
                    }
                }
                .padding(.horizontal, Self.sideInset)
                .padding(.vertical, 30)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    /// «معلومات»: director, studio, release, runtime, age rating, audio and subtitle
    /// languages, quality (from the file Play starts).
    private func infoBlock(_ item: PlexItem) -> some View {
        let target = playTarget ?? item
        let arabic = Locale(identifier: "ar")
        func languages(_ streams: [PlexStream]) -> String? {
            var seen: [String] = []
            for code in streams.compactMap(\.languageCode) {
                // «spa», «ara», «en»: the full code first, then its first two letters.
                let name = arabic.localizedString(forLanguageCode: code)
                    ?? arabic.localizedString(forLanguageCode: String(code.prefix(2))) ?? code
                if !seen.contains(name) { seen.append(name) }
            }
            return seen.isEmpty ? nil : seen.prefix(4).joined(separator: "، ")
        }
        let facts: [(String, String?)] = [
            ("المخرج", item.directors.isEmpty ? nil : item.directors.prefix(2).map(\.tag).joined(separator: "، ")),
            ("الاستوديو", item.studio),
            ("تاريخ الإصدار", ArabicFormat.date(plex: item.originallyAvailableAt)),
            ("المدة", target.duration.map { ArabicFormat.duration(ms: $0) }),
            ("التصنيف العمري", item.normalizedContentRating.map { rating in
                guard let meaning = RatingGuide.explain(rating) else { return rating }
                // A bare age («14», «+18») is already in the meaning («فوق ١٤ (+١٤)…»).
                if rating.allSatisfy({ $0.isNumber || $0 == "+" }) { return meaning }
                // FSI…PDI keeps «TV-14» a left-to-right island so the colon lands after it in RTL.
                return "\u{2068}\(rating)\u{2069}: \(meaning)"
            }),
            ("المحتوى", advisory[item.ratingKey].flatMap { $0.isEmpty ? nil : $0.map(\.title).joined(separator: "، ") }),
            ("الصوت", languages(target.audioStreams)),
            ("الترجمة", languages(target.subtitleStreams)),
            ("الجودة", badges.isEmpty ? nil : badges.joined(separator: ArabicFormat.separator)),
        ]
        let shown = facts.compactMap { label, value in value.map { (label, $0) } }
        return VStack(alignment: .leading, spacing: 0) {
            Text("معلومات")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, Self.sideInset)
                .opacity(scrolled ? 1 : 0)
            // One focus stop for the whole block, so the page scrolls down to it.
            Button {} label: {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 40, alignment: .topLeading), count: 4),
                          alignment: .leading, spacing: 30) {
                    ForEach(shown, id: \.0) { label, value in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(label)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.55))
                            Text(value)
                                .font(.system(size: 24))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(30)
            }
            .buttonStyle(InfoBlockStyle())
            .padding(.horizontal, Self.sideInset - 30)
            .padding(.vertical, 20)
        }
    }

    private var extrasRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("العروض الدعائية والإضافات")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, Self.sideInset)
                .opacity(scrolled ? 1 : 0)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(extras) { extra in
                        Button { play(extra) } label: {
                            ExtraTile(extra: extra, client: client)
                        }
                        .buttonStyle(.card)
                        .focused($lowerFocus, equals: "extra-\(extra.id)")
                    }
                }
                .padding(.horizontal, Self.sideInset)
                .padding(.top, 34)
                .padding(.bottom, 40)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }

    // MARK: - Data

    private func load() async {
        let key = ratingKey
        let pageItem = current
        let isShowPage = pageItem.isShow || pageItem.isEpisode || pageItem.isSeason
        let preferred = preferredEpisode
        // A show's details, seasons and episodes all at once (not one after another).
        async let showTask: ShowEpisodes? = isShowPage
            ? ShowEpisodes.load(client: client, showKey: key, preferred: preferred) : nil
        guard let detailed = try? await client.metadata(key) else { return }
        guard key == ratingKey else { return } // paged away meanwhile
        metadataCache[key] = detailed
        if item?.ratingKey != detailed.ratingKey {
            // New title: clear the previous one's rows.
            seasons = []
            episodesBySeason = [:]
            selectedSeasonKey = nil
            related = []
            extras = []
            playTarget = nil
            scrolled = false
        }
        item = detailed
        Task { await loadLogo(key) }
        if advisory[key] == nil {
            Task {
                if let flags = await ContentAdvisory.shared.flags(for: detailed) { advisory[key] = flags }
            }
        }

        if detailed.isShow {
            guard let show = await showTask, key == self.ratingKey else { return }
            seasons = show.seasons
            episodesBySeason = show.bySeason
            if playTarget?.ratingKey != show.playTarget?.ratingKey { playTarget = show.playTarget }
            if selectedSeasonKey == nil {
                selectedSeasonKey = initialSeasonKey ?? show.playTarget?.parentRatingKey ?? show.seasons.first?.ratingKey
            }
            // Full details of the episode Play starts (tracks, quality badges).
            if let t = show.playTarget, let full = try? await client.metadata(t.ratingKey), key == self.ratingKey {
                playTarget = full
            }
        } else {
            playTarget = detailed
        }
        syncStreamSelection()
        related = await filter.resolve(await client.related(key), client: client)
        if !detailed.isShow { extras = await client.extras(key) }
    }

    private func loadLogo(_ key: String) async {
        guard logos[key] == nil, let meta = metadataCache[key],
              let url = client.imageURL(meta.clearLogoPath, width: 1360, height: 400, png: true),
              let image = await ImageLoader.shared.image(for: url) else { return }
        logos[key] = image
    }

    /// Shows the profile's track choice for this file in the menu (its own choice, else its
    /// preferred languages, else the file's defaults). Changes are saved for this profile only.
    private func syncStreamSelection() {
        guard let target = playTarget else { return }
        let choice = StreamPreference.resolve(for: target, state: store.state(for: target.ratingKey), profile: store.activeProfile)
        shownStreams = (choice.audio?.id ?? -1, choice.subtitle?.id ?? 0)
        audioSelection = shownStreams.audio
        subtitleSelection = shownStreams.subtitle
    }

    private func saveStreams(audio: Int? = nil, subtitle: Int? = nil) {
        guard let target = playTarget else { return }
        if let audio {
            let stream = target.audioStreams.first { $0.id == audio }
            store.chooseAudio(target.mediaInfo, streamID: audio, language: stream?.languageCode)
        }
        if let subtitle {
            let stream = target.subtitleStreams.first { $0.id == subtitle }
            store.chooseSubtitle(target.mediaInfo, streamID: subtitle == 0 ? nil : subtitle, language: stream?.languageCode)
        }
    }

    /// Marks a movie / episode, or every episode of a show, for the current profile.
    private func setWatched(_ target: PlexItem, _ watched: Bool) async {
        let infos: [MediaInfo]
        if target.isShow {
            infos = await client.allLeaves(target.ratingKey).map(\.mediaInfo)
        } else if target.isSeason {
            infos = ((try? await client.children(target.ratingKey)) ?? []).filter(\.isEpisode).map(\.mediaInfo)
        } else {
            infos = [target.mediaInfo]
        }
        store.setWatched(infos, watched: watched)
        await load()
        NotificationCenter.default.post(name: .plexPlaybackDidEnd, object: nil)
    }

    // MARK: - Actions

    private func play(_ target: PlexItem?, fromBeginning: Bool = false) {
        guard let target else { return }
        Task { await PlaybackManager.shared.play(target, client: client, fromBeginning: fromBeginning) }
    }

    private func toggleWatchlist() {
        guard let item else { return }
        store.toggleMyList(item.mediaInfo)
    }

    // MARK: - Text

    /// «▶ تشغيل الحلقة ١» / «متابعة م١ ح٣» for shows, «تشغيل» / «متابعة» for movies.
    private var playTitle: String {
        guard let item else { return "تشغيل" }
        let inProgress = playTarget.map { store.progress(of: $0) != nil } ?? false
        guard item.isShow, let episode = playTarget else { return inProgress ? "متابعة" : "تشغيل" }
        if inProgress {
            let code = ArabicFormat.shortEpisodeCode(season: episode.parentIndex, episode: episode.index) ?? ""
            return "متابعة " + code
        }
        return "تشغيل الحلقة \(ArabicFormat.digits(episode.index ?? 1))"
    }

    private func genreLine(_ item: PlexItem) -> String {
        let kind = item.isShow ? "مسلسل" : "فيلم"
        return ArabicFormat.joined([kind] + ArabicFormat.genres(item.genres.map(\.tag), limit: 2))
    }

    /// Year · duration (the episode Play starts for a show).
    private func techLine(_ item: PlexItem) -> String {
        var parts: [String] = []
        if let year = item.year { parts.append(ArabicFormat.digits(year)) }
        if let duration = (item.isShow ? playTarget?.duration : item.duration) {
            parts.append(ArabicFormat.duration(ms: duration))
        }
        if item.isShow, let seasons = item.childCount { parts.append(seasonsText(seasons)) }
        return ArabicFormat.joined(parts)
    }

    /// 4K / 1080p, HDR / Dolby Vision, Atmos / 5.1, CC / subtitle languages — from the file Play starts.
    private var badges: [String] {
        guard let target = playTarget ?? item else { return [] }
        var out: [String] = []
        switch target.media.first?.resolutionBadge {
        case "4K": out.append("4K")
        case "1080p": out.append("1080p")
        case "720p": out.append("720p")
        default: break
        }
        switch target.dynamicRangeBadge {
        case "Dolby Vision": out.append("Dolby Vision")
        case "HDR10", "HLG": out.append("HDR")
        default: break
        }
        if target.audioStreams.contains(where: \.isAtmos) {
            out.append("Atmos")
        } else {
            let channels = target.audioStreams.compactMap(\.channels).max() ?? target.media.first?.audioChannels ?? 0
            if channels >= 8 { out.append("7.1") } else if channels >= 6 { out.append("5.1") }
        }
        let languages = Set(target.subtitleStreams.compactMap(\.languageCode).map { $0.prefix(2).uppercased() })
        if !languages.isEmpty {
            out.append(languages.count <= 3 ? "CC " + languages.sorted().joined(separator: " ") : "CC")
        }
        return out
    }

    private func seasonsText(_ n: Int) -> String {
        switch n {
        case 1: return "موسم واحد"
        case 2: return "موسمان"
        case 3...10: return "\(ArabicFormat.digits(n)) مواسم"
        default: return "\(ArabicFormat.digits(n)) موسماً"
        }
    }

    private func seasonTitle(_ season: PlexItem) -> String {
        guard let index = season.index else { return season.title }
        return index == 0 ? "حلقات خاصة" : "الموسم \(ArabicFormat.digits(index))"
    }
}

// MARK: - Card artwork

/// One card's artwork: sharp with a dark gradient at the bottom-right (text side); scrolled
/// to the episodes, the same image progressively blurred and darkened (animated with the scroll).
/// Stable identity: the image views are never re-created, so the backdrop never reloads or
/// flashes dark; a new URL (another title) swaps in place once loaded.
private struct DetailCardArt: View {
    let url: URL?
    /// Low-res backdrop, blurred, under the full one (shown at once when cached).
    let lowURL: URL?
    let scrolled: Bool
    let dimmed: Bool

    var body: some View {
        ZStack {
            Color(white: 0.1)
            RemoteImage(url: lowURL)
                .blur(radius: 12, opaque: true)
            RemoteImage(url: url)
            // Bottom-right (physical): under the text; gone once scrolled.
            LinearGradient(stops: [
                .init(color: .black.opacity(0.75), location: 0),
                .init(color: .black.opacity(0.35), location: 0.4),
                .init(color: .clear, location: 0.7),
            ], startPoint: .bottomTrailing, endPoint: .topLeading)
            .opacity(scrolled ? 0 : 1)
            LinearGradient(stops: [
                .init(color: .clear, location: 0.45),
                .init(color: .black.opacity(0.55), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .opacity(scrolled ? 0 : 1)
            // Scrolled: a pre-blurred copy of the same backdrop fades in over the sharp one.
            // Only its opacity animates (an animated blur radius drops frames to black).
            RemoteImage(url: lowURL)
                .blur(radius: 40, opaque: true)
                .opacity(scrolled ? 1 : 0)
            Color.black.opacity(scrolled ? 0.45 : (dimmed ? 0.35 : 0))
        }
    }
}

// MARK: - Pieces

private struct LogoView: View {
    let image: UIImage?
    let title: String
    let maxSize: CGSize
    let fontSize: CGFloat

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: maxSize.width, maxHeight: maxSize.height)
        } else {
            Text(title)
                .font(.system(size: fontSize, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: maxSize.width * 1.3)
        }
    }
}

private struct AgeBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.7), lineWidth: 1.5))
            .foregroundStyle(.white.opacity(0.85))
    }
}

private struct MediaBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.18)))
            .foregroundStyle(.white.opacity(0.85))
            .environment(\.layoutDirection, .leftToRight)
    }
}

/// Season labels: grey, the selected / focused one white.
private struct SeasonLabelStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View { LabelBody(configuration: configuration, isSelected: isSelected) }

    private struct LabelBody: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.system(size: 30, weight: isFocused || isSelected ? .semibold : .regular))
                .foregroundStyle(isFocused || isSelected ? Color.white : Color.white.opacity(0.5))
                .scaleEffect(isFocused ? 1.08 : 1)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

/// No system focus effect: the card draws its own (`EpisodeCard`).
private struct PlainCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// 16:9 episode still (410×230, radius 14) with its duration, ✓ / progress; below it the
/// episode number, title, a 4–5 line description and the air date. Focused: the still gets
/// the native tvOS highlight; the text gets a frosted panel and moves down a little.
private struct EpisodeCard: View {
    let episode: PlexItem
    let client: PlexServerClient
    let contentRating: String?

    @Environment(\.isFocused) private var isFocused
    @Environment(ProfileStore.self) private var store

    private let size = CGSize(width: 410, height: 230)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Color(white: 0.14)
                RemoteImage(url: client.imageURL(episode.thumb ?? episode.art, width: 820, height: 460))
            }
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottomLeading) {
                // Physical bottom-left (mirrored from Apple's bottom-right).
                HStack(spacing: 6) {
                    if store.state(for: episode.ratingKey)?.watched == true {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    if let duration = episode.duration {
                        Text(ArabicFormat.duration(ms: duration))
                    }
                }
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .padding(12)
                .environment(\.layoutDirection, .leftToRight)
            }
            .artworkStatus(episode, barHeight: 5)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            // Native tvOS highlight on the still: lift, shadow, moving shine, parallax.
            .nativeHighlight(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .zIndex(1)

            VStack(alignment: .leading, spacing: 6) {
                Text("الحلقة \(ArabicFormat.digits(episode.index ?? 0))")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Text(episode.title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let summary = episode.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(5)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 10) {
                    if let date = ArabicFormat.date(plex: episode.originallyAvailableAt) {
                        Text(date)
                            .font(.system(size: 19))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    if let contentRating { AgeBadge(text: contentRating) }
                }
            }
            .padding(14)
            .frame(width: size.width + 20, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(isFocused ? 1 : 0)
            }
            .offset(y: isFocused ? 6 : 0)
            .padding(.horizontal, -10)
        }
        .frame(width: size.width, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: isFocused)
    }
}

private struct ExtraTile: View {
    let extra: PlexItem
    let client: PlexServerClient

    private let size = CGSize(width: 410, height: 230)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color(white: 0.14)
                RemoteImage(url: client.imageURL(extra.thumb ?? extra.art, width: 820, height: 460))
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 8)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(extra.title)
                .font(.system(size: 24, weight: .semibold))
                .lineLimit(1)
                .padding(.top, 8)
            Text(ArabicFormat.joined([kind, extra.duration.map(ArabicFormat.duration(ms:))].compactMap { $0 }))
                .font(.system(size: 19))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(width: size.width, alignment: .leading)
    }

    private var kind: String? {
        switch extra.subtype {
        case "trailer": return "إعلان"
        case "behindTheScenes": return "خلف الكواليس"
        case "deleted": return "مشهد محذوف"
        case "featurette": return "فيلم قصير"
        case "interview": return "مقابلة"
        case "scene": return "مشهد"
        case "short": return "قصير"
        default: return nil
        }
    }
}

/// Round actor photo (initials while it loads or when missing), the name and the character.
private struct CastCircle: View {
    let role: PlexTag
    let client: PlexServerClient

    private let size: CGFloat = 150

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(white: 0.2))
                Text(String(role.tag.prefix(1)))
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                RemoteImage(url: client.imageURL(role.thumb, width: 300, height: 300))
                    .clipShape(Circle())
            }
            .frame(width: size, height: size)
            Text(role.tag)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            if let character = role.role, !character.isEmpty {
                Text(character)
                    .font(.system(size: 19))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .frame(width: size + 40)
    }
}

/// Cast focus: the photo grows a little with a soft shadow (no tile behind it).
private struct CastButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyleBody(configuration: configuration) }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .scaleEffect(isFocused ? 1.1 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 18, y: 10)
                .animation(.easeOut(duration: 0.2), value: isFocused)
        }
    }
}

/// Info block focus: a faint glass panel behind it.
private struct InfoBlockStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyleBody(configuration: configuration) }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.white.opacity(isFocused ? 0.1 : 0))
                }
                .animation(.easeOut(duration: 0.2), value: isFocused)
        }
    }
}

/// «عري • مشاهد دموية • ألفاظ» as small chips, the icon tinted by how sensitive it is.
private struct ContentFlagsRow: View {
    let flags: [ContentFlag]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(flags.prefix(6), id: \.self) { flag in
                HStack(spacing: 6) {
                    Image(systemName: flag.symbol)
                        .foregroundStyle(tint(flag))
                    Text(flag.title)
                        .foregroundStyle(.white.opacity(0.9))
                }
                .font(.system(size: 19, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.14)))
            }
        }
    }

    private func tint(_ flag: ContentFlag) -> Color {
        switch flag {
        case .nudity, .sex: return Color(red: 1, green: 0.42, blue: 0.42)
        case .gore, .violence, .suicide: return Color(red: 1, green: 0.62, blue: 0.3)
        default: return Color(red: 1, green: 0.82, blue: 0.35)
        }
    }
}
