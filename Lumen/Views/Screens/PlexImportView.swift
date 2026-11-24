import SwiftUI

/// «استيراد سجل المشاهدة من Plex»: which libraries, and whether it's added to the profile's
/// own history or replaces it. Reads from Plex only; nothing is sent to it.
struct PlexImportView: View {
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
    @FocusState private var closeFocused: Bool

    init(client: PlexServerClient, sections: [PlexDirectory], profile: UserProfile) {
        self.client = client
        self.sections = sections
        self.profile = profile
        _chosen = State(initialValue: Set(sections.map(\.key)))
    }

    private var all: Bool { chosen.count == sections.count }

    var body: some View {
        VStack(spacing: 34) {
            VStack(spacing: 10) {
                Text("استيراد سجل المشاهدة من Plex").font(.system(size: 46, weight: .bold))
                HStack(spacing: 14) {
                    Text("إلى").foregroundStyle(.white.opacity(0.55))
                    ProfileAvatar(profile: profile, size: 40)
                    Text(profile.name)
                }
                .font(.system(size: 28))
            }
            switch phase {
            case .choosing: choices
            case .reading(let done, let total, let name): progress(done, total, name)
            case .finished(let watched, let started, let summary): result(watched, started, summary)
            case .failed(let message): failure(message)
            }
        }
        .padding(.top, 60)
        .padding(.horizontal, 120)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(white: 0.07).ignoresSafeArea())
        .alert("استبدال سجل «\(profile.name)»؟", isPresented: $confirmReplace) {
            Button("استبدال", role: .destructive) { start() }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("في المكتبات المختارة (\(ArabicFormat.digits(chosen.count))): يُمسح ما شاهدته في Lumen ويحل محله سجل Plex. تقدر تتراجع من الإعدادات على هذا الجهاز.")
        }
        // Back while reading: nothing has been written yet.
        .onExitCommand {
            work?.cancel()
            dismiss()
        }
    }

    // MARK: Choices

    private var choices: some View {
        HStack(alignment: .top, spacing: 60) {
            ScrollView(.vertical, showsIndicators: false) {
                SettingsCard("المكتبات") {
                    SettingsRow("كل المكتبات", value: all ? "✓" : nil) {
                        chosen = all ? [] : Set(sections.map(\.key))
                    }
                    ForEach(sections) { section in
                        Button { chosen.formSymmetricDifference([section.key]) } label: {
                            HStack(spacing: 20) {
                                Image(systemName: chosen.contains(section.key) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(chosen.contains(section.key) ? ArtworkStatusOverlay.orange : Color.gray)
                                Text(section.title).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(SettingsRowStyle(selected: false, standalone: false))
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity)
            .focusSection()

            VStack(alignment: .leading, spacing: 36) {
                SettingsCard("الطريقة", footer: mode == .merge
                    ? "يضيف الناقص فقط. ما شاهدته هنا أو في Plex يصير مشاهَدًا، والأحدث يحدد وين وقفت. لا يمسح شيئًا."
                    : "سجل Plex يحل محل سجلك في المكتبات المختارة، وما شاهدته في Lumen وليس في Plex يُمسح.") {
                    modeRow("دمج مع سجلي", .merge)
                    modeRow("استبدال سجلي", .replace)
                }
                SettingsCard(footer: "يُقرأ من حساب Plex المسجّل في التطبيق. لا يتأثر باقي المستخدمين ولا «قائمتي»، ولا يُرسل شيء إلى Plex.") {
                    SettingsRow("بدء الاستيراد", value: chosen.isEmpty ? "اختر مكتبة" : nil, arrow: true) {
                        if mode == .replace { confirmReplace = true } else { start() }
                    }
                    .disabled(chosen.isEmpty)
                }
            }
            .padding(.vertical, 20)
            .frame(width: 720)
            // As tall as the list: reached from any of its rows.
            .frame(maxHeight: .infinity, alignment: .top)
            .focusSection()
        }
    }

    private func modeRow(_ title: String, _ value: ProfileStore.ImportMode) -> some View {
        Button { mode = value } label: {
            HStack(spacing: 20) {
                Image(systemName: mode == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(mode == value ? ArtworkStatusOverlay.orange : Color.gray)
                Text(title)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(SettingsRowStyle(selected: false, standalone: false))
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

    private func progress(_ done: Int, _ total: Int, _ name: String) -> some View {
        VStack(spacing: 28) {
            ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 700)
            Text("جارٍ قراءة «\(name)» (\(ArabicFormat.digits(done + 1)) من \(ArabicFormat.digits(total)))")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.6))
            Button("إلغاء") {
                work?.cancel()
                phase = .choosing
            }
            .buttonStyle(SettingsRowStyle(selected: true, standalone: false))
            .frame(width: 320)
        }
        .padding(.top, 180)
    }

    private func result(_ watched: Int, _ started: Int, _ summary: ProfileStore.ImportSummary) -> some View {
        VStack(spacing: 34) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 90)).foregroundStyle(.green)
            SettingsCard("تم الاستيراد") {
                SettingsInfo("مشاهَد في Plex", value: ArabicFormat.digits(watched))
                SettingsInfo("غير مكتمل في Plex", value: ArabicFormat.digits(started))
                SettingsInfo("أضيف إلى سجلك", value: ArabicFormat.digits(summary.added))
                SettingsInfo("تحدّث في سجلك", value: ArabicFormat.digits(summary.updated))
                if summary.cleared > 0 { SettingsInfo("أزيل من سجلك", value: ArabicFormat.digits(summary.cleared)) }
            }
            .frame(width: 800)
            close
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 34) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 90)).foregroundStyle(.yellow)
            Text(message).font(.system(size: 30)).multilineTextAlignment(.center).frame(maxWidth: 1000)
            close
        }
        .padding(.top, 120)
    }

    private var close: some View {
        Button("إغلاق") { dismiss() }
            .buttonStyle(SettingsRowStyle(selected: true, standalone: false))
            .frame(width: 320)
            .focused($closeFocused)
            .onAppear { closeFocused = true }
    }
}
