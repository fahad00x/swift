import SwiftUI

/// Details of a movie or show (episodes and seasons open their show with that episode ready).
struct DetailView: View {
    let client: PlexServerClient
    let entry: PlexItem

    @Environment(ProfileStore.self) private var store
    @Environment(\.contentFilter) private var filter

    @State private var item: PlexItem?
    @State private var playTarget: PlexItem?
    @State private var seasons: [PlexItem] = []
    @State private var selectedSeasonKey: String?
    @State private var episodesBySeason: [String: [PlexItem]] = [:]
    @State private var related: [PlexItem] = []
    @State private var extras: [PlexItem] = []
    /// What the title contains (TMDB), nil until known or without a TMDB key.
    @State private var advisory: [ContentFlag]?
    @State private var summaryExpanded = false
    @State private var audioSelection = -1
    @State private var subtitleSelection = -1
    @State private var shownStreams: (audio: Int, subtitle: Int) = (-1, -1)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Set when titles open as a card (iPad in landscape); nil inside the card and in portrait.
    @Environment(\.presentDetail) private var presentDetail
    @Environment(\.dismiss) private var dismiss
    @State private var onScreen = false
    @State private var downloadingSeason: PlexItem?
    @State private var downloadingEpisode: PlexItem?
    /// A show's page: «الحلقات», «المزيد من العناوين المشابهة» or «الممثلين والطاقم».
    @State private var showTab: ShowTab = .episodes

    private enum ShowTab { case episodes, related, cast }

    private var metrics: Metrics { Metrics(sizeClass) }

    /// Movie or show the page describes.
    private var ratingKey: String {
        switch entry.type {
        case "episode": return entry.grandparentRatingKey ?? entry.ratingKey
        case "season": return entry.parentRatingKey ?? entry.ratingKey
        default: return entry.ratingKey
        }
    }

