import SwiftUI

// MARK: - Sizes

/// Sizes for the iPhone and for a wide iPad window. A narrow iPad window (Split View,
/// Slide Over) is compact and keeps the iPhone sizes; so does an iPhone in landscape.
struct Metrics {
    let isWide: Bool

    init(_ sizeClass: UserInterfaceSizeClass?) {
        isWide = sizeClass == .regular && UIDevice.current.userInterfaceIdiom == .pad
    }

    var posterWidth: CGFloat { isWide ? 165 : 118 }
    var landscapeWidth: CGFloat { isWide ? 380 : 270 }
    var gridColumn: GridItem {
        isWide ? GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 18, alignment: .top)
               : GridItem(.adaptive(minimum: 105, maximum: 160), spacing: 12, alignment: .top)
    }
    var heroHeight: CGFloat { isWide ? 640 : 560 }
    var detailHeaderHeight: CGFloat { isWide ? 600 : 420 }
    /// Edge padding of rows and text.
    var margin: CGFloat { isWide ? 32 : 16 }
    /// Play / My List buttons: full width on iPhone, a centred group on iPad.
    var actionsWidth: CGFloat { isWide ? 520 : .infinity }
    /// Forms and text pages stay readable instead of spanning the whole iPad.
    var readableWidth: CGFloat { isWide ? 720 : .infinity }
    var logoHeight: CGFloat { isWide ? 130 : 90 }
}

/// iOS Settings' row: a coloured rounded square with a white symbol, and the title.
struct SettingsIcon: View {
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.gradient))
            Text(title)
                .foregroundStyle(.primary)
        }
    }
}

extension View {
    /// Centres the content in a readable column on a wide iPad (forms, sign-in).
    func readableColumn(_ metrics: Metrics) -> some View {
        frame(maxWidth: metrics.readableWidth).frame(maxWidth: .infinity)
    }
}

/// Lays its views out in rows at their own size, wrapping to a new row when full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += isFirst ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

// MARK: - Cards

/// 2:3 poster with title below. Without `width` it fills its grid cell.
struct PosterCard: View {
    let item: PlexItem
    let client: PlexServerClient
    var width: CGFloat?
    var rank: Int?

    @Environment(ShowNews.self) private var news: ShowNews?
    @Environment(\.showsNewsMarks) private var marksNews
    @Environment(ProfileStore.self) private var store

    var body: some View {
        if let rank {
            // The number beside the poster (right in Arabic, like Netflix), not over it:
            // posters from the server have 1080p / rating badges printed in the bottom corners.
            let number = RankNumber(rank: rank, posterWidth: width ?? 118)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: -number.overlap) {
                    number
                    artwork.frame(width: width)
                }
                captions.padding(.leading, number.width - number.overlap)
            }
            .frame(width: width.map { $0 + number.width - number.overlap })
        } else {
            VStack(alignment: .leading, spacing: 6) {
                artwork
                captions
            }
            .frame(width: width)
        }
    }

    @ViewBuilder private var captions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.cardTitle)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var artwork: some View {
        ZStack {
            Color(white: 0.13)
            Image(systemName: item.isShow || item.isEpisode ? "tv" : "film")
                .font(.title)
                .foregroundStyle(.white.opacity(0.2))
            RemoteImage(url: client.posterURL(item))
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .artworkStatus(item)
        .overlay {
            if let cornerText {
                // Physical top-left (an RTL `.topLeading` would be the right).
                ZStack(alignment: .topLeading) {
                    Color.clear
                    CornerBadge(text: cornerText)
                }
                .environment(\.layoutDirection, .leftToRight)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if marksNews, let info = news?.of(item) { NewsMark(info: info, showBar: item.isShow) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Like the Apple TV: a show's unwatched-episode count, or ✓ once watched.
    private var cornerText: String? {
        if item.isShow || item.isSeason {
            guard let leaves = item.leafCount, leaves > 0 else { return nil }
            let remaining = leaves - store.watchedEpisodeCount(under: item.ratingKey)
            return remaining > 0 ? ArabicFormat.digits(remaining) : "✓"
        }
        if item.isPlayable, store.state(for: item.ratingKey)?.watched == true { return "✓" }
        return nil
    }

    private var subtitle: String? {
        if item.isEpisode { return item.episodeCode }
        let genres = ArabicFormat.genres(item.genres.map(\.tag), limit: 2)
        if !genres.isEmpty { return ArabicFormat.list(genres) }
        return item.year.map { ArabicFormat.digits($0) }
    }
}

/// Top 10 number beside a poster: large, dark with a light outline (Netflix), the poster
/// slightly over its edge. Two digits get a wider box so «١٠» is not cut.
private struct RankNumber: View {
    let rank: Int
    let posterWidth: CGFloat

    var width: CGFloat { posterWidth * (rank >= 10 ? 0.85 : 0.55) }
    var overlap: CGFloat { posterWidth * 0.14 }
    private var size: CGFloat { posterWidth * 1.1 }

    var body: some View {
        let text = Text(ArabicFormat.digits(rank))
            .font(.system(size: size, weight: .black, design: .rounded))
        ZStack {
            // Outline: the number offset in eight directions, the fill on top.
            ForEach(0..<8, id: \.self) { i in
                let angle = Double(i) * .pi / 4
                text.foregroundStyle(Color(white: 0.6))
                    .offset(x: cos(angle) * 2.5, y: sin(angle) * 2.5)
            }
            text.foregroundStyle(Color(white: 0.06))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .fixedSize()
        .frame(width: width, alignment: .trailing)
        .offset(y: size * 0.16)
        .accessibilityLabel("المركز \(ArabicFormat.digits(rank))")
    }
}

/// 16:9 Continue Watching card with progress.
struct LandscapeCard: View {
    let item: PlexItem
    let client: PlexServerClient
    var logoPath: String?
    var width: CGFloat = 270

    @Environment(ShowNews.self) private var news: ShowNews?
    @Environment(\.showsNewsMarks) private var marksNews

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Color(white: 0.13)
                RemoteImage(url: client.imageURL(item.landscapePath, width: 640, height: 360))
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                if let url = client.imageURL(logoPath, width: 360, height: 120, png: true) {
                    RemoteImage(url: url, contentMode: .fit)
                        .frame(width: width * 0.5, height: 40, alignment: .bottomLeading)
                        .padding(10)
                        .padding(.bottom, 8)
                }
            }
            .artworkStatus(item, triangleFraction: 0.08)
            .overlay(alignment: .bottom) {
                // Its own bar is drawn already: the badge only.
                if marksNews, let info = news?.of(item), info.title != nil { NewsMark(info: info, showBar: false) }
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(item.cardTitle)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
    }

    private var caption: String {
        let remaining = item.duration.map { max(0, $0 - (item.viewOffset ?? 0)) }
        let time = remaining.map(ArabicFormat.duration(ms:))
        if item.isEpisode {
            // Spelled out («الموسم ٣ • الحلقة ٢ • باقي ٦د»), as on Apple TV: «م٣ • ح٢» read as a code.
            let code = ArabicFormat.episodeCode(season: item.parentIndex, episode: item.index)
            let left = time.map { item.progress != nil ? "باقي \($0)" : $0 }
            // Plain join: both parts are Arabic. `ArabicFormat.joined` isolates each part, which
            // leaves the line no strong letter of its own, so it was laid out left-to-right
            // (the time first when read).
            return [code, left].compactMap { $0 }.joined(separator: ArabicFormat.separator)
        }
        guard let time else { return "" }
        return item.progress != nil ? "باقي \(time)" : time
    }
}

struct Badge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.7), lineWidth: 1))
            .foregroundStyle(.white.opacity(0.9))
    }
}

