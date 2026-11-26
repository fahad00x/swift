import SwiftUI

// MARK: - Button

/// Round button on a details page: download → progress (tap to stop) → done (tap for a menu).
struct DownloadButton: View {
    let item: PlexItem
    let client: PlexServerClient
    var size: CGFloat = 46

    @State private var downloads = Downloads.shared
    @State private var confirmDelete = false
    @State private var starting = false
    @State private var choosing = false

    var body: some View {
        let entry = downloads.entry(item.ratingKey)
        Group {
            switch entry?.state {
            case .done?:
                Menu {
                    Button("حذف التنزيل", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: { circle { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) } }
            case .downloading?, .waiting?:
                Menu {
                    Button("إيقاف وحذف", systemImage: "xmark.circle", role: .destructive) { downloads.delete(item.ratingKey) }
                } label: { circle { ProgressRing(fraction: entry?.fraction ?? 0) } }
            case .failed?:
                Menu {
                    Button("إكمال التحميل", systemImage: "arrow.clockwise") { downloads.resume(item.ratingKey) }
                    Button("حذف", systemImage: "trash", role: .destructive) { downloads.delete(item.ratingKey) }
                } label: { circle { Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(.yellow) } }
            case nil:
                Button {
                    guard !starting else { return }
                    choosing = true
                } label: {
                    circle {
                        if starting { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.down") }
                    }
                }
            }
        }
        .accessibilityLabel("تحميل")
        .downloadQualityDialog(isPresented: $choosing, item: item) { quality in
            starting = true
            Task { await downloads.download(item, client: client, quality: quality); starting = false }
        }
        .alert("حذف «\(ArabicFormat.isolated(item.cardTitle))» من الجهاز؟", isPresented: $confirmDelete) {
            Button("حذف", role: .destructive) { downloads.delete(item.ratingKey) }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("يبقى على الخادم، وتقدر تحمّله مرة ثانية. تقدّم المشاهدة ما يتأثر.")
        }
    }

    private func circle<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.headline)
            .frame(width: size, height: size)
            .background(Circle().fill(.white.opacity(0.18)))
            .foregroundStyle(.white)
    }
}

/// Amber ring that fills with the download.
struct ProgressRing: View {
    let fraction: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 3)
            Circle().trim(from: 0, to: max(0.02, fraction))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "stop.fill").font(.system(size: 9))
        }
        .frame(width: 22, height: 22)
        .animation(.linear(duration: 0.3), value: fraction)
    }
}

// MARK: - Quality

extension View {
    /// «جودة التحميل»: the original, or a smaller copy Plex converts (with its size, about).
    /// A show or season: sizes per episode.
    func downloadQualityDialog(isPresented: Binding<Bool>, item: PlexItem,
                               perEpisode: Bool = false, choose: @escaping (PlaybackQuality) -> Void) -> some View {
        confirmationDialog("جودة التحميل", isPresented: isPresented, titleVisibility: .visible) {
            ForEach(DownloadQuality.choices(for: item), id: \.self) { quality in
                Button(DownloadQuality.label(quality, item: item, perEpisode: perEpisode)) { choose(quality) }
            }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text(perEpisode ? "الحجم تقريبي لكل حلقة." : "الأصغر ياخذ مساحة أقل. يحوّله خادم Plex وقت التحميل، فيتأخر شوي.")
        }
    }
}

enum DownloadQuality {
    /// The original, then the smaller copies that are smaller than it.
    static func choices(for item: PlexItem) -> [PlaybackQuality] {
        let bitrate = item.media.first?.bitrate ?? .max
        let smaller: [PlaybackQuality] = [.kbps8000, .kbps4000, .kbps2000, .kbps1500, .kbps750]
        return [.original] + smaller.filter { ($0.maxBitrateKbps ?? 0) < bitrate }
    }

    static func label(_ quality: PlaybackQuality, item: PlexItem, perEpisode: Bool) -> String {
        let name = quality == .original ? "الأصلي" : quality.title
        guard !perEpisode, let size = Downloads.estimatedSize(item, quality: quality) else { return name }
        let text = ArabicFormat.fileSize(size)
        return "\(name) — \(quality == .original ? "" : "حوالي ")\(text)"
    }
}

// MARK: - Page

/// A show's downloaded episodes, shown as one row on «التنزيلات».
struct DownloadedShow: Hashable, Identifiable {
    let key: String
    let title: String
    var id: String { key }

    static func of(_ entry: DownloadEntry) -> DownloadedShow? {
        guard entry.item.isEpisode else { return nil }
        let title = entry.item.grandparentTitle ?? entry.item.title
        return DownloadedShow(key: entry.item.grandparentRatingKey ?? title, title: title)
    }

    /// Its episodes, by season and episode number.
    func episodes(in list: [DownloadEntry]) -> [DownloadEntry] {
        list.filter { Self.of($0) == self }.sorted {
            ($0.item.parentIndex ?? 0, $0.item.index ?? 0) < ($1.item.parentIndex ?? 0, $1.item.index ?? 0)
        }
    }
}

