import SwiftUI

/// Progress of the first library sync (later syncs run silently). Shared by both apps.
struct LibrarySyncBanner: View {
    @State private var sync = LibrarySync.shared

    var body: some View {
        if sync.isFirstSync && sync.isSyncing {
            HStack(spacing: 16) {
                ProgressView(value: sync.progress)
                    .frame(maxWidth: 260)
                Text(sync.message.isEmpty ? "جارٍ تجهيز المكتبة على الجهاز…" : sync.message)
                    .font(.callout)
                    .lineLimit(1)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(Capsule().fill(Color.black.opacity(0.8)))
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 40)
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
                    Text("\(ArabicFormat.digits(Int(sync.progress * 100)))٪")
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
