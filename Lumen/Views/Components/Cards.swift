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
        case .poster: return CGSize(width: 240, height: 358)
        case .landscape: return CGSize(width: 340, height: 191)
        }
    }

    static let cornerRadius: CGFloat = 10
    static let spacing: CGFloat = 30
    /// Side inset of rows and grids (inside the content area, next to the rail).
    static let inset: CGFloat = 20
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
/// Poster artwork with Plex-style overlays (mirrored for Arabic): network / airing ribbon in
/// the top-right corner, unwatched-episode count (or ✓) top-left, resolution and rating along
/// the bottom, and a thin progress bar once started. No text under the card: the focused
/// item's details show at the top of Home.
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
            PosterOverlays(item: item, watchBox: watchBox, ribbon: ribbon)
        }
        .frame(width: size.width, height: size.height)
        .artworkStatus(item, barHeight: 4)
        .clipShape(RoundedRectangle(cornerRadius: CardKind.cornerRadius, style: .continuous))
        .task(id: item.ratingKey) {
            guard item.isShow, let aired = await client.latestAired(show: item.ratingKey) else { return }
            airing = aired >= PosterOverlays.airingCutoff
        }
    }

    /// Unwatched episodes of a show / season, or ✓ when everything is watched.
    private var watchBox: String? {
        if item.isShow || item.isSeason {
            guard let leaves = item.leafCount, leaves > 0 else { return nil }
            let remaining = leaves - store.watchedEpisodeCount(under: item.ratingKey)
            return remaining > 0 ? ArabicFormat.digits(remaining) : "✓"
        }
        return (store.state(for: item.ratingKey)?.watched ?? false) ? "✓" : nil
    }

    /// Network and status (the server doesn't say whether a show ended, only when it last aired).
    private var ribbon: String? {
        guard item.isShow else { return nil }
        let parts = [item.studio, airing ? "يُعرض" : nil].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Small dark box (count, ✓, or an episode number), shared by posters and episode stills.
struct CornerBox: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(minWidth: 30, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.75)))
    }
}

/// Source + value, e.g. «IMDb 7.8».
struct RatingBox: View {
    let item: PlexItem
    var fontSize: CGFloat = 15

    var body: some View {
        if let rating = item.ratingDisplay {
            HStack(spacing: 5) {
                Text(rating.source)
                    .font(.system(size: fontSize - 2, weight: .heavy))
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.96, green: 0.77, blue: 0.09)))
                    .foregroundStyle(.black)
                Text(rating.value)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(.white)
            }
            .environment(\.layoutDirection, .leftToRight)
        }
    }
}

private struct PosterOverlays: View {
    let item: PlexItem
    let watchBox: String?
    let ribbon: String?

    /// Shows with an episode aired in the last 14 days count as airing.
    static var airingCutoff: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date().addingTimeInterval(-14 * 86_400))
    }

    private var quality: String? { item.media.first?.resolutionBadge }

    var body: some View {
        // Physical positions, mirrored for Arabic: ribbon top-right, box top-left.
        ZStack {
            if let ribbon {
                Text(ribbon)
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: 150, height: 22)
                    .background(Color.black.opacity(0.78))
                    .rotationEffect(.degrees(45))
                    .offset(x: 42, y: -42)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if let watchBox {
                CornerBox(text: watchBox)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if quality != nil || item.ratingDisplay != nil {
                HStack(spacing: 6) {
                    RatingBox(item: item)
                    Spacer(minLength: 0)
                    if let quality {
                        Text(quality)
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .background(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.8), lineWidth: 1.5))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 4)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false)
    }
}

/// Focus: slight lift, white 3 pt border and a soft shadow.
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
                        .strokeBorder(Color.white, lineWidth: isFocused ? 3 : 0)
                }
                .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.08 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 16, y: 10)
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
            HStack(spacing: 10) {
                Text(shelf.title)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                Text("· \(client.name)")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
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
                    .padding(.top, 34)
                    .padding(.bottom, 48)
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
    private let columns = Array(repeating: GridItem(.fixed(CardKind.poster.size.width), spacing: CardKind.spacing, alignment: .top), count: 6)

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

