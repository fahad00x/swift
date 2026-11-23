import SwiftUI

/// Small pill with the first library sync's progress (later syncs run silently); the caller
/// places it where it covers nothing. Shared by both apps.
struct LibrarySyncBanner: View {
    @State private var sync = LibrarySync.shared

    var body: some View {
        if sync.isFirstSync && sync.isSyncing {
            HStack(spacing: 16) {
                ProgressView(value: sync.progress.isFinite ? min(max(sync.progress, 0), 1) : 0)
                    .frame(width: 160)
                Text(sync.message.isEmpty ? "جارٍ تحميل المكتبة…" : sync.message)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(maxWidth: 360, alignment: .leading)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.75)))
            .allowsHitTesting(false)
        }
    }
}

/// «المكتبة على الجهاز» row for Settings.
struct LibrarySyncStatusRow: View {
    @State private var sync = LibrarySync.shared

    var body: some View {
        LabeledContent("المكتبة على الجهاز") {
            if sync.isSyncing {
                HStack(spacing: 12) {
                    Text("\(ArabicFormat.digits(Int((sync.progress.isFinite ? min(max(sync.progress, 0), 1) : 0) * 100)))٪")
                    ProgressView()
                }
            } else if let last = sync.lastSync {
                Text(last, format: .relative(presentation: .named))
            } else {
                Text("—")
            }
        }
    }
}
