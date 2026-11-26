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
        let text = ArabicFormat.digits(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        return "\(name) — \(quality == .original ? "" : "حوالي ")\(text)"
    }
}

// MARK: - Page

/// «التنزيلات»: what's on the device, what's downloading, and the space it takes.
struct DownloadsView: View {
    let client: PlexServerClient

    @State private var downloads = Downloads.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var deleting: DownloadEntry?

    var body: some View {
        BrowseStack(client: client) {
            List {
                if downloads.list.isEmpty {
                    ContentUnavailableView("ما فيه تنزيلات", systemImage: "arrow.down.circle",
                                           description: Text("اضغط زر التحميل في صفحة أي فيلم أو حلقة عشان تشاهده بدون اتصال."))
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(downloads.list) { row($0) }
                            .onDelete { offsets in
                                let list = downloads.list
                                offsets.map { list[$0].ratingKey }.forEach(downloads.delete)
                            }
                    } footer: {
                        Text(spaceText)
                    }
                }
            }
            .readableColumn(Metrics(sizeClass))
            .navigationTitle("التنزيلات")
        }
        .alert("حذف «\(deleting.map { ArabicFormat.isolated($0.item.cardTitle) } ?? "")» من الجهاز؟",
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("حذف", role: .destructive) { if let key = deleting?.ratingKey { downloads.delete(key) } }
            Button("إلغاء", role: .cancel) {}
        }
    }

    private var spaceText: String {
        let used = ByteCountFormatter.string(fromByteCount: downloads.usedBytes, countStyle: .file)
        let free = Downloads.freeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return ArabicFormat.digits("التنزيلات تاخذ \(used)" + (free.map { "، والمتبقي على الجهاز \($0)" } ?? ""))
    }

    private func row(_ entry: DownloadEntry) -> some View {
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
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.item.isEpisode ? (entry.item.grandparentTitle ?? entry.item.title) : entry.item.title)
                        .font(.headline).lineLimit(1)
                    if entry.item.isEpisode {
                        Text(entry.item.cardSubtitle ?? entry.item.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    status(entry)
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

    @ViewBuilder
    private func status(_ entry: DownloadEntry) -> some View {
        let size = { (n: Int64) in ArabicFormat.digits(ByteCountFormatter.string(fromByteCount: n, countStyle: .file)) }
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