// MARK: - Rows

enum CardStyle { case poster, landscape }

/// Horizontal row of cards with a title.
struct ShelfRow: View {
    let title: String
    let items: [PlexItem]
    let client: PlexServerClient
    var style: CardStyle = .poster
    var ranked = false
    var logos: [String: String] = [:]

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let metrics = Metrics(sizeClass)
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(metrics.isWide ? .title2.weight(.bold) : .title3.weight(.bold))
                .padding(.horizontal, metrics.margin)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: metrics.isWide ? 18 : 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        NavigationLink(value: item) {
                            switch style {
                            case .poster:
                                PosterCard(item: item, client: client, width: metrics.posterWidth,
                                           rank: ranked ? index + 1 : nil)
                            case .landscape:
                                LandscapeCard(item: item, client: client, logoPath: logos[item.ratingKey],
                                              width: metrics.landscapeWidth)
                            }
                        }
                        .buttonStyle(.plain)
                        .modifier(CardMenu(item: item, client: client, continueRow: style == .landscape))
                    }
                }
                .padding(.horizontal, metrics.margin)
            }
        }
    }
}

/// Poster grid for libraries and search.
struct PosterGrid: View {
    let items: [PlexItem]
    let client: PlexServerClient
    var onItemAppear: (PlexItem) -> Void = { _ in }

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let metrics = Metrics(sizeClass)
        LazyVGrid(columns: [metrics.gridColumn], alignment: .center, spacing: metrics.isWide ? 26 : 18) {
            ForEach(items) { item in
                NavigationLink(value: item) {
                    PosterCard(item: item, client: client)
                }
                .buttonStyle(.plain)
                .itemContextMenu(item, client: client)
                .onAppear { onItemAppear(item) }
            }
        }
        .padding(.horizontal, metrics.margin)
    }
}

/// Small box in the top corner (physical top-left, as on the Apple TV): a count or ✓.
private struct CornerBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(0.68)))
            .padding(6)
            .environment(\.layoutDirection, .leftToRight)
    }
}

// MARK: - New episode / season

/// «قائمتي» and Continue Watching: cards say when a show has a new episode or season.
private struct ShowsNewsMarksKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var showsNewsMarks: Bool {
        get { self[ShowsNewsMarksKey.self] }
        set { self[ShowsNewsMarksKey.self] = newValue }
    }
}

