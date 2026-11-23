import SwiftUI

/// Apple TV–style details page for a movie or a show.
///
/// State 1 (on open): full-screen artwork; eyebrow, clear logo, genres, summary, info line,
/// quality badges, Play / + / ⋯ buttons and the cast line; the next row peeks at the bottom.
/// State 2 (after moving down): the artwork stays fixed and blurs/darkens, the logo shrinks
/// to the top centre and stays there; seasons + episodes (or related movies), extras, cast and
/// file info scroll underneath. Moving back up to the buttons (or pressing Menu) returns to state 1.
struct DetailPage: View {
    let client: PlexServerClient
    /// Row the page was opened from; swiping past the buttons pages through it (no wrap-around).
    let context: BrowseContext?
    /// Zoom source of the card that opened the page (when there is no row context).
    let sourceID: String?

    @Environment(\.layoutDirection) private var appDirection
    @Environment(\.detailNamespace) private var zoomNamespace
    @Environment(BrowseReturnState.self) private var returnState
    @Environment(ProfileStore.self) private var store
    @Environment(\.contentFilter) private var filter
    @Environment(\.dismiss) private var dismiss
    @Namespace private var logoNamespace

    /// The row item currently shown (movie, show, season or episode).
    @State private var current: PlexItem
    @State private var step = 1
    @State private var generation = 0
    @State private var backdrops: [String: UIImage] = [:]
    @State private var logos: [String: UIImage] = [:]
    @State private var metadataCache: [String: PlexItem] = [:]

    init(client: PlexServerClient, entry: PlexItem, context: BrowseContext? = nil, sourceID: String? = nil) {
        self.client = client
        self.context = context
        self.sourceID = sourceID
        _current = State(initialValue: entry)
    }

    /// Movie or show the page describes (episodes and seasons open their show).
    private var ratingKey: String {
        switch current.type {
        case "episode": return current.grandparentRatingKey ?? current.ratingKey
        case "season": return current.parentRatingKey ?? current.ratingKey
        default: return current.ratingKey
        }
    }
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
    /// +1 when the incoming artwork should enter from the right edge ("next" reads leftwards in RTL).
    private var entrySign: CGFloat { CGFloat(step) * (appDirection == .rightToLeft ? -1 : 1) }

    @State private var item: PlexItem?
    @State private var playTarget: PlexItem?
    @State private var seasons: [PlexItem] = []
    @State private var selectedSeasonKey: String?
    @State private var episodesBySeason: [String: [PlexItem]] = [:]
    @State private var related: [PlexItem] = []
    @State private var extras: [PlexItem] = []
    @State private var revealed = false
    @State private var expanded = false
    @State private var audioSelection = -1
    @State private var subtitleSelection = -1
    /// Selection last loaded from the profile (changes from the menu differ from it).
    @State private var shownStreams: (audio: Int, subtitle: Int) = (-1, -1)

    @FocusState private var heroFocus: HeroButton?
    @FocusState private var seasonFocus: String?
    @FocusState private var lowerFocus: String?

    enum HeroButton: Hashable { case play, watchlist, more, edgeStart, edgeEnd, backToTop }

    private let width: CGFloat = 1920
    private let height: CGFloat = 1080
    /// Hero height in state 1; the rest of the screen shows the next row ("peek").
    private let heroHeight: CGFloat = 930

