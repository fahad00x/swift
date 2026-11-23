import SwiftUI

// Apple TV–style media cards. Focus uses the native `.card` button style, so the lift,
// shadow, specular edge highlight and touch-driven parallax tilt all come from tvOS.

enum CardKind {
    /// 2:3 poster. ~5½ fit across the screen.
    case poster
    /// 16:9 Continue Watching card. ~4½ fit across the screen.
    case landscape

    /// Width chosen so that, after the 80 pt leading inset and 40 pt gaps,
    /// the last visible card is cut in half (signals that the row scrolls).
    var size: CGSize {
        switch self {
        case .poster: return CGSize(width: 298, height: 447)
        case .landscape: return CGSize(width: 372, height: 209)
        }
    }

    static let cornerRadius: CGFloat = 12
    static let spacing: CGFloat = 40
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
                    if let progress = item.progress {
                        ThinProgress(value: progress)
                            .frame(width: 64, height: 5)
                    }
                }
                .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: size.width, height: size.height)
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

struct PosterCard: View {
    let item: PlexItem
    let client: PlexServerClient
    /// 1-based position in a Top 10 row.
    var rank: Int?
    var logoPath: String?
    var size: CGSize = CardKind.poster.size

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(white: 0.13)
            Image(systemName: item.isShow || item.isEpisode ? "tv" : "film")
                .font(.system(size: 54))
                .foregroundStyle(.white.opacity(0.2))
            RemoteImage(url: client.imageURL(item.posterPath, width: Int(size.width * 2), height: Int(size.height * 2)))
            LinearGradient(stops: [
                .init(color: .clear, location: 0.5),
                .init(color: .black.opacity(0.88), location: 1),
            ], startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 4) {
                CardTitle(title: item.cardTitle, logoPath: logoPath, client: client,
                          logoSize: CGSize(width: size.width - 40, height: 70), font: .callout.weight(.bold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .topLeading) {
            if let rank {
                Text(ArabicFormat.digits(rank))
                    .font(.system(size: 120, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .shadow(color: .black.opacity(0.55), radius: 10, y: 4)
                    .padding(.horizontal, 16)
                    .offset(y: -18)
            }
        }
        .overlay(alignment: .topTrailing) { watchState.padding(12) }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: CardKind.cornerRadius, style: .continuous))
    }

    private var subtitle: String? {
        if item.isEpisode { return item.episodeCode }
        let genres = item.genres.prefix(2).map { ArabicFormat.genre($0.tag) }
        if !genres.isEmpty { return genres.joined(separator: "، ") }
        return item.year.map { ArabicFormat.digits($0) }
    }

    @ViewBuilder private var watchState: some View {
        if let count = item.unwatchedCount {
            Text(ArabicFormat.digits(count))
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor))
                .foregroundStyle(.black)
        } else if item.isWatched {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
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

private struct ThinProgress: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.3))
                Capsule().fill(Color.white).frame(width: geo.size.width * value)
            }
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
    @Environment(\.detailNamespace) private var namespace

    private var zoomID: String { sourceID ?? item.id }

    var body: some View {
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
                if focused { backdrop.url = client.imageURL(item.backdropPath, width: 1920, height: 1080) }
            })
            .zoomSource(id: zoomID, namespace: namespace)
        }
        .buttonStyle(.card)
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
        let context = BrowseContext(rowID: shelf.id, items: shelf.items)
        VStack(alignment: .leading, spacing: 0) {
            Text(shelf.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .padding(.horizontal, 80)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: CardKind.spacing) {
                        ForEach(Array(shelf.items.enumerated()), id: \.element.id) { index, item in
                            MediaCardLink(item: item, kind: shelf.kind, client: client,
                                          rank: shelf.ranked ? index + 1 : nil,
                                          logoPath: shelf.logos[item.ratingKey],
                                          sourceID: context.sourceID(for: item),
                                          context: context)
                                .focused($focusedID, equals: item.id)
                        }
                    }
                    // Room for the ~10% focus scale and shadow, so cards never cover the title.
                    .padding(.horizontal, 80)
                    .padding(.top, 34)
                    .padding(.bottom, 54)
                }
                .scrollClipDisabled()
                .onAppear { restoreFocus(proxy) }
            }
            .focusSection()
            .defaultFocus($focusedID, lastFocusedID ?? shelf.items.first?.id, priority: .userInitiated)
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

/// Grid of posters for library and search pages (5 per row, same card as the shelves).
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
    private let columns = Array(repeating: GridItem(.fixed(CardKind.poster.size.width), spacing: 67, alignment: .top), count: 5)

    var body: some View {
        let context = BrowseContext(rowID: rowID, items: items)
        LazyVGrid(columns: columns, alignment: .center, spacing: 70) {
            ForEach(items) { item in
                MediaCardLink(item: item, client: client, sourceID: context.sourceID(for: item), context: context)
                    .focused($focusedID, equals: item.id)
                    .onAppear { onItemAppear(item) }
            }
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 30)
        .onAppear {
            guard let id = returnState.take(for: rowID) else { return }
            scrollProxy?.scrollTo(id, anchor: .center)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focusedID = id }
        }
    }
}