    var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: 20) {
                    header(item)
                    actions(item)
                        .frame(maxWidth: metrics.actionsWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, metrics.margin)
                    if let summary = item.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(summaryExpanded ? nil : 4)
                            .onTapGesture { withAnimation { summaryExpanded.toggle() } }
                            .frame(maxWidth: metrics.isWide ? 900 : .infinity, alignment: .leading)
                            .padding(.horizontal, metrics.margin)
                    }
                    if !item.roles.isEmpty {
                        Text("بطولة: " + ArabicFormat.list(item.roles.prefix(4).map(\.tag)))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, metrics.margin)
                    }

                    if item.isShow {
                        episodesSection(item)
                    } else if !related.isEmpty {
                        ShelfRow(title: "أفلام مشابهة", items: related, client: client)
                    }
                    if !extras.isEmpty { extrasRow }
                    // A show's cast is in its «الممثلين والطاقم» tab.
                    if !item.isShow, !item.roles.isEmpty { castRow(item.roles) }
                    if let target = playTarget ?? (item.isShow ? nil : item), !target.media.isEmpty {
                        fileInfo(target).padding(.horizontal, metrics.margin)
                    }
                }
                .padding(.bottom, 40)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 200)
            }
        }
        .ignoresSafeArea(edges: .top)
        .downloadQualityDialog(isPresented: Binding(get: { downloadingSeason != nil }, set: { if !$0 { downloadingSeason = nil } }),
                               item: playTarget ?? entry, perEpisode: true) { quality in
            if let season = downloadingSeason { Task { await Downloads.shared.download(season, client: client, quality: quality) } }
        }
        .downloadQualityDialog(isPresented: Binding(get: { downloadingEpisode != nil }, set: { if !$0 { downloadingEpisode = nil } }),
                               item: downloadingEpisode ?? entry) { quality in
            if let episode = downloadingEpisode { Task { await Downloads.shared.download(episode, client: client, quality: quality) } }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task(id: entry.id) {
            // What's saved on disk first (instant), then the server.
            await PlexResponseCache.$policy.withValue(.cacheOnly) { await load() }
            await load()
        }
        // Opened full screen in portrait, then turned to landscape: the page becomes the card.
        // Only the page on top (not one covered by another title opened from it).
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onChange(of: presentDetail != nil) { _, cards in
            guard cards, onScreen, let presentDetail else { return }
            dismiss()
            presentDetail(entry)
        }
        .onReceive(NotificationCenter.default.publisher(for: .plexPlaybackDidEnd)) { _ in
            Task { await load() }
        }
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
    }

    // MARK: Header

    private func header(_ item: PlexItem) -> some View {
        ZStack(alignment: .bottom) {
            Color.black
            RemoteImage(url: client.imageURL(item.backdropPath, width: metrics.isWide ? 1920 : 1600,
                                              height: metrics.isWide ? 1080 : 900))
            LinearGradient(stops: [
                .init(color: .clear, location: 0.3),
                .init(color: .black.opacity(0.7), location: 0.7),
                .init(color: .black, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 10) {
                if let eyebrow {
                    Text(eyebrow).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                }
                TitleLogo(item: item, client: client, maxHeight: metrics.logoHeight)
                Text(infoLine(item))
                    .font(metrics.isWide ? .subheadline : .caption)
                    .foregroundStyle(.white.opacity(0.85))
                // What the age rating means, then what this title contains (as on Apple TV).
                if let meaning = RatingGuide.explain(item.normalizedContentRating) {
                    Text(meaning)
                        .font(metrics.isWide ? .footnote : .caption2)
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                if let advisory, !advisory.isEmpty {
                    ContentFlagChips(flags: advisory, large: metrics.isWide)
                }
                if !badges.isEmpty {
                    HStack(spacing: 6) { ForEach(badges, id: \.self) { Badge(text: $0) } }
                }
            }
            .padding(.horizontal, metrics.margin)
            .padding(.bottom, 8)
        }
        .frame(height: metrics.detailHeaderHeight)
        .clipped()
    }

    private func actions(_ item: PlexItem) -> some View {
        HStack(spacing: 12) {
            Button { play(playTarget) } label: {
                Label(playTitle, systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(.white))
                    .foregroundStyle(.black)
            }
            .disabled(playTarget == nil)

            Button { store.toggleMyList(item.mediaInfo) } label: {
                circleIcon(store.isOnMyList(item.ratingKey) ? "checkmark" : "bookmark")
            }
            .accessibilityLabel("قائمتي")

            ratingMenu(item)

            // A movie, or the episode Play starts.
            if let target = item.isShow ? playTarget : item, target.isPlayable {
                DownloadButton(item: target, client: client)
            }

            Menu { moreMenu(item) } label: { circleIcon("ellipsis") }
        }
    }

    /// «قيّم»: the three thumbs; the chosen one shows on the button, a second tap clears it.
    private func ratingMenu(_ item: PlexItem) -> some View {
        let chosen = TitleRatings.rating(of: item, store: store)
        return Menu {
            ForEach(TitleRating.allCases, id: \.self) { rating in
                Button {
                    TitleRatings.toggle(rating, for: item, client: client, store: store)
                } label: {
                    Label(rating.title, systemImage: rating.symbol(filled: chosen == rating))
                }
            }
        } label: {
            Image(systemName: (chosen ?? .like).symbol(filled: chosen != nil))
                .font(.headline)
                .frame(width: 46, height: 46)
                .background(Circle().fill(.white.opacity(0.18)))
                .foregroundStyle(chosen == nil ? Color.white : Theme.accent)
        }
        .accessibilityLabel(chosen.map { "التقييم: \($0.title)" } ?? "قيّم")
    }

    private func circleIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.headline)
            .frame(width: 46, height: 46)
            .background(Circle().fill(.white.opacity(0.18)))
            .foregroundStyle(.white)
    }

    @ViewBuilder
    private func moreMenu(_ item: PlexItem) -> some View {
        if let target = playTarget, target.primaryPart?.id != nil {
            if !target.audioStreams.isEmpty {
                Picker(selection: $audioSelection) {
                    ForEach(target.audioStreams) { Text($0.label).tag($0.id) }
                } label: {
                    Label("الصوت", systemImage: "speaker.wave.2")
                }
                .pickerStyle(.menu)
            }
            Picker(selection: $subtitleSelection) {
                Text("بدون ترجمة").tag(0)
                ForEach(target.subtitleStreams) { Text($0.label).tag($0.id) }
            } label: {
                Label("الترجمة", systemImage: "captions.bubble")
            }
            .pickerStyle(.menu)
        }
        // Changes the current profile's data only (nothing is sent to Plex).
        Button {
            Task { await WatchedActions.setWatched(item, !item.isWatched, client: client, store: store) }
        } label: {
            Label(item.isWatched ? "تحديد كغير مُشاهَد" : "تحديد كمُشاهَد",
                  systemImage: item.isWatched ? "eye.slash" : "checkmark.circle")
        }
        // Only when there is a place to restart from (started, not finished).
        if let target = playTarget, target.progress != nil, !target.isWatched {
            Button { play(target, fromBeginning: true) } label: {
                Label("التشغيل من البداية", systemImage: "arrow.counterclockwise")
            }
        }
        if item.isShow, let season = seasons.first(where: { $0.ratingKey == selectedSeasonKey }) {
            Button {
                downloadingSeason = season
            } label: {
                Label("تحميل \(seasonTitle(season))", systemImage: "arrow.down.circle")
            }
        }
    }

    // MARK: Episodes

    /// «الحلقات | المزيد من العناوين المشابهة | الممثلين والطاقم» tabs. Episodes: the season button
    /// and one episode per row: picture with a play mark and progress, number and title, summary,
    /// length, and a download button on the other side.
    private func episodesSection(_ item: PlexItem) -> some View {
        let hasCast = !item.roles.isEmpty || !item.directors.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 28) {
                    sectionTab("الحلقات", selected: showTab == .episodes) { showTab = .episodes }
                    if !related.isEmpty {
                        sectionTab("المزيد من العناوين المشابهة", selected: showTab == .related) { showTab = .related }
                    }
                    if hasCast {
                        sectionTab("الممثلين والطاقم", selected: showTab == .cast) { showTab = .cast }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            Divider().overlay(Color.white.opacity(0.12))

            if showTab == .related, !related.isEmpty {
                PosterGrid(items: related, client: client).padding(.top, 16)
            } else if showTab == .cast, hasCast {
                castGrid(item).padding(.top, 16)
            } else {
                if seasons.count > 1 {
                    seasonButton.padding(.vertical, 16)
                } else {
                    Color.clear.frame(height: 8)
                }
                let episodes = selectedSeasonKey.flatMap { episodesBySeason[$0] } ?? []
                LazyVStack(spacing: 0) {
                    ForEach(episodes) { episode in
                        episodeRow(episode)
                        if episode.id != episodes.last?.id {
                            Divider().overlay(Color.white.opacity(0.12))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: metrics.isWide ? 820 : .infinity)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, metrics.margin)
    }

    private func sectionTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Capsule().fill(selected ? Theme.accent : .clear).frame(height: 4)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.55))
            }
            .fixedSize()
            .padding(.bottom, 12)
        }
        .buttonStyle(.plain)
    }

    private var seasonButton: some View {
        Menu {
            Picker("الموسم", selection: Binding(get: { selectedSeasonKey ?? "" }, set: { selectedSeasonKey = $0 })) {
                ForEach(seasons) { Text(seasonTitle($0)).tag($0.ratingKey) }
            }
        } label: {
            HStack(spacing: 10) {
                Text(seasons.first { $0.ratingKey == selectedSeasonKey }.map(seasonTitle) ?? "الموسم")
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.14)))
        }
    }

    private func episodeRow(_ episode: PlexItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Button { play(episode) } label: {
                EpisodeRow(episode: episode, client: client, wide: metrics.isWide)
            }
            .buttonStyle(.plain)
            .contextMenu { episodeMenu(episode) }
            downloadButton(episode)
        }
        .padding(.vertical, 14)
    }

    /// Download it, or how it's going / done (tap to remove a finished one).
    @ViewBuilder
    private func downloadButton(_ episode: PlexItem) -> some View {
        let entry = Downloads.shared.entry(episode.ratingKey)
        Button {
            if entry == nil { downloadingEpisode = episode }
        } label: {
            Group {
                switch entry?.state {
                case .none:
                    Image(systemName: "arrow.down.to.line")
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                case .failed:
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.yellow)
                case .waiting, .downloading:
                    ProgressView(value: entry?.fraction ?? 0)
                        .progressViewStyle(.circular)
                        .tint(Theme.accent)
                        .scaleEffect(0.8)
                }
            }
            .font(.title3)
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry == nil ? "تحميل الحلقة" : "التنزيل")
    }

    @ViewBuilder
    private func episodeMenu(_ episode: PlexItem) -> some View {
        Button {
            Task { await WatchedActions.setWatched(episode, !episode.isWatched, client: client, store: store) }
        } label: {
            Label(episode.isWatched ? "تحديد كغير مُشاهَد" : "تحديد كمُشاهَد",
                  systemImage: episode.isWatched ? "eye.slash" : "checkmark.circle")
        }
        if episode.progress != nil, !episode.isWatched {
            Button { play(episode, fromBeginning: true) } label: {
                Label("التشغيل من البداية", systemImage: "arrow.counterclockwise")
            }
        }
        if Downloads.shared.entry(episode.ratingKey) == nil {
            Button {
                downloadingEpisode = episode
            } label: { Label("تحميل الحلقة", systemImage: "arrow.down.circle") }
        } else {
            Button(role: .destructive) { Downloads.shared.delete(episode.ratingKey) } label: {
                Label("حذف التنزيل", systemImage: "trash")
            }
        }
    }

    private var extrasRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("العروض الدعائية والإضافات").font(.title3.weight(.bold)).padding(.horizontal, metrics.margin)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(extras) { extra in
                        Button { play(extra) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack {
                                    Color(white: 0.14)
                                    RemoteImage(url: client.imageURL(extra.thumb ?? extra.art, width: 520, height: 292))
                                    Image(systemName: "play.circle.fill").font(.title).foregroundStyle(.white.opacity(0.85))
                                }
                                .frame(width: 220, height: 124)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                Text(extra.title).font(.caption.weight(.semibold)).lineLimit(1)
                            }
                            .frame(width: 220, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, metrics.margin)
            }
        }
    }

    /// «الممثلين والطاقم»: every actor with their character, then the directors.
    private func castGrid(_ item: PlexItem) -> some View {
        let columns = [GridItem(.adaptive(minimum: 96), spacing: 14, alignment: .top)]
        return VStack(alignment: .leading, spacing: 18) {
            if !item.roles.isEmpty {
                Text("الممثلين").font(.headline)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(item.roles) { person($0, detail: $0.role) }
                }
            }
            if !item.directors.isEmpty {
                Text("الإخراج").font(.headline)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(item.directors) { person($0, detail: nil) }
                }
            }
        }
    }

    private func person(_ tag: PlexTag, detail: String?) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(Color.white.opacity(0.1))
                Text(String(tag.tag.prefix(1))).foregroundStyle(.white.opacity(0.6))
                RemoteImage(url: client.imageURL(tag.thumb, width: 200, height: 200))
            }
            .frame(width: 80, height: 80)
            .clipShape(Circle())
            Text(tag.tag).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
            if let detail, !detail.isEmpty {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func castRow(_ roles: [PlexTag]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("طاقم التمثيل").font(.title3.weight(.bold)).padding(.horizontal, metrics.margin)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(roles.prefix(30)) { role in
                        VStack(spacing: 6) {
                            ZStack {
                                Circle().fill(Color.white.opacity(0.1))
                                Text(String(role.tag.prefix(1))).foregroundStyle(.white.opacity(0.6))
                                RemoteImage(url: client.imageURL(role.thumb, width: 200, height: 200))
                            }
                            .frame(width: 80, height: 80)
                            .clipShape(Circle())
                            Text(role.tag).font(.caption2.weight(.semibold)).lineLimit(1)
                            if let character = role.role, !character.isEmpty {
                                Text(character).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(width: 92)
                    }
                }
                .padding(.horizontal, metrics.margin)
            }
        }
    }

    private func fileInfo(_ target: PlexItem) -> some View {
        let media = target.media.first
        let part = target.primaryPart
        var video: [String] = []
        if let res = media?.resolutionBadge { video.append(res) }
        if let codec = media?.videoCodec { video.append(codec.uppercased()) }
        if let hdr = target.dynamicRangeBadge { video.append(hdr) }
        var file: [String] = []
        if let container = (part?.container ?? media?.container)?.uppercased() { file.append(container) }
        if let size = part?.size { file.append(ArabicFormat.fileSize(Int64(size))) }
        if let bitrate = media?.bitrate { file.append(ArabicFormat.bitrate(kbps: bitrate)) }

        return VStack(alignment: .leading, spacing: 8) {
            Text("معلومات الملف").font(.title3.weight(.bold))
            infoLine("الفيديو", ArabicFormat.joined(video))
            infoLine("الصوت", ArabicFormat.list(target.audioStreams.prefix(4).map(\.label)))
            infoLine("الترجمات", ArabicFormat.list(target.subtitleStreams.prefix(6).map(\.label)))
            infoLine("الملف", ArabicFormat.joined(file))
            if let rating = (item ?? target).normalizedContentRating {
                infoLine("التصنيف", ratingText(rating))
            }
            if let advisory, !advisory.isEmpty {
                infoLine("المحتوى", advisory.map(\.title).joined(separator: "، "))
            }
            if target.isEpisode {
                infoLine("التخطي", target.introSkipSourceText.replacingOccurrences(of: "تخطي المقدمة: ", with: "المقدمة: "))
            }
        }
    }

    /// «R: للكبار (+١٧)…»; a bare age («+18») is already in its meaning.
    private func ratingText(_ rating: String) -> String {
        guard let meaning = RatingGuide.explain(rating) else { return rating }
        if rating.allSatisfy({ $0.isNumber || $0 == "+" }) { return meaning }
        // FSI…PDI keeps «TV-14» a left-to-right island so the colon lands after it in RTL.
        return "\u{2068}\(rating)\u{2069}: \(meaning)"
    }

    private func infoLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
        }
        .font(.footnote)
    }

    // MARK: Data

    private func load() async {
        let key = ratingKey
        let isShowPage = entry.isShow || entry.isEpisode || entry.isSeason
        // A show's details, seasons and episodes all at once (not one after another).
        async let detailTask = client.metadata(key)
        async let showTask: ShowEpisodes? = isShowPage
            ? ShowEpisodes.load(client: client, showKey: key, preferred: entry.isEpisode ? entry : nil) : nil
        guard let detailed = try? await detailTask else { return }
        item = detailed
        if advisory == nil {
            Task { advisory = await ContentAdvisory.shared.flags(for: detailed) }
        }
        if detailed.isShow {
            guard let show = await showTask else { return }
            seasons = show.seasons
            episodesBySeason = show.bySeason
            if playTarget?.ratingKey != show.playTarget?.ratingKey { playTarget = show.playTarget }
            if selectedSeasonKey == nil {
                let initial = entry.isEpisode ? entry.parentRatingKey : (entry.isSeason ? entry.ratingKey : nil)
                selectedSeasonKey = initial ?? show.playTarget?.parentRatingKey ?? show.seasons.first?.ratingKey
            }
            // Full details of the episode Play starts (tracks, quality badges, file info).
            if let t = show.playTarget, let full = try? await client.metadata(t.ratingKey) { playTarget = full }
            // «المزيد من العناوين المشابهة» next to the episodes.
            related = await filter.resolve(await client.related(key), client: client)
        } else {
            playTarget = detailed
            related = await filter.resolve(await client.related(key), client: client)
        }
        syncStreamSelection()
        extras = await client.extras(key)
    }

    /// The profile's track choice for this file, else its preferred languages, else the defaults.
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

    private func play(_ target: PlexItem?, fromBeginning: Bool = false) {
        guard let target else { return }
        Task { await PlaybackManager.shared.play(target, client: client, fromBeginning: fromBeginning) }
    }

    // MARK: Text

    private var playTitle: String {
        guard let item else { return "تشغيل" }
        let inProgress = playTarget?.progress != nil && playTarget?.isWatched == false
        guard item.isShow, let episode = playTarget else { return inProgress ? "استئناف" : "تشغيل" }
        let season = episode.parentIndex.flatMap { $0 > 1 ? $0 : nil }
        let code = ArabicFormat.shortEpisodeCode(season: season, episode: episode.index ?? 1) ?? ""
        return "\(inProgress ? "استئناف" : "تشغيل") \(code)"
    }

    private var eyebrow: String? {
        if let target = playTarget, target.progress != nil, !target.isWatched { return "لم تكمله" }
        return nil
    }

    private func infoLine(_ item: PlexItem) -> String {
        var parts: [String] = [item.isShow ? "مسلسل" : "فيلم"]
        parts += ArabicFormat.genres(item.genres.map(\.tag), limit: 2)
        if let year = item.year { parts.append(ArabicFormat.digits(year)) }
        if item.isShow {
            if let n = item.childCount { parts.append(n == 1 ? "موسم واحد" : "\(ArabicFormat.digits(n)) مواسم") }
        } else if let duration = item.duration {
            parts.append(ArabicFormat.duration(ms: duration))
        }
        if let rating = item.normalizedContentRating { parts.append(rating) }
        return ArabicFormat.joined(parts)
    }

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
        if target.audioStreams.contains(where: \.isAtmos) { out.append("Atmos") }
        if !target.subtitleStreams.isEmpty { out.append("CC") }
        return out
    }

    private func seasonTitle(_ season: PlexItem) -> String {
        guard let index = season.index else { return season.title }
        return index == 0 ? "حلقات خاصة" : "الموسم \(ArabicFormat.digits(index))"
    }
}