    var body: some View {
        ZStack(alignment: .top) {
            DetailBackdrop(key: displayKey(current), image: backdrops[displayKey(current)], url: backdropURL(current),
                           expanded: expanded, entrySign: entrySign, generation: generation)

            if let item {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            hero(item)
                                .frame(width: width, height: heroHeight, alignment: .bottom)
                                .background(GeometryReader { geo in
                                    Color.clear.preference(key: HeroOffsetKey.self,
                                                           value: geo.frame(in: .named("detail")).minY)
                                })
                                .id("hero")

                            Color.clear.frame(height: 1).id("browse")
                            browse(item)
                                .padding(.bottom, 140)
                        }
                    }
                    .coordinateSpace(name: "detail")
                    .scrollClipDisabled()
                    .onPreferenceChange(HeroOffsetKey.self) { minY in
                        if minY < -120, heroFocus == nil { setExpanded(true) }
                    }
                    .onChange(of: expanded) { _, isExpanded in
                        withAnimation(.easeInOut(duration: 0.5)) {
                            if isExpanded {
                                proxy.scrollTo("browse", anchor: UnitPoint(x: 0.5, y: 0.2))
                            } else {
                                proxy.scrollTo("hero", anchor: .top)
                            }
                        }
                    }
                    .onChange(of: heroFocus) { _, focus in
                        if focus != nil {
                            setExpanded(false)
                            withAnimation(.easeInOut(duration: 0.5)) { proxy.scrollTo("hero", anchor: .top) }
                        }
                    }
                }
                .ignoresSafeArea()

