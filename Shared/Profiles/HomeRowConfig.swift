import Foundation

/// One row of a profile's Home as the profile arranged it (Settings → «صفوف الرئيسية», or the
/// row's own menu). Saved with the profile, so it follows it to every device.
///
/// - pinned: the row keeps its place; only what's in it changes.
/// - not pinned (dynamic): the app decides whether and where it shows, as before.
/// - hidden: removed from Home.
struct HomeRowConfig: Codable, Hashable, Sendable, Identifiable {
    /// The row's family (`HomeLayout.family(of:)`): «continue», «mylist», «because»,
    /// «hub-…», «genre-…», «recent-…»…
    var id: String
    /// Its title when last seen, for the list in Settings.
    var title: String?
    var pinned: Bool = false
    var hidden: Bool = false
    /// A row the profile added (id «custom-…»); nil: one of the app's rows.
    var custom: CustomHomeRow?
}

/// A row the profile added to Home: what fills it.
struct CustomHomeRow: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// «أضيف مؤخراً في <library>».
        case recent
        /// One genre of a library (Plex's genre key).
        case genre
        /// A Plex / Kometa collection.
        case collection
        /// What «فلترة» matched (saved from the library's filter tab); a new batch every day.
        case filter
    }
    var kind: Kind
    /// The library's key.
    var section: String
    var genre: String?
    var collection: String?
    /// `.filter`: the library tab it was saved from (`LibraryScope.id`) and the choices.
    var scope: String?
    var criteria: FilterCriteria?
}

/// A row as Settings lists it: its family and title.
struct HomeRowInfo: Hashable, Sendable {
    let id: String
    let title: String
}

/// Applies a profile's arrangement to the rows the app built.
enum HomeLayout {
    /// Rows whose id changes with their content share one family: «لأنك شاهدت <title>» is
    /// «because-<key>»; the profile arranges «because».
    static func family(of rowID: String) -> String {
        if rowID.hasPrefix("because-") { return "because" }
        return rowID
    }

    /// `rows` in the app's order → as the profile arranged them. No arrangement: unchanged.
    ///
    /// Pinned rows sit at their position in the arrangement (counted among the rows shown);
    /// the other rows fill the remaining places in the app's order; hidden rows are left out.
    /// A pinned row with nothing in it right now is skipped (no gap). Rows the arrangement
    /// doesn't know yet (a new library, a new genre) are dynamic.
    static func arrange<Row>(_ rows: [Row], id: (Row) -> String, layout: [HomeRowConfig]?) -> [Row] {
        guard let layout, !layout.isEmpty else { return rows }
        let hidden = Set(layout.filter(\.hidden).map(\.id))
        let visible = rows.filter { !hidden.contains(family(of: id($0))) }
        let pinnedOrder = layout.filter { !$0.hidden }.map { ($0.id, $0.pinned) }
        let pinnedIDs = Set(pinnedOrder.filter(\.1).map(\.0))

        // The slot each pinned row asks for: its index among the arrangement's shown rows.
        var wanted: [Int: String] = [:]
        for (index, entry) in pinnedOrder.enumerated() where entry.1 { wanted[index] = entry.0 }

        var byFamily: [String: Row] = [:]
        for row in visible where pinnedIDs.contains(family(of: id(row))) {
            if byFamily[family(of: id(row))] == nil { byFamily[family(of: id(row))] = row }
        }
        var dynamic = visible.filter { !pinnedIDs.contains(family(of: id($0))) }[...]

        var out: [Row] = []
        var slot = 0
        let total = byFamily.count + dynamic.count
        while out.count < total {
            if let family = wanted[slot] {
                slot += 1
                if let row = byFamily.removeValue(forKey: family) { out.append(row) }
                continue
            }
            slot += 1
            if let next = dynamic.popFirst() {
                out.append(next)
            } else if let rest = wanted.keys.filter({ $0 >= slot }).min() {
                // Only pinned rows are left: they come next, in their order.
                slot = rest
            } else {
                break
            }
        }
        return out
    }

    // MARK: Editing

    /// Every row as the profile sees it, in order: shown rows (as arranged), then pinned rows
    /// with nothing in them right now (at their place), then removed ones. `current`: the rows
    /// the app built (before arranging). The base of every edit below.
    static func entries(current: [HomeRowInfo], layout: [HomeRowConfig]?) -> [HomeRowConfig] {
        let saved = layout ?? []
        var byID: [String: HomeRowConfig] = [:]
        for entry in saved where byID[entry.id] == nil { byID[entry.id] = entry }
        var seen = Set<String>()
        let rows = current.filter { seen.insert(family(of: $0.id)).inserted }
        let shown = arrange(rows, id: \.id, layout: saved)
        var out = shown.map { row -> HomeRowConfig in
            var entry = byID[family(of: row.id)] ?? HomeRowConfig(id: family(of: row.id))
            entry.title = row.title
            return entry
        }
        let present = Set(out.map(\.id))
        // Kept rows not on Home right now (empty, or a custom row not loaded yet).
        let kept = saved.filter { !$0.hidden }
        for (index, entry) in kept.enumerated() where !present.contains(entry.id) {
            out.insert(entry, at: min(index, out.count))
        }
        out += saved.filter { $0.hidden && !present.contains($0.id) }
        return out
    }

    /// Moves a row one place up (-1) or down (+1) among the shown ones; it then keeps that place.
    static func moving(_ id: String, by offset: Int, current: [HomeRowInfo], layout: [HomeRowConfig]?) -> [HomeRowConfig] {
        var list = entries(current: current, layout: layout)
        let shown = list.indices.filter { !list[$0].hidden }
        guard let at = shown.firstIndex(where: { list[$0].id == id }) else { return list }
        let target = at + offset
        guard shown.indices.contains(target) else { return list }
        list.swapAt(shown[at], shown[target])
        list[shown[target]].pinned = true
        return list
    }

    static func settingPinned(_ id: String, _ pinned: Bool, current: [HomeRowInfo], layout: [HomeRowConfig]?) -> [HomeRowConfig] {
        var list = entries(current: current, layout: layout)
        if let at = list.firstIndex(where: { $0.id == id }) { list[at].pinned = pinned }
        return list
    }

    /// Removes a row from Home (it stays listed, to bring back). A removed custom row is gone.
    static func hiding(_ id: String, current: [HomeRowInfo], layout: [HomeRowConfig]?) -> [HomeRowConfig] {
        var list = entries(current: current, layout: layout)
        guard let at = list.firstIndex(where: { $0.id == id }) else { return list }
        var entry = list.remove(at: at)
        guard entry.custom == nil else { return list }
        entry.hidden = true
        entry.pinned = false
        list.append(entry)
        return list
    }

    /// A removed row back on Home, dynamic, after the shown ones.
    static func restoring(_ id: String, current: [HomeRowInfo], layout: [HomeRowConfig]?) -> [HomeRowConfig] {
        var list = entries(current: current, layout: layout)
        guard let at = list.firstIndex(where: { $0.id == id }) else { return list }
        var entry = list.remove(at: at)
        entry.hidden = false
        list.insert(entry, at: list.firstIndex(where: \.hidden) ?? list.count)
        return list
    }

    /// A new row (fixed) at the end of the shown ones.
    static func adding(_ row: HomeRowConfig, current: [HomeRowInfo], layout: [HomeRowConfig]?) -> [HomeRowConfig] {
        var list = entries(current: current, layout: layout)
        var entry = row
        entry.pinned = true
        list.insert(entry, at: list.firstIndex(where: \.hidden) ?? list.count)
        return list
    }
}