private struct EpisodeRow: View {
    let episode: PlexItem
    let client: PlexServerClient
    var wide = false

    /// «٣. اسم الحلقة»; «الحلقة ٣» when the server has no name for it («3», «Episode 3»).
    private var title: String {
        let number = episode.index ?? 0
        let name = episode.title.trimmingCharacters(in: .whitespaces)
        let plain = name.isEmpty || Int(name) == number
            || name.range(of: "^(episode|ep\\.?|e|الحلقة)\\s*\\d+$", options: [.regularExpression, .caseInsensitive]) != nil
        return plain ? "الحلقة \(ArabicFormat.digits(number))" : "\(ArabicFormat.digits(number)). \(ArabicFormat.isolated(name))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Color(white: 0.14)
                RemoteImage(url: client.imageURL(episode.thumb ?? episode.art, width: 420, height: 236))
                Image(systemName: "play.fill")
                    .font(.system(size: wide ? 18 : 14))
                    .foregroundStyle(.white)
                    .frame(width: wide ? 44 : 34, height: wide ? 44 : 34)
                    .background(Circle().fill(.black.opacity(0.45)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
            }
            .frame(width: wide ? 176 : 140, height: wide ? 99 : 79)
            .artworkStatus(episode, triangleFraction: 0.12, barHeight: 3)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let summary = episode.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(wide ? 3 : 2)
                }
                if let duration = episode.duration {
                    Text(ArabicFormat.duration(ms: duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// «عري • مشاهد دموية • ألفاظ» as small chips, the icon tinted by how sensitive it is (as on Apple TV).
private struct ContentFlagChips: View {
    let flags: [ContentFlag]
    let large: Bool

    var body: some View {
        // One centred row under the title, wrapping only when it doesn't fit.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            FlowLayout(spacing: 6) { chips }.fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("المحتوى: " + flags.map(\.title).joined(separator: "، "))
    }

    private var chips: some View {
        ForEach(flags.prefix(6), id: \.self) { flag in
            HStack(spacing: 4) {
                Image(systemName: flag.symbol).foregroundStyle(tint(flag))
                Text(flag.title).foregroundStyle(.white.opacity(0.9))
            }
            .font((large ? Font.caption : .caption2).weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.14)))
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
