import SwiftUI

/// What the last Home build decided, for the hidden tuning screen
/// (Settings → tap «الإصدار» five times). In memory only.
@MainActor
enum HomeDiagnostics {
    struct RowInfo: Identifiable {
        let id: String
        let title: String
        let count: Int
        /// Why it is where it is (score, kept / dropped…).
        let note: String
    }

    private(set) static var rows: [RowInfo] = []
    private(set) static var heroTitles: [String] = []
    private(set) static var builtAt: Date?

    static func record(feed: HomeFeed) {
        rows = feed.rows.map { RowInfo(id: $0.id, title: $0.title, count: $0.items.count, note: "") }
        heroTitles = feed.featured.map { "\($0.display.title) · \($0.eyebrow)" }
        builtAt = Date()
    }
}

/// Hidden screen: the profile's taste, the rows of the last Home and their scores.
struct HomeDiagnosticsView: View {
    let client: PlexServerClient

    @Environment(ProfileStore.self) private var store
    @State private var taste: TasteProfile?
    @State private var titles: [String: String] = [:]
    @State private var cleared = false

    var body: some View {
        List {
            Section("آخر بناء للرئيسية") {
                line("الوقت", HomeDiagnostics.builtAt.map(Self.time) ?? "لم تُبنَ بعد")
                line("المستخدم", store.activeProfile?.name ?? "—")
                Button(cleared ? "تم المسح، ارجع للرئيسية" : "مسح كاش الرئيسية وإعادة البناء") {
                    HomeFeed.clearSnapshots()
                    NotificationCenter.default.post(name: .libraryShouldRefresh, object: nil)
                    cleared = true
                }
            }

            Section {
                if HomeDiagnostics.rows.isEmpty { line("—", "") }
                ForEach(Array(HomeDiagnostics.rows.enumerated()), id: \.element.id) { pair in
                    let row = pair.element
                    line("\(pair.offset + 1). \(row.title)",
                         "\(row.count) عنصر" + (row.note.isEmpty ? "" : " · \(row.note)"))
                }
            } header: {
                Text("الصفوف بالترتيب")
            } footer: {
                #if os(tvOS)
                Text("رئيسية الآبل تي في تُبنى في TVFeed، وصفوفها ما تظهر هنا بعد. هذا القسم للآيفون.")
                #else
                Text("آخر بناء لرئيسية هذا الجهاز.")
                #endif
            }

            Section("البانر") {
                if HomeDiagnostics.heroTitles.isEmpty { line("—", "") }
                ForEach(Array(HomeDiagnostics.heroTitles.enumerated()), id: \.offset) { pair in
                    line("\(pair.offset + 1).", pair.element)
                }
            }

            Section("ذوق الأنواع") {
                if let taste {
                    if taste.weights.isEmpty { line("لا توجد مشاهدات كافية", "") }
                    ForEach(taste.weights.sorted { $0.value > $1.value }, id: \.key) { entry in
                        line(ArabicFormat.genre(entry.key), Self.number(entry.value))
                    }
                } else {
                    ProgressView()
                }
            }

            Section {
                if let taste {
                    ForEach(taste.titles.prefix(60)) { title in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(titles[title.key] ?? title.key).lineLimit(1)
                                Spacer()
                                Text(Self.number(title.weight)).monospacedDigit()
                            }
                            Text(detail(title))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .diagnosticsRow()
                    }
                }
            } header: {
                Text("الأعمال اللي تبني الذوق")
            } footer: {
                Text("الوزن = الحداثة × التفاعل. الحداثة = ١ ÷ (١ + الأيام ÷ ٣٠).")
            }
        }
        .navigationTitle("ضبط الرئيسية")
        .task { await load() }
    }

    private func load() async {
        let result = await UserFeed.taste(store: store, client: client)
        taste = result
        // Names for the strongest titles (from the session / disk cache when possible).
        for title in result.titles.prefix(60) where titles[title.key] == nil {
            if let item = await client.cachedMetadata(title.key) { titles[title.key] = item.title }
        }
    }

    private func detail(_ title: TasteProfile.Title) -> String {
        var parts: [String] = [title.type == "show" ? "مسلسل" : "فيلم"]
        if title.type == "show" { parts.append("\(title.watchedCount) حلقة مكتملة") }
        else if title.watchedCount > 0 { parts.append("مكتمل") }
        if title.abandoned { parts.append("متروك") }
        parts.append("حداثة \(Self.number(title.recency))")
        parts.append("تفاعل \(Self.number(title.engagement))")
        parts.append(title.genres.isEmpty ? "بدون أنواع" : title.genres.map(ArabicFormat.genre).joined(separator: "، "))
        return parts.joined(separator: " · ")
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).lineLimit(1)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
        }
        .diagnosticsRow()
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().second())
    }
}

private extension View {
    /// tvOS scrolls a list by moving focus, so plain rows must be focusable to be reached.
    @ViewBuilder
    func diagnosticsRow() -> some View {
        #if os(tvOS)
        focusable()
        #else
        self
        #endif
    }
}

/// Counts quick taps on a hidden trigger: true on the fifth tap within 2 s of each other.
struct HiddenTapCounter {
    private var count = 0
    private var last = Date.distantPast

    mutating func tap(needed: Int = 5) -> Bool {
        let now = Date()
        count = now.timeIntervalSince(last) < 2 ? count + 1 : 1
        last = now
        guard count >= needed else { return false }
        count = 0
        return true
    }
}
