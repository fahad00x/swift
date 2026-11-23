import SwiftUI

// MARK: - Cards

/// 2:3 poster with title below. Without `width` it fills its grid cell.
struct PosterCard: View {
    let item: PlexItem
    let client: PlexServerClient
    var width: CGFloat?
    var rank: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            artwork
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
        .frame(width: width)
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
        .overlay(alignment: .bottomLeading) {
            if let rank {
                Text(ArabicFormat.digits(rank))
                    .font(.system(size: 54, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 6)
                    .padding(.horizontal, 8)
                    .offset(y: 10)
            }
        }
        .artworkStatus(item)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var subtitle: String? {
        if item.isEpisode { return item.episodeCode }
        let genres = ArabicFormat.genres(item.genres.map(\.tag), limit: 2)
        if !genres.isEmpty { return ArabicFormat.list(genres) }
        return item.year.map { ArabicFormat.digits($0) }
    }
}

/// 16:9 Continue Watching card with progress.
struct LandscapeCard: View {
    let item: PlexItem
    let client: PlexServerClient
    var logoPath: String?
    var width: CGFloat = 270

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
            let code = ArabicFormat.shortEpisodeCode(season: item.parentIndex, episode: item.index)
            return ArabicFormat.joined([code, time].compactMap { $0 })
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        NavigationLink(value: item) {
                            switch style {
                            case .poster:
                                PosterCard(item: item, client: client, width: 118, rank: ranked ? index + 1 : nil)
                            case .landscape:
                                LandscapeCard(item: item, client: client, logoPath: logos[item.ratingKey])
                            }
                        }
                        .buttonStyle(.plain)
                        .itemContextMenu(item, client: client)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

/// Poster grid for libraries and search.
struct PosterGrid: View {
    let items: [PlexItem]
    let client: PlexServerClient
    var onItemAppear: (PlexItem) -> Void = { _ in }

    private let columns = [GridItem(.adaptive(minimum: 105, maximum: 160), spacing: 12, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: 18) {
            ForEach(items) { item in
                NavigationLink(value: item) {
                    PosterCard(item: item, client: client)
                }
                .buttonStyle(.plain)
                .itemContextMenu(item, client: client)
                .onAppear { onItemAppear(item) }
            }
        }
        .padding(.horizontal, 16)
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