/// «التنزيلات»: what's on the device, what's downloading, and the space it takes. A show is one
/// row («٣ حلقات • 921 MB») that opens its episodes; movies have a row each.
struct DownloadsView: View {
    let client: PlexServerClient

    @State private var downloads = Downloads.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var deleting: DownloadEntry?
    @State private var deletingShow: DownloadedShow?

    private enum Row: Identifiable {
        case movie(DownloadEntry)
        case show(DownloadedShow, [DownloadEntry])
        var id: String {
            switch self {
            case .movie(let entry): return entry.id
            case .show(let show, _): return "show-" + show.key
            }
        }
    }

    /// Newest first, a show where its newest episode is.
    private var rows: [Row] {
        let list = downloads.list
        var seen = Set<DownloadedShow>()
        return list.compactMap { entry in
            guard let show = DownloadedShow.of(entry) else { return .movie(entry) }
            guard seen.insert(show).inserted else { return nil }
            return .show(show, show.episodes(in: list))
        }
    }

    var body: some View {
        BrowseStack(client: client) {
            List {
                if downloads.list.isEmpty {
                    ContentUnavailableView("ما فيه تنزيلات", systemImage: "arrow.down.circle",
                                           description: Text("اضغط زر التحميل في صفحة أي فيلم أو حلقة عشان تشاهده بدون اتصال."))
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        let rows = rows
                        ForEach(rows) { row in
                            switch row {
                            case .movie(let entry):
                                DownloadRow(entry: entry, client: client, deleting: $deleting)
                            case .show(let show, let episodes):
                                NavigationLink(value: show) { ShowDownloadRow(show: show, episodes: episodes) }
                                    .contextMenu {
                                        Button("حذف الحلقات", systemImage: "trash", role: .destructive) { deletingShow = show }
                                    }
                            }
                        }
                        .onDelete { offsets in
                            for row in offsets.map({ rows[$0] }) {
                                switch row {
                                case .movie(let entry): downloads.delete(entry.ratingKey)
                                // Many files at once: asked first.
                                case .show(let show, _): deletingShow = show
                                }
                            }
                        }
                    } footer: {
                        Text(spaceText)
                    }
                }
            }
            .readableColumn(Metrics(sizeClass))
            .navigationTitle("التنزيلات")
            .navigationDestination(for: DownloadedShow.self) { show in
                DownloadedEpisodesView(show: show, client: client)
            }
        }
        .deleteAlert($deleting)
        .alert("حذف حلقات «\(deletingShow.map { ArabicFormat.isolated($0.title) } ?? "")» من الجهاز؟",
               isPresented: Binding(get: { deletingShow != nil }, set: { if !$0 { deletingShow = nil } })) {
            Button("حذف", role: .destructive) {
                guard let show = deletingShow else { return }
                show.episodes(in: downloads.list).forEach { downloads.delete($0.ratingKey) }
            }
            Button("إلغاء", role: .cancel) {}
        } message: {
            let count = deletingShow.map { $0.episodes(in: downloads.list).count } ?? 0
            Text(ArabicFormat.episodeCount(count))
        }
    }

    private var spaceText: String {
        let used = ArabicFormat.fileSize(downloads.usedBytes)
        let free = Downloads.freeBytes.map { ArabicFormat.fileSize($0) }
        return "التنزيلات تاخذ \(used)" + (free.map { "، والمتبقي على الجهاز \($0)" } ?? "")
    }
}

/// A show's downloaded episodes; swipe to delete one.
private struct DownloadedEpisodesView: View {
    let show: DownloadedShow
    let client: PlexServerClient

    @State private var downloads = Downloads.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var deleting: DownloadEntry?

    var body: some View {
        let episodes = show.episodes(in: downloads.list)
        List {
            ForEach(episodes) { DownloadRow(entry: $0, client: client, deleting: $deleting, inShow: true) }
                .onDelete { offsets in offsets.map { episodes[$0].ratingKey }.forEach(downloads.delete) }
        }
        .readableColumn(Metrics(sizeClass))
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
        .deleteAlert($deleting)
        // The last one deleted: back to the list.
        .onChange(of: episodes.isEmpty) { _, empty in if empty { dismiss() } }
    }
}

/// The show: its poster, «٣ حلقات • 921 MB», and how many are still downloading.
private struct ShowDownloadRow: View {
    let show: DownloadedShow
    let episodes: [DownloadEntry]

