import Foundation
import Observation

/// The four libraries pinned to the sidebar (per profile, chosen in Settings); the rest are under «المزيد».
@MainActor
@Observable
final class SidebarPrefs {
    static let maxPinned = 4

    private let key: String
    private var pinnedIDs: [String]?

    /// From the profile (synced through iCloud); older builds kept it on the device only.
    init(profileID: String) {
        key = "sidebar.libraries.\(profileID)"
        let profile = ProfileStore.shared.profiles.first { $0.id == profileID }
        pinnedIDs = profile?.settings?.sidebarScopes ?? UserDefaults.standard.stringArray(forKey: key)
    }

    /// Pinned libraries in order (the first four by default).
    ///
    /// Saved ids can go stale (a library removed or renamed on the server, a scope split into
    /// anime / non-anime, or a choice synced from another device with other libraries). When
    /// none of the saved ids match an open library any more, the sidebar used to show the
    /// «المكتبات» header with nothing under it; it now falls back to the default first four.
    /// An explicitly empty choice (everything under «المزيد») is kept.
    func pinned(from scopes: [LibraryScope]) -> [LibraryScope] {
        guard let pinnedIDs, !pinnedIDs.isEmpty else {
            return pinnedIDs == nil ? Array(scopes.prefix(Self.maxPinned)) : []
        }
        let chosen = pinnedIDs.compactMap { id in scopes.first { $0.id == id } }
        if chosen.isEmpty { return Array(scopes.prefix(Self.maxPinned)) }
        return Array(chosen.prefix(Self.maxPinned))
    }

    func isPinned(_ scope: LibraryScope, in scopes: [LibraryScope]) -> Bool {
        pinned(from: scopes).contains { $0.id == scope.id }
    }

    /// Adds (dropping the last one when four are pinned) or removes a library.
    func toggle(_ scope: LibraryScope, in scopes: [LibraryScope]) {
        var ids = pinned(from: scopes).map(\.id)
        if let i = ids.firstIndex(of: scope.id) {
            ids.remove(at: i)
        } else {
            if ids.count >= Self.maxPinned { ids.removeLast() }
            ids.append(scope.id)
        }
        save(ids)
    }

    func moveUp(_ scope: LibraryScope, in scopes: [LibraryScope]) {
        var ids = pinned(from: scopes).map(\.id)
        guard let i = ids.firstIndex(of: scope.id), i > 0 else { return }
        ids.swapAt(i, i - 1)
        save(ids)
    }

    private func save(_ ids: [String]) {
        pinnedIDs = ids
        UserDefaults.standard.set(ids, forKey: key)
        ProfileStore.shared.updateSettings { $0.sidebarScopes = ids }
    }
}
