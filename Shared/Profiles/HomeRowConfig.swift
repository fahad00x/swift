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
}
