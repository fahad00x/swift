import SwiftUI

/// «استيراد سجل المشاهدة من Plex»: which libraries, and whether it's added to the profile's own
/// history or replaces it. Reads from Plex only; nothing is sent to it. (Same as the Apple TV.)
struct PlexImportPage: View {
    let client: PlexServerClient
    let sections: [PlexDirectory]
    let profile: UserProfile

    @Environment(ProfileStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case choosing
        case reading(done: Int, total: Int, name: String)
        case finished(watched: Int, started: Int, ProfileStore.ImportSummary)
        case failed(String)
    }

    @State private var chosen: Set<String>
    @State private var mode: ProfileStore.ImportMode = .merge
    @State private var phase: Phase = .choosing
    @State private var confirmReplace = false
    @State private var work: Task<Void, Never>?
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(client: PlexServerClient, sections: [PlexDirectory], profile: UserProfile) {
        self.client = client
        self.sections = sections
        self.profile = profile
        _chosen = State(initialValue: Set(sections.map(\.key)))
    }

    private var all: Bool { chosen.count == sections.count }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Text("إلى").foregroundStyle(.secondary)
                    ProfileAvatar(profile: profile, size: 32)
                    Text(profile.name).font(.headline)
                }
            }
            switch phase {
            case .choosing: choices
            case .reading(let done, let total, let name): progress(done, total, name)
            case .finished(let watched, let started, let summary): result(watched, started, summary)
            case .failed(let message): failure(message)
            }
        }
        .readableColumn(Metrics(sizeClass))
        .navigationTitle("استيراد من Plex")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isReading)
        .alert("استبدال سجل «\(profile.name)»؟", isPresented: $confirmReplace) {
            Button("استبدال", role: .destructive) { start() }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("في المكتبات المختارة (\(ArabicFormat.digits(chosen.count))): يُمسح ما شاهدته في Lumen ويحل محله سجل Plex. تقدر تتراجع من الإعدادات على هذا الجهاز.")
        }
        // Leaving while reading: nothing has been written yet.
        .onDisappear { work?.cancel() }
    }

    private var isReading: Bool {
        if case .reading = phase { return true }
        return false
    }

    // MARK: Choices

    @ViewBuilder
    private var choices: some View {
        Section("المكتبات") {
            check("كل المكتبات", isOn: all) { chosen = all ? [] : Set(sections.map(\.key)) }
            ForEach(sections) { section in
                check(section.title, isOn: chosen.contains(section.key)) { chosen.formSymmetricDifference([section.key]) }
            }
        }
        Section {
            Picker("الطريقة", selection: $mode) {
                Text("دمج مع سجلي").tag(ProfileStore.ImportMode.merge)
                Text("استبدال سجلي").tag(ProfileStore.ImportMode.replace)
            }
            .pickerStyle(.segmented)
        } footer: {
            Text(mode == .merge
                 ? "يضيف الناقص فقط. ما شاهدته هنا أو في Plex يصير مشاهَدًا، والأحدث يحدد وين وقفت. لا يمسح شيئًا."
                 : "سجل Plex يحل محل سجلك في المكتبات المختارة، وما شاهدته في Lumen وليس في Plex يُمسح.")
        }
        Section {
            Button("بدء الاستيراد") {
                if mode == .replace { confirmReplace = true } else { start() }
            }
            .disabled(chosen.isEmpty)
        } footer: {
            Text("يُقرأ من حساب Plex المسجّل في التطبيق. لا يتأثر باقي المستخدمين ولا «قائمتي»، ولا يُرسل شيء إلى Plex.")
        }
    }

    private func check(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? ArtworkStatusOverlay.orange : Color.secondary)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
    }

    // MARK: Work

    private func start() {
        let picked = sections.filter { chosen.contains($0.key) }
        let mode = mode
        phase = .reading(done: 0, total: picked.count, name: picked.first?.title ?? "")
        work = Task {
            var items: [ProfileStore.ImportedState] = []
            for (index, section) in picked.enumerated() {
                phase = .reading(done: index, total: picked.count, name: section.title)
                do {
                    items += try await client.history(section: section).map { item in
                        let watched = (item.viewCount ?? 0) > 0
                        var info = item.mediaInfo
                        info.sectionKey = info.sectionKey ?? section.key
                        return .init(info: info, offsetMs: watched ? 0 : (item.viewOffset ?? 0), watched: watched,
                                     lastViewedAt: item.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? .distantPast)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    // All or nothing: a half-read history must not replace anything.
                    phase = .failed("تعذّرت قراءة «\(section.title)» من Plex. لم يتغيّر شيء في سجلك.")
                    return
                }
                guard !Task.isCancelled else { return }
            }
            guard let summary = store.importHistory(items, sections: Set(picked.map(\.key)), mode: mode, into: profile.id) else {
                phase = .failed("تغيّر المستخدم أثناء الاستيراد. لم يتغيّر شيء.")
                return
            }
            phase = .finished(watched: items.filter(\.watched).count, started: items.filter { !$0.watched }.count, summary)
            NotificationCenter.default.post(name: .plexPlaybackDidEnd, object: nil)
        }
    }

    @ViewBuilder
    private func progress(_ done: Int, _ total: Int, _ name: String) -> some View {
        Section {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
            Text("جارٍ قراءة «\(name)» (\(ArabicFormat.digits(done + 1)) من \(ArabicFormat.digits(total)))")
                .foregroundStyle(.secondary)
            Button("إلغاء", role: .cancel) {
                work?.cancel()
                phase = .choosing
            }
        }
    }

    @ViewBuilder
    private func result(_ watched: Int, _ started: Int, _ summary: ProfileStore.ImportSummary) -> some View {
        Section {
            Label("تم الاستيراد", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            LabeledContent("مشاهَد في Plex", value: ArabicFormat.digits(watched))
            LabeledContent("غير مكتمل في Plex", value: ArabicFormat.digits(started))
            LabeledContent("أضيف إلى سجلك", value: ArabicFormat.digits(summary.added))
            LabeledContent("تحدّث في سجلك", value: ArabicFormat.digits(summary.updated))
            if summary.cleared > 0 { LabeledContent("أزيل من سجلك", value: ArabicFormat.digits(summary.cleared)) }
        }
        Section { Button("تم") { dismiss() } }
    }

    @ViewBuilder
    private func failure(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        }
        Section {
            Button("المحاولة من جديد") { phase = .choosing }
            Button("إغلاق") { dismiss() }
        }
    }
}
