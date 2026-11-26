import SwiftUI

// Apple TV media cards in the style of Apple's TV app: artwork only (no text under posters),
// a few status overlays, and a lift-and-glow focus (scale, soft shadow, light glass rim).

// MARK: - Landscape (Continue Watching)

/// 16:9 artwork: the episode's own still (or the movie's art), with a clear orange progress
/// bar inside its bottom edge (like Plex). Title and episode are drawn under it by `LandscapeCaption`.
struct LandscapeCard: View {
    let item: PlexItem
    let client: PlexServerClient

    @Environment(ProfileStore.self) private var store

    var body: some View {
        let size = CardKind.landscape.size
        ZStack {
            Color(white: 0.13)
            Image(systemName: item.isEpisode ? "tv" : "film")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.2))
            RemoteImage(url: client.imageURL(item.landscapePath, width: Int(size.width * 2), height: Int(size.height * 2)))
            if let progress = store.progress(of: item) {
                // Fills left → right like the player's timeline (also in Arabic).
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 40)
                        .overlay(alignment: .bottom) {
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.3))
                                Capsule()
                                    .fill(ArtworkStatusOverlay.orange)
                                    .frame(width: (size.width - 28) * progress)
                            }
                            .frame(width: size.width - 28, height: 7)
                            .padding(.bottom, 12)
                        }
                }
                .environment(\.layoutDirection, .leftToRight)
                .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: CardKind.cornerRadius, style: .continuous))
    }
}

/// Under a Continue Watching card: the title, and «الموسم ١  •  الحلقة ٧» (episodes) or the
/// time left (movies).
private struct LandscapeCaption: View {
    let item: PlexItem

    @Environment(ProfileStore.self) private var store

    var body: some View {
        let width = CardKind.landscape.size.width
        VStack(alignment: .leading, spacing: 6) {
            Text(item.cardTitle)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private var detail: String? {
        if item.isEpisode {
            return ArabicFormat.episodeCode(season: item.parentIndex, episode: item.index)
        }
        let remaining = item.duration.map { max(0, $0 - (store.state(for: item.ratingKey)?.offsetMs ?? item.viewOffset ?? 0)) }
        guard let remaining, remaining > 0 else { return item.year.map { ArabicFormat.digits($0) } }
        return "باقي " + ArabicFormat.duration(ms: remaining)
    }
}

// MARK: - Poster

/// «قائمتي» and Continue Watching: posters say when the show has a new episode or season.
private struct MarksNewEpisodesKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var marksNewEpisodes: Bool {
        get { self[MarksNewEpisodesKey.self] }
        set { self[MarksNewEpisodesKey.self] = newValue }
    }
}

/// Artwork only (the title is drawn under the card by `MediaCardLink`), with the status
/// overlays: unwatched triangle + progress bar, unwatched episode count, quality and the
/// «يُعرض» ribbon (no rating: posters often have it printed on them already) for shows with a recent episode.
struct PosterCard: View {
    let item: PlexItem
    let client: PlexServerClient
    /// 1-based position in a Top 10 row.
    var rank: Int?
    var logoPath: String?
    var size: CGSize = CardKind.poster.size

    @Environment(ProfileStore.self) private var store
    @Environment(ShowNews.self) private var news: ShowNews?
    @Environment(\.marksNewEpisodes) private var marksNews
    /// Focus of the enclosing (native card) button.
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        ZStack {
            Color(white: 0.13)
            Image(systemName: item.isShow || item.isEpisode ? "tv" : "film")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.2))
            RemoteImage(url: size == CardKind.poster.size
                        ? client.posterURL(item)
                        : client.imageURL(item.posterPath, width: Int(size.width * 2), height: Int(size.height * 2)))
            PosterBadges(corner: cornerText)
            if marksNews, let info = news?.of(item) {
                if let title = info.title {
                    Text(title)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(ArtworkStatusOverlay.orange)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                } else if item.isShow, let progress = info.progress {
                    // The episode it stopped in (an episode's own poster has its bar already).
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.black.opacity(0.45))
                        Rectangle().fill(ArtworkStatusOverlay.orange).frame(width: size.width * progress)
                    }
                    .frame(height: 5)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .environment(\.layoutDirection, .leftToRight)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: isFocused)
        .frame(width: size.width, height: size.height)
        // Thin progress bar when started (no unwatched triangle on Apple TV).
        .artworkStatus(item, barHeight: 5)
        .clipShape(RoundedRectangle(cornerRadius: CardKind.cornerRadius, style: .continuous))
    }

    /// «مسلسل • كوميديا» / «فيلم • أكشن»; the season and episode for an episode.
    static func focusCaption(_ item: PlexItem) -> String? {
        if item.isEpisode { return ArabicFormat.episodeCode(season: item.parentIndex, episode: item.index) }
        guard item.isShow || item.type == "movie" else { return nil }
        let kind = item.isShow ? "مسلسل" : "فيلم"
        return ArabicFormat.joined([kind] + ArabicFormat.genres(item.genres.map(\.tag), limit: 1))
    }

    /// Unwatched-episode count, or ✓ when fully watched.
    private var cornerText: String? {
        if item.isShow || item.isSeason {
            guard let leaves = item.leafCount, leaves > 0 else { return nil }
            let remaining = leaves - store.watchedEpisodeCount(under: item.ratingKey)
            return remaining > 0 ? ArabicFormat.digits(remaining) : "✓"
        }
        if item.isPlayable, store.state(for: item.ratingKey)?.watched == true { return "✓" }
        return nil
    }
}