    @State private var downloads = Downloads.shared
    @Environment(ProfileStore.self) private var store

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let image = episodes.lazy.compactMap({ downloads.image($0.ratingKey) }).first {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color(white: 0.15).overlay(Image(systemName: "tv").foregroundStyle(.secondary))
                }
            }
            .frame(width: 60, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(show.title).font(.headline).lineLimit(1)
                Text(details).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// «٣ حلقات • 921 MB».
    private var details: String {
        let bytes = episodes.reduce(Int64(0)) { $0 + ($1.state == .done ? $1.total : $1.written) }
        return ArabicFormat.episodeCount(episodes.count) + ArabicFormat.separator + ArabicFormat.fileSize(bytes)
    }

    /// «يتحمّل ٢» while some are downloading, else «شاهدت ١ من ٣».
    private var note: String? {
        let loading = episodes.filter { $0.state == .downloading || $0.state == .waiting }.count
        if loading > 0 { return "يتحمّل " + ArabicFormat.digits(loading) }
        let watched = episodes.filter { store.state(for: $0.ratingKey)?.watched == true }.count
        guard watched > 0 else { return nil }
        return watched == episodes.count ? "شاهدتها كلها ✓"
            : "شاهدت \(ArabicFormat.digits(watched)) من \(ArabicFormat.digits(episodes.count))"
    }
}

/// A movie or an episode: tap to play, with how far it was watched (or ✓).
private struct DownloadRow: View {
    let entry: DownloadEntry
    let client: PlexServerClient
    @Binding var deleting: DownloadEntry?
    /// On its show's page: the episode as the title.
    var inShow = false

    @State private var downloads = Downloads.shared
    @Environment(ProfileStore.self) private var store

    var body: some View {
        let state = store.state(for: entry.ratingKey)
        let watched = state?.watched == true
        Button {
            guard entry.state == .done else { return }
            Task { await PlaybackManager.shared.play(entry.item, client: client) }
        } label: {
            HStack(spacing: 14) {
                Group {
                    if let image = downloads.image(entry.ratingKey, backdrop: entry.item.isEpisode) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Color(white: 0.15).overlay(Image(systemName: "film").foregroundStyle(.secondary))
                    }
                }
                .frame(width: entry.item.isEpisode ? 120 : 60, height: entry.item.isEpisode ? 68 : 90)
                .overlay(alignment: .bottom) {
                    // How far it was watched, on the picture like the cards.
                    if !watched, let state, state.offsetMs > 0, state.durationMs > 0 {
                        WatchedBar(fraction: Double(state.offsetMs) / Double(state.durationMs))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title).font(.headline).lineLimit(1)
                        if watched {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(Theme.accent)
                                .accessibilityLabel("شوهد")
                        }
                    }
                    if let subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    status
                }
                Spacer(minLength: 0)
                if entry.state == .done {
                    Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .contextMenu {
            if entry.state == .failed {
                Button("إكمال التحميل", systemImage: "arrow.clockwise") { downloads.resume(entry.ratingKey) }
            }
            Button("حذف", systemImage: "trash", role: .destructive) { deleting = entry }
        }
    }

    private var title: String {
        guard entry.item.isEpisode else { return entry.item.title }
        return inShow ? (ArabicFormat.episodeCode(season: entry.item.parentIndex, episode: entry.item.index) ?? entry.item.title)
                      : (entry.item.grandparentTitle ?? entry.item.title)
    }

    private var subtitle: String? {
        guard entry.item.isEpisode else { return nil }
        return inShow ? entry.item.title : (entry.item.cardSubtitle ?? entry.item.title)
    }

    @ViewBuilder
    private var status: some View {
        let size = { (n: Int64) in ArabicFormat.fileSize(n) }
        switch entry.state {
        case .done:
            Text(size(entry.total) + (entry.quality.flatMap(PlaybackQuality.init(rawValue:)).map { " • " + $0.title } ?? " • الأصلي"))
                .font(.caption).foregroundStyle(.secondary)
        case .downloading, .waiting:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: entry.fraction).tint(Theme.accent)
                    .environment(\.layoutDirection, .leftToRight)
                Text("\(size(entry.written)) من \(entry.total > 0 ? (entry.estimated ? "حوالي " : "") + size(entry.total) : "…")"
                     + (entry.quality.flatMap(PlaybackQuality.init(rawValue:)).map { " • " + $0.title } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .failed:
            HStack(spacing: 8) {
                Text(entry.error ?? "توقف التحميل").font(.caption).foregroundStyle(.yellow)
                Button("إكمال") { downloads.resume(entry.ratingKey) }.font(.caption.weight(.semibold))
            }
        }
    }
}

/// Thin watched-so-far bar along the bottom of a picture.
private struct WatchedBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.black.opacity(0.5))
                Rectangle().fill(Theme.accent).frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 4)
        .environment(\.layoutDirection, .leftToRight)
    }
}

private extension View {
    /// «حذف «…» من الجهاز؟» for one movie or episode.
    func deleteAlert(_ entry: Binding<DownloadEntry?>) -> some View {
        alert("حذف «\(entry.wrappedValue.map { ArabicFormat.isolated($0.item.cardTitle) } ?? "")» من الجهاز؟",
              isPresented: Binding(get: { entry.wrappedValue != nil }, set: { if !$0 { entry.wrappedValue = nil } })) {
            Button("حذف", role: .destructive) { if let key = entry.wrappedValue?.ratingKey { Downloads.shared.delete(key) } }
            Button("إلغاء", role: .cancel) {}
        }
    }
}