                if expanded {
                    LogoView(image: logos[item.ratingKey], title: item.title, maxSize: CGSize(width: 560, height: 150), fontSize: 64)
                        .matchedGeometryEffect(id: "logo", in: logoNamespace)
                        .padding(.top, 54)
                        .frame(maxWidth: .infinity)
                        .allowsHitTesting(false)
                }
            } else {
                LoadingView()
            }
        }
        .frame(width: width, height: height)
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
            guard let key else { return }
            selectedSeasonKey = key
            setExpanded(true)
        }
        .onChange(of: lowerFocus) { _, focus in
            if focus != nil { setExpanded(true) }
        }
        .onChange(of: heroFocus) { old, new in handleEdgeFocus(from: old, to: new) }
        .task(id: current.id) {
            // Artwork alone first (0.4 s on open, until the slide lands when paging),
            // then the text and buttons fade in once the data is ready.
            let start = Date()
            // What's saved on disk first (instant), then the server.
            await PlexResponseCache.$policy.withValue(.cacheOnly) { await load() }
            let cacheMiss = item == nil || item?.ratingKey != ratingKey
            if cacheMiss { await load() }
            let minimum = generation == 0 ? 0.4 : 0.8
            let wait = minimum - Date().timeIntervalSince(start)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) { revealed = true }
            if !cacheMiss { await load() }
            await preloadNeighbours()
        }
        .zoomDestination(id: zoomSourceID, namespace: context?.rowID == "hero" ? nil : zoomNamespace)
        .onReceive(NotificationCenter.default.publisher(for: .plexPlaybackDidEnd)) { _ in
            Task { await load() }
        }
        .defaultFocus($heroFocus, .play)
    }

    /// Menu/Back goes one step back: from seasons/episodes (state 2) to the top of the page,
    /// from the top (state 1) back to the screen the page was opened from.
    private func exitAction() {
        if expanded {
            setExpanded(false)
            heroFocus = .play
        } else {
            dismiss()
        }
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        withAnimation(.easeInOut(duration: 0.5)) { expanded = value }
    }

    // MARK: - State 1

    private func hero(_ item: PlexItem) -> some View {
        HStack(alignment: .bottom, spacing: 60) {
            VStack(alignment: .leading, spacing: 18) {
                if let eyebrow {
                    Text(eyebrow)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }

                if expanded {
                    Color.clear.frame(width: 10, height: 200)
                } else {
                    LogoView(image: logos[item.ratingKey], title: item.title, maxSize: CGSize(width: 760, height: 220), fontSize: 92)
                        .matchedGeometryEffect(id: "logo", in: logoNamespace)
                }

                Text(genreLine(item))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))

                if let summary = item.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 980, alignment: .leading)
                }

                HStack(spacing: 14) {
                    Text(infoLine(item))
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                    ForEach(badges, id: \.self) { Badge(text: $0) }
                }

                buttons(item)
                    .padding(.top, 14)
            }
            .frame(width: 1020, alignment: .leading)

            Spacer(minLength: 0)

            if !item.roles.isEmpty {
                Text("بطولة: " + item.roles.prefix(3).map(\.tag).joined(separator: "، "))
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 560, alignment: .trailing)
                    .padding(.bottom, 20)
            }
        }
        .padding(.horizontal, 110)
        .padding(.bottom, 60)
        .shadow(color: .black.opacity(0.35), radius: 10)
        .opacity(revealed && !expanded ? 1 : 0)
        .offset(y: revealed ? 0 : 36)
    }

    private func buttons(_ item: PlexItem) -> some View {
        HStack(spacing: 22) {
            edgeTarget(.edgeStart, enabled: hasPrevious)

            Button { play(playTarget) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "play.fill")
                    Text(playTitle)
                }
            }
            .buttonStyle(HeroPillButtonStyle())
            .focused($heroFocus, equals: .play)

            // «قائمتي» of the current profile.
            Button(action: toggleWatchlist) {
                Image(systemName: store.isOnMyList(item.ratingKey) ? "checkmark" : "plus")
            }
            .buttonStyle(HeroCircleButtonStyle())
            .focused($heroFocus, equals: .watchlist)

            Menu {
                moreMenu(item)
            } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(HeroCircleButtonStyle())
            .focused($heroFocus, equals: .more)

            edgeTarget(.edgeEnd, enabled: hasNext)
        }
        .focusSection()
    }

    /// Invisible focus target just past the end of the button row: moving onto it pages to the
    /// previous / next item of the row. Disabled at either end of the row and in state 2.
    private func edgeTarget(_ edge: HeroButton, enabled: Bool) -> some View {
        Color.white.opacity(0.001)
            .frame(width: 6, height: 80)
            .focusable(enabled && !expanded && revealed)
            .focused($heroFocus, equals: edge)
    }

    private func handleEdgeFocus(from old: HeroButton?, to new: HeroButton?) {
        let buttons: [HeroButton] = [.play, .watchlist, .more]
        switch new {
        case .edgeStart?:
            if let old, buttons.contains(old) { page(-1) }
            DispatchQueue.main.async { heroFocus = .play }
        case .edgeEnd?:
            if let old, buttons.contains(old) { page(+1) }
            DispatchQueue.main.async { heroFocus = .more }
        case .backToTop?:
            setExpanded(false)
            DispatchQueue.main.async { heroFocus = .play }
        default:
            break
        }
    }

    /// Slides to a sibling of the row: the new artwork slides in from the side while the text
    /// fades out, and the text returns once the artwork has arrived. Stops at the row's ends.
    private func page(_ delta: Int) {
        guard let context, let i = currentIndex, context.items.indices.contains(i + delta) else { return }
        let next = context.items[i + delta]
        step = delta
        withAnimation(.easeOut(duration: 0.2)) { revealed = false }
        returnState.set(rowID: context.rowID, itemID: next.id)
        DispatchQueue.main.async {
            withAnimation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.8)) {
                generation += 1
                current = next
            }
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

    private func backdropURL(_ item: PlexItem) -> URL? {
        let path = metadataCache[displayKey(item)]?.backdropPath ?? (item.isEpisode ? (item.grandparentArt ?? item.art) : item.backdropPath)
        return client.imageURL(path, width: 1920, height: 1080)
    }

    /// Artwork + logo of the previous and next items, so paging never shows a blank frame.
    private func preloadNeighbours() async {
        guard let context, let i = currentIndex else { return }
        for j in [i + 1, i - 1] where context.items.indices.contains(j) {
            let neighbour = context.items[j]
            let key = displayKey(neighbour)
            if metadataCache[key] == nil, let meta = try? await client.metadata(key) { metadataCache[key] = meta }
            await loadArtwork(for: neighbour)
        }
        // Keep only the current item and its neighbours' 4K artwork in memory.
        let keep = Set(([i - 1, i, i + 1].filter { context.items.indices.contains($0) }).map { displayKey(context.items[$0]) })
        backdrops = backdrops.filter { keep.contains($0.key) }
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

    // MARK: - State 2

    @ViewBuilder
    private func browse(_ item: PlexItem) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            // The buttons above are hidden in state 2 (and hidden views can't take focus), so
            // Up from the first row lands on this full-width strip, which goes back to the top.
            Color.white.opacity(0.001)
                .frame(width: width, height: 10)
                .focusable(expanded)
                .focused($heroFocus, equals: .backToTop)

            if item.isShow {
                if seasons.count > 1 { seasonChips }
                episodesRow
            } else if !related.isEmpty {
                ShelfView(shelf: Shelf(id: "related-\(item.ratingKey)", title: "أفلام مشابهة",
                                       kind: .poster, items: related),
                          client: client)
            }

            if !extras.isEmpty { extrasRow }
            if !item.roles.isEmpty { castRow(item.roles) }
            if let target = playTarget ?? (item.isShow ? nil : item), !target.media.isEmpty {
                fileInfo(target)
            }
        }
        .opacity(revealed ? 1 : 0)
    }

    private var seasonChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(seasons) { season in
                    Button { selectedSeasonKey = season.ratingKey } label: {
                        Text(seasonTitle(season))
                    }
                    .buttonStyle(ChipButtonStyle(isSelected: season.ratingKey == selectedSeasonKey))
                    .focused($seasonFocus, equals: season.ratingKey)
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    /// Episode focus lands on when entering the row: the one Play starts, else the first unwatched.
    private func entryEpisode(_ episodes: [PlexItem]) -> PlexItem? {
        episodes.first { $0.ratingKey == playTarget?.ratingKey }
            ?? episodes.first { !$0.isWatched }
            ?? episodes.first
    }

    private var episodesRow: some View {
        let episodes = (selectedSeasonKey.flatMap { episodesBySeason[$0] } ?? []).uniqued()
        let entry = entryEpisode(episodes)
        return ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 48) {
                ForEach(episodes) { episode in
                    Button { play(episode) } label: {
                        EpisodeTile(episode: episode, client: client)
                    }
                    .buttonStyle(.borderless)
                    .focused($lowerFocus, equals: "ep-\(episode.id)")
                    .contextMenu {
                        Button(episode.isWatched ? "تحديد كغير مُشاهَد" : "تحديد كمُشاهَد",
                               systemImage: episode.isWatched ? "eye.slash" : "checkmark.circle") {
                            Task { await setWatched(episode, !episode.isWatched) }
                        }
                        Button("التشغيل من البداية", systemImage: "arrow.counterclockwise") {
                            play(episode, fromBeginning: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.top, 30)
            .padding(.bottom, 40)
        }
        .scrollClipDisabled()
        .onAppear {
            // Show the episode you're up to (e.g. E7), not the start of the season.
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
            SectionTitle("العروض الدعائية والإضافات")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 48) {
                    ForEach(extras) { extra in
                        Button { play(extra) } label: {
                            ExtraTile(extra: extra, client: client)
                        }
                        .buttonStyle(.borderless)
                        .focused($lowerFocus, equals: "extra-\(extra.id)")
                    }
                }
                .padding(.horizontal, 80)
                .padding(.top, 30)
                .padding(.bottom, 40)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }

    private func castRow(_ roles: [PlexTag]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle("طاقم التمثيل")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(roles.prefix(30)) { role in
                        Button {} label: {
                            CastTile(role: role, client: client)
                        }
                        .buttonStyle(.borderless)
                        .focused($lowerFocus, equals: "cast-\(role.id)")
                    }
                }
                .padding(.horizontal, 80)
                .padding(.top, 30)
                .padding(.bottom, 40)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }

    private func fileInfo(_ target: PlexItem) -> some View {
        let media = target.media.first
        let part = target.primaryPart
        var video: [String] = []
        if let res = media?.resolutionBadge { video.append(res) }
        if let codec = media?.videoCodec { video.append(codec.uppercased()) }
        if let hdr = target.dynamicRangeBadge { video.append(hdr) }
        if let fps = target.videoStream?.frameRate { video.append(String(format: "%.3g fps", fps)) }
        let audio = target.audioStreams.map(\.label)
        let subs = target.subtitleStreams.map(\.label)
        var file: [String] = []
        if let container = (part?.container ?? media?.container)?.uppercased() { file.append(container) }
        if let size = part?.size { file.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        if let bitrate = media?.bitrate { file.append(String(format: "%.1f Mbps", Double(bitrate) / 1000)) }

        return VStack(alignment: .leading, spacing: 0) {
            SectionTitle("معلومات الملف")
            HStack(alignment: .top, spacing: 30) {
                InfoTile(title: "الفيديو", lines: video.isEmpty ? ["—"] : [video.joined(separator: " · ")])
                InfoTile(title: "الصوت", lines: audio.isEmpty ? ["—"] : Array(audio.prefix(5)))
                InfoTile(title: "الترجمات", lines: subs.isEmpty ? ["لا توجد"] : Array(subs.prefix(5)))
                InfoTile(title: "الملف", lines: (file.isEmpty ? ["—"] : file) + (target.isEpisode ? [target.introSkipSourceText] : []))
            }
            .padding(.horizontal, 80)
            .padding(.top, 26)
            .focusSection()
        }
    }

    // MARK: - Data

    private func load() async {
        let key = ratingKey
        let pageItem = current
        Task { await loadArtwork(for: pageItem) }
        // A show's details, seasons and episodes all at once (not one after another).
        let isShowPage = pageItem.isShow || pageItem.isEpisode || pageItem.isSeason
        let preferred = preferredEpisode
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
            expanded = false
        }
        item = detailed
        Task { await loadArtwork(for: pageItem) }

        if detailed.isShow {
            // Seasons + every episode in two parallel requests; shown before the file details.
            guard let show = await showTask, key == self.ratingKey else { return }
            seasons = show.seasons
            episodesBySeason = show.bySeason
            if playTarget?.ratingKey != show.playTarget?.ratingKey { playTarget = show.playTarget }
            if selectedSeasonKey == nil {
                selectedSeasonKey = initialSeasonKey ?? show.playTarget?.parentRatingKey ?? show.seasons.first?.ratingKey
            }
            // Full details of the episode Play starts (tracks, quality badges, file info).
            if let t = show.playTarget, let full = try? await client.metadata(t.ratingKey), key == self.ratingKey {
                playTarget = full
            }
        } else {
            playTarget = detailed
            related = await filter.resolve(await client.related(ratingKey), client: client)
        }

        syncStreamSelection()
        extras = await client.extras(ratingKey)
    }

    private func loadArtwork(for item: PlexItem) async {
        let key = displayKey(item)
        if backdrops[key] == nil, let url = backdropURL(item), let image = await ImageLoader.shared.image(for: url) {
            backdrops[key] = image
        }
        if logos[key] == nil, let meta = metadataCache[key],
           let url = client.imageURL(meta.clearLogoPath, width: 1520, height: 440, png: true),
           let image = await ImageLoader.shared.image(for: url) {
            logos[key] = image
        }
    }

    /// Shows the profile's track choice for this file in the ⋯ menu (its own choice, else its
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

    private var playTitle: String {
        guard let item else { return "تشغيل" }
        let inProgress = playTarget?.progress != nil && playTarget?.isWatched == false
        guard item.isShow, let episode = playTarget else { return inProgress ? "استئناف" : "تشغيل" }
        if inProgress { return "استئناف \(episodeShortCode(episode))" }
        if (item.viewedLeafCount ?? 0) == 0, (episode.parentIndex ?? 1) <= 1, (episode.index ?? 1) <= 1 {
            return "تشغيل الحلقة الأولى"
        }
        return "تشغيل \(episodeShortCode(episode))"
    }

    /// "ح٥", or "م٢، ح٥" past the first season.
    private func episodeShortCode(_ episode: PlexItem) -> String {
        let e = "ح\(ArabicFormat.digits(episode.index ?? 1))"
        if let s = episode.parentIndex, s > 1 { return "م\(ArabicFormat.digits(s))، \(e)" }
        return e
    }

    private var eyebrow: String? {
        guard let item else { return nil }
        let now = Date().timeIntervalSince1970
        func recent(_ addedAt: Int?, days: Double) -> Bool {
            guard let addedAt else { return false }
            return now - Double(addedAt) < days * 86_400
        }
        if let target = playTarget, target.progress != nil, !target.isWatched { return "لم تكمله" }
        if item.isShow, let target = playTarget, !target.isWatched, recent(target.addedAt, days: 14) { return "حلقة جديدة" }
        if recent(item.addedAt, days: 30) { return "أضيف مؤخراً" }
        return nil
    }

    private func genreLine(_ item: PlexItem) -> String {
        let kind = item.isShow ? "مسلسل" : "فيلم"
        let genres = item.genres.prefix(3).map { ArabicFormat.genre($0.tag) }
        return genres.isEmpty ? kind : "\(kind) · \(genres.joined(separator: "، "))"
    }

    private func infoLine(_ item: PlexItem) -> String {
        var parts: [String] = []
        if let year = item.year { parts.append(ArabicFormat.digits(year)) }
        if item.isShow {
            if let seasons = item.childCount { parts.append(seasonsText(seasons)) }
        } else if let duration = item.duration {
            parts.append(ArabicFormat.duration(ms: duration))
        }
        if let rating = item.contentRating, !rating.isEmpty { parts.append(rating) }
        return parts.joined(separator: " · ")
    }

    /// 4K / HD, HDR or Dolby Vision, Atmos, 5.1 / 7.1, CC — from the file that Play starts.
    private var badges: [String] {
        guard let target = playTarget ?? item else { return [] }
        var out: [String] = []
        switch target.media.first?.resolutionBadge {
        case "4K": out.append("4K")
        case "1080p", "720p": out.append("HD")
        default: break
        }
        switch target.dynamicRangeBadge {
        case "Dolby Vision": out.append("Dolby Vision")
        case "HDR10", "HLG": out.append("HDR")
        default: break
        }
        if target.audioStreams.contains(where: \.isAtmos) { out.append("Dolby Atmos") }
        let channels = target.audioStreams.compactMap(\.channels).max() ?? target.media.first?.audioChannels ?? 0
        if channels >= 8 { out.append("7.1") } else if channels >= 6 { out.append("5.1") }
        if !target.subtitleStreams.isEmpty { out.append("CC") }
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

private struct BackdropSlide: ViewModifier {
    var x: CGFloat
    var opacity: Double

    func body(content: Content) -> some View {
        content.offset(x: x).opacity(opacity)
    }
}

private struct HeroOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Background

/// Fixed full-screen artwork: sharp with text scrims in state 1; blurred and darker in state 2.
private struct DetailBackdrop: View {
    /// Identity of the artwork; a new key slides in from the side (paging).
    let key: String
    let image: UIImage?
    let url: URL?
    let expanded: Bool
    /// +1: the new artwork enters from the right edge, -1: from the left.
    let entrySign: CGFloat
    let generation: Int

    @Environment(\.layoutDirection) private var appDirection

    var body: some View {
        ZStack {
            Color.black
            ZStack {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        RemoteImage(url: url)
                    }
                }
                .frame(width: 1920, height: 1080)
                .clipped()
                .id(key)
                .transition(.asymmetric(
                    insertion: .modifier(active: BackdropSlide(x: entrySign * 1920, opacity: 1),
                                         identity: BackdropSlide(x: 0, opacity: 1)),
                    removal: .modifier(active: BackdropSlide(x: -entrySign * 1920 * 0.35, opacity: 0.5),
                                       identity: BackdropSlide(x: 0, opacity: 1))))
                .zIndex(Double(generation))
            }
            .frame(width: 1920, height: 1080)
            .blur(radius: expanded ? 60 : 0, opaque: true)
            .scaleEffect(expanded ? 1.06 : 1)
            .clipped()

            Color.black.opacity(expanded ? 0.5 : 0)

            // Text side + bottom scrims (physical sides; see environment below).
            LinearGradient(stops: [
                .init(color: .black.opacity(0.85), location: 0),
                .init(color: .black.opacity(0.55), location: 0.35),
                .init(color: .clear, location: 0.72),
            ], startPoint: appDirection == .rightToLeft ? .trailing : .leading,
               endPoint: appDirection == .rightToLeft ? .leading : .trailing)
                .opacity(expanded ? 0.4 : 1)
            LinearGradient(stops: [
                .init(color: .clear, location: 0.4),
                .init(color: .black.opacity(0.6), location: 0.7),
                .init(color: .black.opacity(0.95), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: 1920, height: 1080)
        .environment(\.layoutDirection, .leftToRight)
        .animation(.easeInOut(duration: 0.55), value: expanded)
        .ignoresSafeArea()
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
                .multilineTextAlignment(.center)
                .frame(maxWidth: maxSize.width * 1.3)
        }
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white.opacity(0.78))
            .padding(.horizontal, 80)
    }
}

/// 16:9 episode still; the still lifts with the native highlight effect, the text stays below.
private struct EpisodeTile: View {
    let episode: PlexItem
    let client: PlexServerClient

    private let size = CGSize(width: 440, height: 248)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottom) {
                Color(white: 0.14)
                RemoteImage(url: client.imageURL(episode.thumb ?? episode.art, width: 880, height: 496))
            }
            .frame(width: size.width, height: size.height)
            .artworkStatus(episode, triangleFraction: 0.08, barHeight: 6)
            .clipShape(RoundedRectangle(cornerRadius: CardKind.cornerRadius, style: .continuous))
            .hoverEffect(.highlight)

            Text("الحلقة \(ArabicFormat.digits(episode.index ?? 0))")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 8)
            Text(episode.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            if let summary = episode.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            Text(details)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(width: size.width, alignment: .leading)
    }

    private var details: String {
        var parts: [String] = []
        if let date = episode.originallyAvailableAt.flatMap(Self.parseDate) {
            parts.append(date.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "ar"))))
        }
        if let duration = episode.duration { parts.append(ArabicFormat.duration(ms: duration)) }
        return parts.joined(separator: " · ")
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }
}