/// Small box in the top corner (physical top-left, mirrored from Apple's top-right for
/// Arabic): unwatched-episode count or ✓. Resolution and ratings live on the banner and the
/// details page, not on posters.
private struct PosterBadges: View {
    let corner: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let corner {
                Text(corner)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 30, minHeight: 30)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.68)))
                    .padding(10)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false)
    }
}

/// Title and year / episode under a poster.
private struct CardCaption: View {
    let item: PlexItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.cardTitle)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
    }

    private var detail: String? {
        if item.isEpisode {
            return ArabicFormat.episodeCode(season: item.parentIndex, episode: item.index)
        }
        if item.isSeason { return item.parentTitle }
        return item.year.map { ArabicFormat.digits($0) }
    }
}

/// Focus: lift and glow, like Apple's TV app.
struct PosterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.pageContentFocused) private var pageContentFocused

        var body: some View {
            // Apple TV app focus: scale + lift + soft shadow + a light glass rim. No border.
            configuration.label
                .overlay {
                    RoundedRectangle(cornerRadius: CardKind.cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08), .white.opacity(0.25)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1.5)
                        .opacity(isFocused ? 1 : 0)
                }
                .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.09 : 1))
                .offset(y: isFocused ? -6 : 0)
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: isFocused ? 24 : 0, y: isFocused ? 18 : 0)
                .animation(.spring(response: 0.3, dampingFraction: 0.9), value: isFocused)
                // Under a banner: focus in the rows moves the page up.
                .onChange(of: isFocused) { _, focused in if focused { pageContentFocused?() } }
        }
    }
}

/// Clear logo when available, otherwise the title text.
private struct CardTitle: View {
    let title: String
    let logoPath: String?
    let client: PlexServerClient
    let logoSize: CGSize
    let font: Font

    var body: some View {
        if let url = client.imageURL(logoPath, width: Int(logoSize.width * 2), height: Int(logoSize.height * 2), png: true) {
            LogoImage(url: url, title: title, font: font)
                .frame(maxWidth: logoSize.width, maxHeight: logoSize.height, alignment: .bottomLeading)
        } else {
            titleText
        }
    }

    private var titleText: some View {
        Text(title)
            .font(font)
            .foregroundStyle(.white)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .shadow(color: .black.opacity(0.5), radius: 6)
    }
}

private struct LogoImage: View {
    let url: URL
    let title: String
    let font: Font
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed {
                Text(title).font(font).foregroundStyle(.white).lineLimit(2)
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            image = await ImageLoader.shared.image(for: url)
            failed = image == nil
        }
    }
}

// MARK: - Navigation + focus

/// A card that opens the item's detail page. Uses the native tvOS card focus effect.
struct MediaCardLink: View {
    let item: PlexItem
    var kind: CardKind = .poster
    let client: PlexServerClient
    var rank: Int?
    var logoPath: String?
    var posterSize: CGSize = CardKind.poster.size
    /// Unique per card on screen (row + item) for the zoom transition.
    var sourceID: String?
    /// Row this card belongs to (lets the details page page through it).
    var context: BrowseContext?

    @Environment(BackdropState.self) private var backdrop
    @Environment(\.pageContentFocused) private var pageContentFocused
    @State private var cardFocused = false
    @Environment(\.detailNamespace) private var namespace

    private var zoomID: String { sourceID ?? item.id }

