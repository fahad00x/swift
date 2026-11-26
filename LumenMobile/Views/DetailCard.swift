import SwiftUI

// iPad in landscape: a title's page opens as a card in the middle of the screen, the page it was
// opened from blurred on both sides (a tap there closes it). Elsewhere it's pushed as before.

/// Opens a title's page as a card; nil where pages are pushed instead.
private struct DetailPresenterKey: EnvironmentKey {
    static let defaultValue: ((PlexItem) -> Void)? = nil
}

extension EnvironmentValues {
    var presentDetail: ((PlexItem) -> Void)? {
        get { self[DetailPresenterKey.self] }
        set { self[DetailPresenterKey.self] = newValue }
    }
}

/// A link to a title's page: the card where there is one, otherwise a push.
struct DetailLink<Label: View>: View {
    let item: PlexItem
    @ViewBuilder let label: () -> Label

    @Environment(\.presentDetail) private var presentDetail

    var body: some View {
        if let presentDetail {
            Button { presentDetail(item) } label: { label() }
        } else {
            NavigationLink(value: item) { label() }
        }
    }
}

/// The card: as wide as a phone page (the iPhone's layout), the whole height, the rest of the
/// screen blurred. Titles opened inside it (related, cast…) open in the card.
struct DetailCard: View {
    let client: PlexServerClient
    let item: PlexItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        GeometryReader { geo in
            // Turned to portrait with the card open: the page fills the screen, as when pushed.
            let landscape = geo.size.width > geo.size.height
            let width = landscape ? min(720, geo.size.width * 0.6) : geo.size.width
            let radius: CGFloat = landscape ? 14 : 0
            HStack(spacing: 0) {
                closeArea
                NavigationStack {
                    page(item)
                        .navigationDestination(for: PlexItem.self) { page($0) }
                }
                // The iPhone's layout in the narrow card; the iPad's own in portrait.
                .environment(\.horizontalSizeClass, landscape ? .compact : sizeClass)
                .environment(\.presentDetail, nil)
                .frame(width: width)
                .background(Color.black)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius))
                .shadow(color: .black.opacity(landscape ? 0.6 : 0), radius: 30)
                closeArea
            }
            .ignoresSafeArea(edges: landscape ? .vertical : .bottom)
            // Portrait: black under the status bar too, not the blurred page.
            .background(landscape ? Color.clear : Color.black)
        }
        .presentationBackground(.ultraThinMaterial)
    }

    /// A title's page in the card, with ✕ on every page (also those opened inside it).
    private func page(_ entry: PlexItem) -> some View {
        DetailView(client: client, entry: entry)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(.black.opacity(0.5)))
                    }
                    .accessibilityLabel("إغلاق")
                }
            }
    }

    /// A tap beside the card closes it.
    private var closeArea: some View {
        Color.black.opacity(0.35)
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
            .ignoresSafeArea()
    }
}
