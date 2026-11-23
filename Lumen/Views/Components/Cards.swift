import SwiftUI

// Apple TV media cards: artwork with status overlays and a light white-border focus style
// (no shadow or parallax, so moving focus stays cheap).

enum CardKind {
    /// 2:3 poster. 7 fit across the content area (next to the sidebar rail).
    case poster
    /// 16:9 Continue Watching card. ~4½ fit across the screen.
    case landscape

    /// Sized for the content area next to the sidebar rail.
    var size: CGSize {
        switch self {
        case .poster: return CGSize(width: 210, height: 315)
        case .landscape: return CGSize(width: 340, height: 191)
        }
    }

    static let cornerRadius: CGFloat = 10
    static let spacing: CGFloat = 28
    /// Side inset of rows and grids (inside the content area, next to the rail).
    static let inset: CGFloat = 50
}

// MARK: - Landscape (Continue Watching)

struct LandscapeCard: View {
    let item: PlexItem
    let client: PlexServerClient
    /// Show / movie clear logo, when known.
    var logoPath: String?

    var body: some View {
        let size = CardKind.landscape.size
        ZStack(alignment: .bottom) {
            Color(white: 0.13)
            RemoteImage(url: client.imageURL(item.landscapePath, width: Int(size.width * 2), height: Int(size.height * 2)))
            LinearGradient(stops: [
                .init(color: .clear, location: 0.35),
                .init(color: .black.opacity(0.8), location: 1),
            ], startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 8) {
                CardTitle(title: item.cardTitle, logoPath: logoPath, client: client,
                          logoSize: CGSize(width: 190, height: 64), font: .headline)
                HStack(spacing: 10) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text(caption)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: size.width, height: size.height)
        .artworkStatus(item, triangleFraction: 0.08, barHeight: 6)
        .clipShape(RoundedRectangle(cornerRadius: CardKind.cornerRadius, style: .continuous))
    }

    /// "م٣، ح١ · ٥٨د" for an episode, "باقي ٤٥د" for a movie.
    private var caption: String {
        let remaining = item.duration.map { max(0, $0 - (item.viewOffset ?? 0)) }
        let time = remaining.map(ArabicFormat.duration(ms:))
        if item.isEpisode {
            var code: [String] = []
            if let s = item.parentIndex { code.append("م\(ArabicFormat.digits(s))") }
            if let e = item.index { code.append("ح\(ArabicFormat.digits(e))") }
            return ([code.joined(separator: "، ")] + [time].compactMap { $0 })
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
        guard let time else { return "" }
        return item.progress != nil ? "باقي \(time)" : time
    }
}

// MARK: - Poster

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
    @State private var airing = false

    var body: some View {
        ZStack {
            Color(white: 0.13)
            Image(systemName: item.isShow || item.isEpisode ? "tv" : "film")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.2))
            RemoteImage(url: size == CardKind.poster.size
                        ? client.posterURL(item)
                        : client.imageURL(item.posterPath, width: Int(size.width * 2), height: Int(size.height * 2)))
            PosterBadges(item: item, unwatchedEpisodes: unwatchedEpisodes, airing: airing)
        }
        .frame(width: size.width, height: size.height)
        .artworkStatus(item, triangleFraction: 0.14, barHeight: 5)
        .clipShape(RoundedRectangle(cornerRadius: CardKind.cornerRadius, style: .continuous))
        .task(id: item.ratingKey) {
            guard item.isShow, let aired = await client.latestAired(show: item.ratingKey) else { return }
            airing = aired >= PosterBadges.airingCutoff
        }
    }

    private var unwatchedEpisodes: Int? {
        guard item.isShow || item.isSeason, let leaves = item.leafCount, leaves > 0 else { return nil }
        let remaining = leaves - store.watchedEpisodeCount(under: item.ratingKey)
        return remaining > 0 ? remaining : nil
    }
}

/// Overlays drawn in physical positions (top-left count / quality, bottom ribbon),
/// so they never collide with the top-right unwatched triangle in Arabic.
private struct PosterBadges: View {
    let item: PlexItem
    let unwatchedEpisodes: Int?
    let airing: Bool

    /// Shows with an episode aired in the last 14 days count as airing.
    static var airingCutoff: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date().addingTimeInterval(-14 * 86_400))
    }

    private var quality: String? {
        guard item.isPlayable else { return nil }
        return item.media.first?.resolutionBadge
    }

    var body: some View {
        ZStack {
            if airing {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let unwatchedEpisodes {
                    badge(ArabicFormat.digits(unwatchedEpisodes), font: .system(size: 18, weight: .bold))
                }
                if let quality {
                    badge(quality, font: .system(size: 14, weight: .heavy))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(8)

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if airing {
                    Text("يُعرض")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(red: 0.35, green: 0.85, blue: 0.45)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false)
    }

    private func badge(_ text: String, font: Font) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(0.72)))
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
            var code: [String] = []
            if let s = item.parentIndex { code.append("م\(ArabicFormat.digits(s))") }
            if let e = item.index { code.append("ح\(ArabicFormat.digits(e))") }
            return code.isEmpty ? nil : code.joined(separator: " · ")
        }
        if item.isSeason { return item.parentTitle }
        return item.year.map { ArabicFormat.digits($0) }
    }
}