    /// Collections and playlists open a listing, everything else the details page.
    private var isContainer: Bool { item.type == "collection" || item.type == "playlist" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if isContainer {
                    NavigationLink(value: BrowseRoute(title: item.title, path: containerPath)) { card }
                } else {
                    NavigationLink(value: DetailRoute(item: item, sourceID: zoomID, context: context)) {
                        card.zoomSource(id: zoomID, namespace: namespace)
                    }
                }
            }
            // Native tvOS card focus: lift, soft shadow, moving shine and parallax tilt.
            .buttonStyle(.card)
            .continueMenu(context?.rowID == "continue", item: item, client: client)
            // Focused poster: «مسلسل • كوميديا» just under it (badges printed on server posters
            // stay readable); takes no room in the row.
            .overlay(alignment: .bottom) {
                if kind == .poster, cardFocused, let caption = PosterCard.focusCaption(item) {
                    Text(caption)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .fixedSize()
                        .offset(y: 44)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.2), value: cardFocused)

            // No text under posters (Apple TV app); landscape cards keep their title.
            if kind == .landscape {
                LandscapeCaption(item: item)
            }
        }
    }

    private var containerPath: String {
        if let key = item.key, key.hasPrefix("/") { return key }
        return item.type == "playlist" ? "/playlists/\(item.ratingKey)/items" : "/library/collections/\(item.ratingKey)/children"
    }

    private var card: some View {
        Group {
            switch kind {
            case .poster:
                PosterCard(item: item, client: client, rank: rank, logoPath: logoPath, size: posterSize)
            case .landscape:
                LandscapeCard(item: item, client: client)
            }
        }
        .background(FocusReporter { focused in
            cardFocused = focused
            guard focused else { return }
            // Under a banner: focus in the rows moves the page up.
            pageContentFocused?()
            // Grids show the focused item's artwork behind them (Home has its banner instead).
            backdrop.url = client.imageURL(item.backdropPath, width: 1280, height: 720)
        })
    }
}

private extension View {
    @ViewBuilder
    func continueMenu(_ on: Bool, item: PlexItem, client: PlexServerClient) -> some View {
        if on { modifier(ContinueCardMenu(item: item, client: client)) } else { self }
    }
}

/// Reports focus changes of the enclosing button (the nearest focusable ancestor).
private struct FocusReporter: View {
    let onChange: (Bool) -> Void
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Color.clear.onChange(of: isFocused) { _, focused in onChange(focused) }
    }
}

// MARK: - Rows

/// Horizontally scrolling row. Starts on the reading side (right in Arabic), leaves room
/// for the focused card to grow without covering the title, and remembers the last
/// focused card when focus leaves and comes back.
struct ShelfView: View {
    let shelf: Shelf
    let client: PlexServerClient

    @Environment(ProfileStore.self) private var store
    @Environment(BrowseReturnState.self) private var returnState
    @Environment(\.pageRowFocused) private var pageRowFocused
    @FocusState private var focusedID: String?
    @State private var lastFocusedID: String?

    var body: some View {
        let items = shelf.items.mergingCopies(store)
        let context = BrowseContext(rowID: shelf.id, items: items)
        VStack(alignment: .leading, spacing: 0) {
            // Small grey header (Apple TV app), 34 pt above the posters.
            VStack(alignment: .leading, spacing: 2) {
                Text(shelf.title)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                if let subtitle = shelf.subtitle {
                    Text(subtitle)
                        .font(.system(size: 21, weight: .regular))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, CardKind.inset)
            .sidebarPadding()

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: CardKind.spacing) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            MediaCardLink(item: item, kind: shelf.kind, client: client,
                                          rank: shelf.ranked ? index + 1 : nil,
                                          logoPath: shelf.logos[item.ratingKey],
                                          sourceID: context.sourceID(for: item),
                                          context: context)
                                .focused($focusedID, equals: item.id)
                        }
                    }
                    // 34 pt under the header; ~96 pt from the poster bottom to the next header.
                    .padding(.horizontal, CardKind.inset)
                    .padding(.top, 34)
                    .padding(.bottom, 96)
                    // A short row fills the screen. Narrower than its scroll view, on tvOS 27 in
                    // Arabic it slid towards the sidebar by the empty space after a details page
                    // closed (five cards: 300 pt; two: off the screen).
                    .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in
                        max(width, cardsWidth(items.count))
                    }
                }
                // First card on the same line as every row, after the sidebar; cards scroll under it.
                .sidebarSafeArea()
                .scrollClipDisabled()
                .onAppear { restoreFocus(proxy, count: items.count) }
            }
            .focusSection()
            .defaultFocus($focusedID, lastFocusedID ?? items.first?.id, priority: .userInitiated)
            .onChange(of: items.map(\.id)) { old, new in keepFocus(from: old, to: new) }
            .onChange(of: focusedID) { old, id in
                if let id { lastFocusedID = id }
                // Focus entered this row: the page brings it to its reading position.
                if old == nil, id != nil { pageRowFocused?(shelf.id) }
            }
        }
    }

    /// The focused card was just removed: the one that took its place, not the banner.
    private func keepFocus(from old: [String], to new: [String]) {
        guard shelf.id == "continue", Date().timeIntervalSince(ContinueActions.removedAt) < 3,
              let gone = lastFocusedID, !new.contains(gone), let index = old.firstIndex(of: gone), !new.isEmpty else { return }
        let next = new[min(index, new.count - 1)]
        for delay in [0.05, 0.4, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { if focusedID == nil { focusedID = next } }
        }
    }

    /// Width of the cards with their margins.
    private func cardsWidth(_ count: Int) -> CGFloat {
        CGFloat(count) * shelf.kind.size.width + CGFloat(max(0, count - 1)) * CardKind.spacing + 2 * CardKind.inset
    }

    /// After returning from a details page that paged along this row, land on the last item reached.
    private func restoreFocus(_ proxy: ScrollViewProxy, count: Int) {
        guard let id = returnState.take(for: shelf.id) else { return }
        lastFocusedID = id
        // Nothing to scroll in a row that fits the screen.
        if cardsWidth(count) > UIScreen.main.bounds.width { proxy.scrollTo(id, anchor: .center) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focusedID = id }
    }
}

