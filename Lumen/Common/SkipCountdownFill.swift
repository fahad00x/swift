import SwiftUI

/// Behind the skip button while it waits to skip by itself: a darker fill grows across it from
/// the reading side (the right in Arabic) over `PlayerSession.autoSkipDelay` s. Its own view, as
/// it reads the playhead (which changes every frame) and the button must not be rebuilt for it.
struct SkipCountdownFill: View {
    let session: PlayerSession
    var color: Color = .black.opacity(0.18)

    var body: some View {
        if let autoAt = session.skipAutoAt {
            let start = autoAt - PlayerSession.autoSkipDelay
            let fraction = min(1, max(0, (session.position - start) / PlayerSession.autoSkipDelay))
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(color).frame(width: geo.size.width * fraction)
                    Spacer(minLength: 0)
                }
                .environment(\.layoutDirection, .rightToLeft)
                .animation(.linear(duration: 0.3), value: fraction)
            }
            .allowsHitTesting(false)
        }
    }
}