/// Focus: a slight lift and a white border, no heavy shadow or parallax (cheap to draw).
struct PosterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .overlay {
                    RoundedRectangle(cornerRadius: CardKind.cornerRadius, style: .continuous)
                        .strokeBorder(Color.white, lineWidth: isFocused ? 5 : 0)
                }
                .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.08 : 1))
                .animation(.easeOut(duration: 0.12), value: isFocused)
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
    @Environment(HomeFocus.self) private var homeFocus: HomeFocus?
    @Environment(\.detailNamespace) private var namespace

    private var zoomID: String { sourceID ?? item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: DetailRoute(item: item, sourceID: zoomID, context: context)) {
                Group {
                    switch kind {
                    case .poster:
                        PosterCard(item: item, client: client, rank: rank, logoPath: logoPath, size: posterSize)
                    case .landscape:
                        LandscapeCard(item: item, client: client, logoPath: logoPath)
                    }
                }
                .background(FocusReporter { focused in
                    guard focused else { return }
                    if let homeFocus {
                        // Home shows the focused item's details and backdrop at the top.
                        homeFocus.item = item
                    } else {
                        backdrop.url = client.imageURL(item.backdropPath, width: 1280, height: 720)
                    }
                })
                .zoomSource(id: zoomID, namespace: namespace)
            }
            .buttonStyle(PosterButtonStyle())

            if kind == .poster {
                CardCaption(item: item)
                    .frame(width: posterSize.width, alignment: .leading)
            }
        }
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

struct Shelf: Identifiable {
    let id: String
    let title: String
    let kind: CardKind
    let items: [PlexItem]
    /// Top 10 style: large rank numbers on the cards.
    var ranked = false
    /// ratingKey → clear logo path.
    var logos: [String: String] = [:]
}

/// Horizontally scrolling row. Starts on the reading side (right in Arabic), leaves room
/// for the focused card to grow without covering the title, and remembers the last
/// focused card when focus leaves and comes back.
struct ShelfView: View {
    let shelf: Shelf
    let client: PlexServerClient

    @Environment(BrowseReturnState.self) private var returnState
    @FocusState private var focusedID: String?
    @State private var lastFocusedID: String?

    var body: some View {
        let items = shelf.items.uniqued()
        let context = BrowseContext(rowID: shelf.id, items: items)
        VStack(alignment: .leading, spacing: 0) {
            Text(shelf.title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, CardKind.inset)

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
                    // Room for the 8% focus lift, so cards never cover the title.
                    .padding(.horizontal, CardKind.inset)
                    .padding(.top, 24)
                    .padding(.bottom, 30)
                }
                .scrollClipDisabled()
                .onAppear { restoreFocus(proxy) }
            }
            .focusSection()
            .defaultFocus($focusedID, lastFocusedID ?? items.first?.id, priority: .userInitiated)
            .onChange(of: focusedID) { _, id in
                if let id { lastFocusedID = id }
            }
        }
    }

    /// After returning from a details page that paged along this row, land on the last item reached.
    private func restoreFocus(_ proxy: ScrollViewProxy) {
        guard let id = returnState.take(for: shelf.id) else { return }
        lastFocusedID = id
        proxy.scrollTo(id, anchor: .center)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focusedID = id }
    }
}

/// Grid of posters for library and search pages (7 per row, same card as the shelves).
/// Wrap the enclosing ScrollView in a ScrollViewReader and pass its proxy so focus can be
/// restored to the last item reached by paging on a details page.
struct PosterGrid: View {
    let items: [PlexItem]
    let client: PlexServerClient
    var scrollProxy: ScrollViewProxy?
    var onItemAppear: (PlexItem) -> Void = { _ in }

    @Environment(BrowseReturnState.self) private var returnState
    @FocusState private var focusedID: String?

    private let rowID = "grid"
    private let columns = Array(repeating: GridItem(.fixed(CardKind.poster.size.width), spacing: CardKind.spacing, alignment: .top), count: 7)

    var body: some View {
        let items = self.items.uniqued()
        let context = BrowseContext(rowID: rowID, items: items)
        LazyVGrid(columns: columns, alignment: .center, spacing: 44) {
            ForEach(items) { item in
                MediaCardLink(item: item, client: client, sourceID: context.sourceID(for: item), context: context)
                    .focused($focusedID, equals: item.id)
                    .onAppear { onItemAppear(item) }
            }
        }
        .padding(.horizontal, CardKind.inset)
        .padding(.vertical, 30)
        .onAppear {
            guard let id = returnState.take(for: rowID) else { return }
            scrollProxy?.scrollTo(id, anchor: .center)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focusedID = id }
        }
    }
}