/// Grid of posters for library and search pages (6 per row, same card as the shelves).
/// Wrap the enclosing ScrollView in a ScrollViewReader and pass its proxy so focus can be
/// restored to the last item reached by paging on a details page.
struct PosterGrid: View {
    let items: [PlexItem]
    let client: PlexServerClient
    var scrollProxy: ScrollViewProxy?
    /// Return-to-item key (two grids on one page need different ones).
    var rowID = "grid"
    var onItemAppear: (PlexItem) -> Void = { _ in }

    @Environment(BrowseReturnState.self) private var returnState
    @FocusState private var focusedID: String?
    /// Width offered to the grid (measured; nil until then). The grid is drawn only once it's
    /// known: drawn wider than its container it would push the container wider (next to the
    /// grid keyboard tvOS then centres the over-wide results and they run under the keyboard).
    @State private var width: CGFloat?

    /// As many posters as fit at 230 pt or more, sized to fill the row exactly: 6 × 260 at
    /// full width (1760 pt), 4 × ~242 next to the grid keyboard in Search (no empty strip).
    private var layout: (count: Int, poster: CGSize) {
        let full = CardKind.poster.size
        let minimum: CGFloat = 230
        let available = max((width ?? 0) - 2 * CardKind.inset, minimum)
        let count = max(1, Int(((available + CardKind.spacing) / (minimum + CardKind.spacing)).rounded(.down)))
        let w = ((available - CGFloat(count - 1) * CardKind.spacing) / CGFloat(count)).rounded(.down)
        return (count, CGSize(width: w, height: (w * full.height / full.width).rounded()))
    }

    var body: some View {
        let items = self.items.uniqued()
        let context = BrowseContext(rowID: rowID, items: items)
        let layout = self.layout
        let columns = Array(repeating: GridItem(.fixed(layout.poster.width), spacing: CardKind.spacing, alignment: .top),
                            count: layout.count)
        VStack(alignment: .leading, spacing: 0) {
            // The width offered to the grid (not the grid's own, which follows its columns).
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            if width != nil {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
                    ForEach(items) { item in
                        MediaCardLink(item: item, client: client, posterSize: layout.poster,
                                      sourceID: context.sourceID(for: item), context: context)
                            .focused($focusedID, equals: item.id)
                            .onAppear { onItemAppear(item) }
                    }
                }
                .padding(.horizontal, CardKind.inset)
                .padding(.vertical, 30)
                // Starts on the same line as the rows; the enclosing ScrollView adds the sidebar inset.
                .frame(maxWidth: .infinity, alignment: .leading)
                // Entering the grid lands on its first item (reading side), not the one under the bar.
                .focusSection()
                .defaultFocus($focusedID, items.first?.id, priority: .userInitiated)
                .onAppear {
                    guard let id = returnState.take(for: rowID) else { return }
                    scrollProxy?.scrollTo(id, anchor: .center)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focusedID = id }
                }
            }
        }
    }
}

