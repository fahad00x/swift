import SwiftUI

/// Navigation value for a card → details page.
/// `sourceID` identifies the exact card (row + item) so the zoom transition starts from it,
/// even when the same title appears in several rows.
struct DetailRoute: Hashable {
    let item: PlexItem
    let sourceID: String
    /// The row the card belongs to, so the details page can page through its siblings.
    var context: BrowseContext?
}

/// A row (or grid, or the home hero) a details page was opened from.
struct BrowseContext: Hashable {
    let rowID: String
    let items: [PlexItem]

    /// Zoom-transition id of a card in this row.
    func sourceID(for item: PlexItem) -> String { "\(rowID)|\(item.id)" }
}

/// Remembers the last item reached by paging on a details page, so Back can land on that card.
@MainActor
@Observable
final class BrowseReturnState {
    private(set) var rowID: String?
    private(set) var itemID: String?

    func set(rowID: String, itemID: String) {
        self.rowID = rowID
        self.itemID = itemID
    }

    /// Returns (and clears) the item to restore focus to, if it belongs to `rowID`.
    func take(for rowID: String) -> String? {
        guard self.rowID == rowID, let itemID else { return nil }
        self.rowID = nil
        self.itemID = nil
        return itemID
    }
}

private struct DetailNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// Namespace shared by cards and the details page for the zoom transition.
    var detailNamespace: Namespace.ID? {
        get { self[DetailNamespaceKey.self] }
        set { self[DetailNamespaceKey.self] = newValue }
    }
}

extension View {
    /// Marks a card as the source of the zoom transition (tvOS 18+).
    @ViewBuilder
    func zoomSource(id: String, namespace: Namespace.ID?) -> some View {
        if let namespace {
            if #available(tvOS 18.0, *) {
                self.matchedTransitionSource(id: id, in: namespace)
            } else {
                self
            }
        } else {
            self
        }
    }

    /// The details page grows out of its card (tvOS 18+); older versions keep the standard transition.
    @ViewBuilder
    func zoomDestination(id: String, namespace: Namespace.ID?) -> some View {
        if let namespace {
            if #available(tvOS 18.0, *) {
                self.navigationTransition(.zoom(sourceID: id, in: namespace))
            } else {
                self
            }
        } else {
            self
        }
    }
}
