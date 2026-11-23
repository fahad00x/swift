import SwiftUI

// Plex-style "UltraBlur" backgrounds: the artwork at the top melting into a soft gradient of
// the four corner colours Plex computes for it, so rows and text sit on the item's own colour
// instead of a black band. Falls back to the darkened artwork when the colours are missing.

/// Four-corner colour field (MeshGradient on tvOS 18, two blended linear gradients on 17),
/// lightly darkened so white text stays readable.
struct UltraBlurBackground: View {
    let colors: PlexUltraBlurColors

    var body: some View {
        let tl = Color(hex: colors.topLeft ?? "000000")
        let tr = Color(hex: colors.topRight ?? "000000")
        let bl = Color(hex: colors.bottomLeft ?? "000000")
        let br = Color(hex: colors.bottomRight ?? "000000")
        ZStack {
            if #available(tvOS 18.0, iOS 18.0, *) {
                MeshGradient(width: 2, height: 2,
                             points: [[0, 0], [1, 0], [0, 1], [1, 1]],
                             colors: [tl, tr, bl, br])
            } else {
                LinearGradient(colors: [tl, tr], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [bl, br], startPoint: .leading, endPoint: .trailing)
                    .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
            }
            Color.black.opacity(0.28)
        }
        // Corners are physical (Plex's top-left is the image's top-left), also in Arabic.
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// Artwork over its UltraBlur colours: the image fills the top and fades into the colour
/// below `fadeStart`…`fadeEnd` (fractions of the height). Without colours, the plain image.
/// Changes cross-fade (~0.4 s). Always full screen, including under the sidebar.
struct ArtworkBackdrop: View {
    let url: URL?
    let colors: PlexUltraBlurColors?
    var fadeStart: CGFloat = 0.38
    var fadeEnd: CGFloat = 0.78

    var body: some View {
        ZStack {
            Color.black
            if let colors {
                UltraBlurBackground(colors: colors)
                    .id(colors)
                    .transition(.opacity)
            }
            if let url {
                RemoteImage(url: url)
                    .mask {
                        if colors != nil {
                            LinearGradient(stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: fadeStart),
                                .init(color: .clear, location: fadeEnd),
                            ], startPoint: .top, endPoint: .bottom)
                        } else {
                            Color.black
                        }
                    }
                    .id(url)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: url)
        .animation(.easeInOut(duration: 0.4), value: colors)
        .ignoresSafeArea()
    }
}

/// Darkens the reading side (the right in Arabic, where the text and the sidebar are) and
/// the bottom. Lighter over UltraBlur colours, stronger over a bare image.
struct BackdropScrim: View {
    let hasColors: Bool
    /// How far the right-side darkening reaches (fraction of the width).
    var sideReach: CGFloat = 0.62

    var body: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: .black.opacity(hasColors ? 0.7 : 0.92), location: 0),
                .init(color: .black.opacity(hasColors ? 0.45 : 0.75), location: 0.28),
                .init(color: .black.opacity(hasColors ? 0.12 : 0.35), location: sideReach),
                .init(color: .black.opacity(hasColors ? 0 : 0.12), location: 1),
            ], startPoint: .trailing, endPoint: .leading)
            LinearGradient(stops: hasColors ? [
                .init(color: .clear, location: 0.45),
                .init(color: .black.opacity(0.25), location: 1),
            ] : [
                .init(color: .clear, location: 0.22),
                .init(color: .black.opacity(0.7), location: 0.4),
                .init(color: .black.opacity(0.92), location: 0.58),
                .init(color: .black, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        // Physical sides: trailing = the right edge.
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
