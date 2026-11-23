import SwiftUI

// Infuse-style watch indicators on artwork, shared by the Apple TV and iPhone apps.
// They read the active profile's watch state live from ProfileStore (not the copy the item
// was fetched with), so finishing or marking an item updates every card on screen at once.

@MainActor
extension ProfileStore {
    /// Movie / episode not finished; show / season with at least one unwatched episode.
    func isUnwatched(_ item: PlexItem) -> Bool {
        switch item.type {
        case "show", "season":
            guard let leaves = item.leafCount, leaves > 0 else { return !item.isWatched }
            return watchedEpisodeCount(under: item.ratingKey) < leaves
        default:
            return !(state(for: item.ratingKey)?.watched ?? false)
        }
    }

    /// 0…1 for a started, unfinished movie / episode; nil otherwise.
    func progress(of item: PlexItem) -> Double? {
        guard item.isPlayable, let s = state(for: item.ratingKey), !s.watched, s.offsetMs > 0 else { return nil }
        let duration = s.durationMs > 0 ? s.durationMs : (item.duration ?? 0)
        guard duration > 0 else { return nil }
        let value = Double(s.offsetMs) / Double(duration)
        return value < 0.995 ? min(max(value, 0.01), 1) : nil
    }
}

/// Orange corner triangle (unwatched) and orange bottom bar (progress), drawn over artwork.
/// Placed in physical coordinates: the triangle is always top-right and the bar fills
/// left → right like the player's timeline, in Arabic (RTL) too.
struct ArtworkStatusOverlay: View {
    let item: PlexItem
    /// Short side of the triangle, relative to the artwork width.
    var triangleFraction: CGFloat = 0.13
    var barHeight: CGFloat = 4

    @Environment(ProfileStore.self) private var store

    static let orange = Color(red: 1.0, green: 0.58, blue: 0.0)

    var body: some View {
        let progress = store.progress(of: item)
        // Started-but-unfinished items show only the progress bar, never the triangle.
        let unwatched = progress == nil && store.isUnwatched(item)
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                Color.clear
                if unwatched {
                    let side = max(12, geo.size.width * triangleFraction)
                    CornerTriangle()
                        .fill(Self.orange)
                        .frame(width: side, height: side)
                        .shadow(color: .black.opacity(0.35), radius: 2)
                }
                if let progress {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.black.opacity(0.45))
                        Rectangle().fill(Self.orange).frame(width: geo.size.width * progress)
                    }
                    .frame(height: barHeight)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: unwatched)
        .animation(.easeOut(duration: 0.2), value: progress)
    }
}

/// Right triangle filling the top-right corner.
struct CornerTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

extension View {
    /// Adds the watch indicators; apply to the artwork, inside its clip shape.
    func artworkStatus(_ item: PlexItem, triangleFraction: CGFloat = 0.13, barHeight: CGFloat = 4) -> some View {
        overlay(ArtworkStatusOverlay(item: item, triangleFraction: triangleFraction, barHeight: barHeight))
    }
}
