import SwiftUI

/// Apple TV app–style details page, mirrored for Arabic.
///
/// State 1, a CARD: on a flat dark-grey background, the title's artwork fills a rounded card
/// (120 pt side margins, 40 pt from the top, running past the bottom edge) with the text on the
/// reading side (right) and the cast on the other. The row's neighbouring titles peek at the
/// sides; Left / Right slide the strip to the next / previous one (next comes from the left).
/// The artwork cycles through 2–3 of the title's backgrounds.
///
/// State 2, EPISODES (Down, or the episodes button): the card grows to the full screen and
/// turns into a blurred colour wash; a small logo at the top, the season labels, the episodes
/// and «ذات صلة». Up from the seasons, or Back, returns to the card.
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

    /// The row item currently shown (movie, show, season or episode).
    @State private var current: PlexItem
    @State private var metadataCache: [String: PlexItem] = [:]
    @State private var logos: [String: UIImage] = [:]
    /// Background artworks of a movie / show (paths), cycled on its card.
    @State private var artworks: [String: [String]] = [:]
    @State private var artIndex = 0

    @State private var item: PlexItem?
    @State private var playTarget: PlexItem?
    @State private var seasons: [PlexItem] = []
    @State private var selectedSeasonKey: String?
    @State private var episodesBySeason: [String: [PlexItem]] = [:]
    @State private var related: [PlexItem] = []
    @State private var extras: [PlexItem] = []
    @State private var revealed = false
    @State private var expanded = false
    /// The episodes view finished appearing (Up to the card works only then, so focus landing
    /// on the top strip while it appears doesn't close it again).
    @State private var episodesReady = false
    @State private var audioSelection = -1
    @State private var subtitleSelection = -1
    /// Selection last loaded from the profile (changes from the menu differ from it).
    @State private var shownStreams: (audio: Int, subtitle: Int) = (-1, -1)

    @FocusState private var heroFocus: HeroButton?
    @FocusState private var seasonFocus: String?
    @FocusState private var lowerFocus: String?

    enum HeroButton: Hashable { case play, watchlist, episodes, edgeStart, edgeEnd, down, backToTop }

    /// Side inset of rows on the full-screen episodes view.
    static let sideInset: CGFloat = CardKind.inset

    // Card geometry (px at 1920×1080).
    private static let screen = CGSize(width: 1920, height: 1080)
    private static let cardMargin: CGFloat = 120
    private static let cardTop: CGFloat = 40
    private static let cardGap: CGFloat = 22
    private static let cardRadius: CGFloat = 36
    private static var cardWidth: CGFloat { screen.width - 2 * cardMargin }
    /// Runs 40 pt past the bottom edge.
    private static var cardHeight: CGFloat { screen.height }
    private static var pitch: CGFloat { cardWidth + cardGap }
    /// Text 40 pt inside the card edge.
    private static var textInset: CGFloat { cardMargin + 40 }

    init(client: PlexServerClient, entry: PlexItem, context: BrowseContext? = nil, sourceID: String? = nil) {
        self.client = client
        self.context = context
        self.sourceID = sourceID
        _current = State(initialValue: entry)
    }

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

            if let item {
                cardText(item)
                    .opacity(revealed && !expanded ? 1 : 0)
                    .offset(y: revealed ? 0 : 24)

                if expanded {
                    episodesView(item)
                        .transition(.asymmetric(
                            insertion: .offset(y: 260).combined(with: .opacity),
                            removal: .offset(y: 200).combined(with: .opacity)))
                }
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
            if let key { selectedSeasonKey = key }
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
            if !cacheMiss { await load() }
            await preloadNeighbours()
        }
        .task(id: "\(current.id)|\(expanded)") { await cycleArtwork() }
        .zoomDestination(id: zoomSourceID,
                         namespace: (context?.rowID.hasPrefix("banner") ?? false) ? nil : zoomNamespace)
        .onReceive(NotificationCenter.default.publisher(for: .plexPlaybackDidEnd)) { _ in
            Task { await load() }
        }
        .defaultFocus($heroFocus, .play)
    }

    /// Back goes one step back: from the episodes to the card, from the card to the poster.
    private func exitAction() {
        if expanded {
            setExpanded(false)
            heroFocus = .play
        } else {
            dismiss()
        }
    }

    /// Card ↔ episodes (~1.15 s with the Apple curve).
    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        episodesReady = false
        withAnimation(.spring(response: 0.75, dampingFraction: 1.0)) { expanded = value }
        if value {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if expanded { episodesReady = true } }
        }
    }

    // MARK: - Cards

    /// The current card and its neighbours as one strip (physical coordinates: in Arabic the
    /// next title sits on the left). On the episodes view the current card fills the screen.
    private var cardStrip: some View {
        let items = context?.items ?? [current]
        let i = currentIndex ?? 0
        let window = items.indices.filter { abs($0 - i) <= 2 }.map { items[$0] }
        return ZStack(alignment: .top) {
            ForEach(window, id: \.id) { entry in
                let offset = (items.firstIndex { $0.id == entry.id } ?? i) - i
                let isCurrent = entry.id == current.id
                let full = isCurrent && expanded
                DetailCardArt(url: artURL(for: entry, isCurrent: isCurrent),
                              isCurrent: isCurrent, expanded: full, dimmed: !isCurrent)
                    .frame(width: full ? Self.screen.width : Self.cardWidth,
                           height: full ? Self.screen.height : Self.cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: full ? 0 : Self.cardRadius, style: .continuous))
                    .offset(x: -CGFloat(offset) * Self.pitch, y: full ? 0 : Self.cardTop)
                    .opacity(expanded && !isCurrent ? 0 : 1)
                    .zIndex(isCurrent ? 1 : 0)
            }
        }
        .frame(width: Self.screen.width, height: Self.screen.height, alignment: .top)
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false)
    }

    /// Current card: one of its artworks (cycled); neighbours: their main backdrop.
    private func artURL(for entry: PlexItem, isCurrent: Bool) -> URL? {
        let key = displayKey(entry)
        var path = metadataCache[key]?.backdropPath ?? (entry.isEpisode ? (entry.grandparentArt ?? entry.art) : entry.backdropPath)
        if isCurrent, let list = artworks[key], !list.isEmpty {
            path = list[artIndex % list.count]
        }
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

                // Down from the buttons opens the episodes view.
                Color.white.opacity(0.001)
                    .frame(width: 900, height: 8)
                    .focusable(revealed && !expanded)
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
        .padding(.bottom, 56)
        .frame(width: Self.screen.width, height: Self.screen.height, alignment: .bottom)
        .shadow(color: .black.opacity(0.35), radius: 10)
    }

    private func buttons(_ item: PlexItem) -> some View {
        HStack(spacing: 20) {
            edgeTarget(.edgeStart, enabled: hasPrevious)

            Button { play(playTarget) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "play.fill")
                    Text(playTitle)
                }
            }
            .buttonStyle(GlassPillButtonStyle())
            .focused($heroFocus, equals: .play)
            // Long press: audio, subtitles, watched mark, play from the start.
            .contextMenu { moreMenu(item) }

            // «قائمتي» of the current profile.
            Button(action: toggleWatchlist) {
                Image(systemName: store.isOnMyList(item.ratingKey) ? "checkmark" : "plus")
            }
            .buttonStyle(GlassCircleButtonStyle())
            .focused($heroFocus, equals: .watchlist)

            Button {
                setExpanded(true)
                focusEpisodes()
            } label: {
                Image(systemName: item.isShow ? "list.bullet.rectangle" : "rectangle.stack")
            }
            .buttonStyle(GlassCircleButtonStyle())
            .focused($heroFocus, equals: .episodes)

            edgeTarget(.edgeEnd, enabled: hasNext)
        }
        .focusSection()
    }

    /// Invisible focus target just past the end of the button row: moving onto it pages to the
    /// previous / next title of the row. Disabled at either end of the row and on the episodes view.
    private func edgeTarget(_ edge: HeroButton, enabled: Bool) -> some View {
        Color.white.opacity(0.001)
            .frame(width: 6, height: 76)
            .focusable(enabled && !expanded && revealed)
            .focused($heroFocus, equals: edge)
    }

    private func handleHeroFocus(from old: HeroButton?, to new: HeroButton?) {
        let buttons: [HeroButton] = [.play, .watchlist, .episodes]
        switch new {
        case .edgeStart?:
            if let old, buttons.contains(old) { page(-1) }
            DispatchQueue.main.async { heroFocus = .play }
        case .edgeEnd?:
            if let old, buttons.contains(old) { page(+1) }
            DispatchQueue.main.async { heroFocus = .episodes }
        case .down?:
            setExpanded(true)
            focusEpisodes()
        case .backToTop?:
            setExpanded(false)
            DispatchQueue.main.async { heroFocus = .play }
        default:
            break
        }
    }

    /// After the episodes view appears: focus the episode Play starts (or the first row).
    private func focusEpisodes() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let episodes = currentEpisodes
            if let entry = entryEpisode(episodes) {
                lowerFocus = "ep-\(entry.id)"
            }
        }
    }

    /// Slides to a sibling of the row (~0.86 s): the text fades out, the cards slide as a
    /// strip, the new text fades in. Stops at the row's ends.
    private func page(_ delta: Int) {
        guard let context, let i = currentIndex, context.items.indices.contains(i + delta) else { return }
        let next = context.items[i + delta]
        withAnimation(.easeOut(duration: 0.2)) { revealed = false }
        returnState.set(rowID: context.rowID, itemID: next.id)
        artIndex = 0
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

    /// Every ~2.5 s the next artwork, with a 0.25 s cross-fade (preloaded first). Not on the
    /// episodes view.
    private func cycleArtwork() async {
        guard !expanded else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let list = artworks[ratingKey], list.count > 1 else { continue }
            let next = (artIndex + 1) % list.count
            if let url = client.imageURL(list[next], width: 1920, height: 1080) {
                _ = await ImageLoader.shared.image(for: url)
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { artIndex = next }
        }
    }

    /// Metadata and artwork of the previous and next titles, so paging never shows a blank card.
    private func preloadNeighbours() async {
        guard let context, let i = currentIndex else { return }
        for j in [i + 1, i - 1] where context.items.indices.contains(j) {
            let neighbour = context.items[j]
            let key = displayKey(neighbour)
            if metadataCache[key] == nil, let meta = try? await client.metadata(key) { metadataCache[key] = meta }
            if let url = artURL(for: neighbour, isCurrent: false) { _ = await ImageLoader.shared.image(for: url) }
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

    private func episodesView(_ item: PlexItem) -> some View {
        VStack(spacing: 0) {
            // Up from the first row lands here and returns to the card.
            Color.white.opacity(0.001)
                .frame(width: Self.screen.width, height: 8)
                .focusable(expanded && episodesReady)
                .focused($heroFocus, equals: .backToTop)

            LogoView(image: logos[item.ratingKey], title: item.title,
                     maxSize: CGSize(width: 200, height: 90), fontSize: 40)
                .frame(height: 90)
                .padding(.top, 40)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 34) {
                    if item.isShow {
                        if !seasons.isEmpty { seasonLabels }
                        episodesRow(item)
                    }
                    if !related.isEmpty {
                        ShelfView(shelf: Shelf(id: "related-\(item.ratingKey)", title: "ذات صلة",
                                               kind: .poster, items: related),
                                  client: client)
                    }
                    if !item.isShow && !extras.isEmpty { extrasRow }
                }
                .padding(.top, 30)
                .padding(.bottom, 120)
            }
            .scrollClipDisabled()
        }
        .frame(width: Self.screen.width, height: Self.screen.height, alignment: .top)
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
                        .buttonStyle(PlainCardStyle())
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

    private var extrasRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("العروض الدعائية والإضافات")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, Self.sideInset)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(extras) { extra in
                        Button { play(extra) } label: {
                            ExtraTile(extra: extra, client: client)
                        }
                        .buttonStyle(PosterButtonStyle())
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
        async let artTask = client.artworks(key)
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
            expanded = false
        }
        item = detailed
        Task { await loadLogo(key) }

        // 2–3 backgrounds to cycle: the title's own first, then the alternatives.
        var arts = await artTask
        if let own = detailed.backdropPath { arts.removeAll { $0 == own }; arts.insert(own, at: 0) }
        artworks[key] = Array(arts.prefix(3))

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

/// One card's artwork: sharp with a dark gradient at the bottom-right (text side) on the card;
/// a heavily blurred colour wash of it on the full-screen episodes view.
private struct DetailCardArt: View {
    let url: URL?
    let isCurrent: Bool
    let expanded: Bool
    let dimmed: Bool

    var body: some View {
        ZStack {
            Color(white: 0.1)
            RemoteImage(url: url)
                .id(url)
                .transition(.opacity)
                .blur(radius: expanded ? 70 : 0, opaque: true)
                .saturation(expanded ? 1.3 : 1)
            Color.black.opacity(expanded ? 0.45 : (dimmed ? 0.35 : 0))
            if !expanded {
                // Bottom-right (physical): under the text.
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.75), location: 0),
                    .init(color: .black.opacity(0.35), location: 0.4),
                    .init(color: .clear, location: 0.7),
                ], startPoint: .bottomTrailing, endPoint: .topLeading)
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(0.55), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: url)
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
/// episode number, title, a 4–5 line description and the air date. Focused: the still scales
/// and lifts with a glass rim and shadow; the text gets a frosted panel and moves down a little.
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
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08), .white.opacity(0.25)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
                    .opacity(isFocused ? 1 : 0)
            }
            .scaleEffect(isFocused ? 1.12 : 1)
            .offset(y: isFocused ? -8 : 0)
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: isFocused ? 24 : 0, y: isFocused ? 16 : 0)
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