private struct ExtraTile: View {
    let extra: PlexItem
    let client: PlexServerClient

    private let size = CGSize(width: 440, height: 248)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color(white: 0.14)
                RemoteImage(url: client.imageURL(extra.thumb ?? extra.art, width: 880, height: 496))
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 8)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: CardKind.cornerRadius, style: .continuous))
            .hoverEffect(.highlight)

            Text(extra.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .padding(.top, 8)
            Text([kind, extra.duration.map(ArabicFormat.duration(ms:))].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2)
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

private struct CastTile: View {
    let role: PlexTag
    let client: PlexServerClient

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.white.opacity(0.1))
                Text(String(role.tag.prefix(1))).font(.title).foregroundStyle(.white.opacity(0.6))
                RemoteImage(url: client.imageURL(role.thumb, width: 320, height: 320))
            }
            .frame(width: 170, height: 170)
            .clipShape(Circle())
            .hoverEffect(.highlight)

            Text(role.tag)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.top, 8)
            if let character = role.role, !character.isEmpty {
                Text(character)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .frame(width: 200)
    }
}

/// Focusable so the remote can reach (and scroll to) the file info at the bottom.
private struct InfoTile: View {
    let title: String
    let lines: [String]

    var body: some View {
        InfoTileBody(title: title, lines: lines)
            .focusable()
    }
}

private struct InfoTileBody: View {
    let title: String
    let lines: [String]
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .lineLimit(2)
            }
        }
        .padding(24)
        .frame(width: 400, height: 260, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(isFocused ? 0.2 : 0.07))
        )
        .scaleEffect(isFocused ? 1.04 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