/// «حلقة جديدة» / «موسم جديد» strip; or, mid-episode, the bar of the episode it stopped in.
private struct NewsMark: View {
    let info: ShowNews.Info
    let showBar: Bool

    var body: some View {
        if let title = info.title {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.black)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(ArtworkStatusOverlay.orange)
        } else if showBar, let progress = info.progress {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.black.opacity(0.45))
                    Rectangle().fill(ArtworkStatusOverlay.orange).frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 4)
            .environment(\.layoutDirection, .leftToRight)
        }
    }
}

// MARK: - Continue Watching

/// «إزالة من متابعة المشاهدة»: hidden until watched again, or with its history deleted too.
@MainActor
enum ContinueActions {
    static func key(_ item: PlexItem) -> String {
        item.isEpisode ? (item.grandparentRatingKey ?? item.ratingKey) : item.ratingKey
    }

    static func remove(_ key: String, deletingHistory: Bool, store: ProfileStore) {
        if deletingHistory { store.clearHistory(of: key) } else { store.hideFromContinue(key) }
        NotificationCenter.default.post(name: .plexPlaybackDidEnd, object: nil)
    }

    /// The row as the profile wants it: without what it removed, with every show that has a new
    /// episode or season (the feed looks at the latest ones only), new ones first if chosen.
    static func shown(_ items: [PlexItem], store: ProfileStore, news: ShowNews?, filter: ContentFilter) -> [PlexItem] {
        let there = Set(items.map(key))
        let missing = (news?.info ?? [:]).filter { $0.value.badge != nil && !there.contains($0.key) }
            .sorted { $0.value.newest > $1.value.newest }.compactMap(\.value.episode)
            .filter { filter.allows($0) }
        var out = (items + missing).filter { !store.isHiddenFromContinue(key($0)) }
        if store.activeProfile?.settings?.continueNewFirst == true {
            let new = out.filter { news?.of($0)?.badge != nil }
                .sorted { (news?.of($0)?.newest ?? 0) > (news?.of($1)?.newest ?? 0) }
            out = new + out.filter { news?.of($0)?.badge == nil }
        }
        return out
    }
}

/// Long press: the usual menu, or on Continue Watching «تحديد كمُشاهَد» and «إزالة».
private struct CardMenu: ViewModifier {
    let item: PlexItem
    let client: PlexServerClient
    let continueRow: Bool

    @Environment(ProfileStore.self) private var store
    @State private var asking = false

    func body(content: Content) -> some View {
        if continueRow {
            content
                .contextMenu {
                    Button {
                        Task { await PlaybackManager.shared.play(item, client: client) }
                    } label: { Label("استئناف", systemImage: "play.fill") }
                    Button {
                        Task { await WatchedActions.setWatched(item, true, client: client, store: store) }
                    } label: { Label(item.isEpisode ? "تحديد الحلقة كمُشاهَدة" : "تحديد كمُشاهَد", systemImage: "checkmark.circle") }
                    Button(role: .destructive) { asking = true } label: {
                        Label("إزالة من متابعة المشاهدة", systemImage: "minus.circle")
                    }
                }
                .alert("إزالة «\(ArabicFormat.isolated(item.cardTitle))» من متابعة المشاهدة؟", isPresented: $asking) {
                    Button("إزالة فقط") { ContinueActions.remove(ContinueActions.key(item), deletingHistory: false, store: store) }
                    Button("إزالة وحذف السجل", role: .destructive) {
                        ContinueActions.remove(ContinueActions.key(item), deletingHistory: true, store: store)
                    }
                    Button("إلغاء", role: .cancel) {}
                } message: {
                    Text("«إزالة فقط» تُبقي ما شاهدته، ويرجع إذا شاهدت منه شيئًا. «حذف السجل» يرجّعه كأنك ما شاهدته.")
                }
        } else {
            content.itemContextMenu(item, client: client)
        }
    }
}

// MARK: - Long-press menu

private struct ItemContextMenu: ViewModifier {
    let item: PlexItem
    let client: PlexServerClient
    @Environment(ProfileStore.self) private var store

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                Task { await PlaybackManager.shared.play(item, client: client) }
            } label: {
                Label(item.isShow ? "تشغيل" : (item.progress != nil ? "استئناف" : "تشغيل"), systemImage: "play.fill")
            }
            .disabled(!item.isPlayable)
            Button {
                store.toggleMyList(item.mediaInfo)
            } label: {
                if store.isOnMyList(item.ratingKey) {
                    Label("إزالة من قائمتي", systemImage: "minus.circle")
                } else {
                    Label("إضافة إلى قائمتي", systemImage: "plus.circle")
                }
            }
            Button {
                Task { await WatchedActions.setWatched(item, !item.isWatched, client: client, store: store) }
            } label: {
                Label(item.isWatched ? "تحديد كغير مُشاهَد" : "تحديد كمُشاهَد",
                      systemImage: item.isWatched ? "eye.slash" : "checkmark.circle")
            }
        }
    }
}

extension View {
    func itemContextMenu(_ item: PlexItem, client: PlexServerClient) -> some View {
        modifier(ItemContextMenu(item: item, client: client))
    }
}
