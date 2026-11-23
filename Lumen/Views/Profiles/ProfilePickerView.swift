import SwiftUI

/// «مين يشاهد؟» — shown on every launch (unless «تذكّر آخر مستخدم» is on) and from
/// the avatar on Home / «تبديل المستخدم» in Settings.
struct ProfilePickerView: View {
    let client: PlexServerClient
    let sections: [PlexDirectory]

    @Environment(ProfileStore.self) private var store
    @State private var editor: EditorTarget?
    @State private var pin: PinRequest?
    @State private var pendingDelete: UserProfile?
    @FocusState private var focused: String?

    enum EditorTarget: Identifiable {
        case create
        case edit(UserProfile)
        var id: String {
            switch self {
            case .create: return "new"
            case .edit(let p): return p.id
            }
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.1), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 80) {
                Text("مين يشاهد؟")
                    .font(.system(size: 66, weight: .bold))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 64) {
                        ForEach(store.profiles) { profile in tile(profile) }
                        addTile
                    }
                    .padding(.horizontal, 90)
                    .padding(.vertical, 50)
                    .frame(minWidth: 1920)
                }
                .scrollClipDisabled()
                .focusSection()
                .defaultFocus($focused, store.profiles.first?.id)

                Text("اضغط مطوّلاً على أي مستخدم لتعديله أو حذفه")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .fullScreenCover(item: $editor) { target in
            switch target {
            case .create:
                ProfileEditorView(client: client, sections: sections, existing: nil)
            case .edit(let profile):
                ProfileEditorView(client: client, sections: sections, existing: profile)
            }
        }
        .pinRequest($pin)
        .alert("حذف «\(pendingDelete?.name ?? "")»؟", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("حذف", role: .destructive) {
                if let p = pendingDelete { store.delete(p) }
                pendingDelete = nil
            }
            Button("إلغاء", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("سيُحذف تقدّم المشاهدة وقائمته من كل الأجهزة.")
        }
    }

    private func tile(_ profile: UserProfile) -> some View {
        let isFocused = focused == profile.id
        return VStack(spacing: 30) {
            Button { choose(profile) } label: {
                ProfileAvatar(profile: profile, size: 230)
            }
            .buttonStyle(.card)
            .focused($focused, equals: profile.id)
            .contextMenu {
                Button("تعديل", systemImage: "pencil") { authorize(profile) { editor = .edit(profile) } }
                if !profile.isOwner {
                    Button("حذف", systemImage: "trash", role: .destructive) {
                        authorize(profile) { pendingDelete = profile }
                    }
                }
            }

            HStack(spacing: 10) {
                if profile.hasPIN { Image(systemName: "lock.fill").font(.caption) }
                Text(profile.name).lineLimit(1)
            }
            .font(.title3.weight(isFocused ? .bold : .medium))
            .foregroundStyle(isFocused ? .white : .white.opacity(0.6))
            if profile.isKids {
                Text("أطفال")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 14).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.15)))
            }
        }
        .frame(width: 260)
        .animation(.easeOut(duration: 0.2), value: isFocused)
    }

    private var addTile: some View {
        let isFocused = focused == "add"
        return VStack(spacing: 30) {
            Button { editor = .create } label: {
                ZStack {
                    Circle().fill(Color.white.opacity(0.12))
                    Image(systemName: "plus")
                        .font(.system(size: 90, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(width: 230, height: 230)
            }
            .buttonStyle(.card)
            .focused($focused, equals: "add")

            Text("إضافة مستخدم")
                .font(.title3.weight(isFocused ? .bold : .medium))
                .foregroundStyle(isFocused ? .white : .white.opacity(0.6))
        }
        .frame(width: 260)
    }

    private func choose(_ profile: UserProfile) {
        guard profile.hasPIN else {
            store.activate(profile)
            return
        }
        pin = PinRequest(title: "أدخل رمز «\(profile.name)»", profiles: [profile]) {
            store.activate(profile)
        }
    }

    /// Editing / deleting a profile with a PIN (or a kids profile) asks for the PIN first.
    private func authorize(_ profile: UserProfile, then action: @escaping () -> Void) {
        let editors = ProfileGate.editors(for: profile, store: store)
        guard !editors.isEmpty else { action(); return }
        let subtitle = profile.isKids ? "حساب الأطفال يحتاج رمز المستخدم الرئيسي" : nil
        pin = PinRequest(title: "أدخل الرمز لتعديل «\(profile.name)»", subtitle: subtitle, profiles: editors, onSuccess: action)
    }
}
