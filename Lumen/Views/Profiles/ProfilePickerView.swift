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

    @State private var chosenID: String?
    @State private var choosingToEdit = false

    /// Circle 170, gap 25 (pitch 195).
    private let circle: CGFloat = 170

    var body: some View {
        ZStack {
            // Like the system user picker: only a blurred image, one centred row of circles.
            ProfilePickerBackdrop(client: client, sections: sections)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 25) {
                    ForEach(store.profiles) { profile in tile(profile) }
                    addTile
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 40)
                .frame(minWidth: 1920)
            }
            .scrollClipDisabled()
            .focusSection()
            .defaultFocus($focused, store.profiles.first?.id)
            .frame(maxHeight: .infinity)

            // Optional «تعديل» glass pill at the bottom centre.
            VStack {
                Spacer()
                Button("تعديل") { choosingToEdit = true }
                    .buttonStyle(PickerGlassPillStyle())
                    .padding(.bottom, 70)
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
        .confirmationDialog("تعديل مستخدم", isPresented: $choosingToEdit) {
            ForEach(store.profiles) { profile in
                Button(profile.name) { authorize(profile) { editor = .edit(profile) } }
            }
            Button("إلغاء", role: .cancel) {}
        }
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
        return VStack(spacing: 22) {
            Button { choose(profile) } label: {
                ProfileInitialsCircle(profile: profile, size: circle)
            }
            .buttonStyle(PickerCircleStyle(chosen: chosenID == profile.id))
            .focused($focused, equals: profile.id)
            .contextMenu {
                Button("تعديل", systemImage: "pencil") { authorize(profile) { editor = .edit(profile) } }
                if !profile.isOwner {
                    Button("حذف", systemImage: "trash", role: .destructive) {
                        authorize(profile) { pendingDelete = profile }
                    }
                }
            }

            Text(profile.name)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(isFocused ? Color.white : Color.white.opacity(0.6))
                .lineLimit(1)
        }
        .frame(width: circle)
        .animation(.easeOut(duration: 0.2), value: isFocused)
    }

    /// «+» in a translucent glass circle.
    private var addTile: some View {
        let isFocused = focused == "add"
        return VStack(spacing: 22) {
            Button { editor = .create } label: {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                    Image(systemName: "plus")
                        .font(.system(size: 60, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .frame(width: circle, height: circle)
            }
            .buttonStyle(PickerCircleStyle(chosen: false))
            .focused($focused, equals: "add")

            Text("إضافة")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(isFocused ? Color.white : Color.white.opacity(0.6))
        }
        .frame(width: circle)
        .animation(.easeOut(duration: 0.2), value: isFocused)
    }

    private func choose(_ profile: UserProfile) {
        guard profile.hasPIN else {
            enter(profile)
            return
        }
        pin = PinRequest(title: "أدخل رمز «\(profile.name)»", profiles: [profile]) {
            enter(profile)
        }
    }

    /// The chosen circle zooms slightly, then the screen cross-fades into Home (~0.4 s).
    private func enter(_ profile: UserProfile) {
        withAnimation(.easeOut(duration: 0.2)) { chosenID = profile.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeInOut(duration: 0.4)) { store.activate(profile) }
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

/// Focus: the circle scales ~1.12 with a soft shadow and a subtle light rim (no ring).
private struct PickerCircleStyle: ButtonStyle {
    let chosen: Bool

    func makeBody(configuration: Configuration) -> some View { CircleBody(configuration: configuration, chosen: chosen) }

    private struct CircleBody: View {
        let configuration: ButtonStyleConfiguration
        let chosen: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.05)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
                        .opacity(isFocused ? 1 : 0)
                }
                .contentShape(Circle())
                .scaleEffect(chosen ? 1.2 : (configuration.isPressed ? 1.06 : (isFocused ? 1.12 : 1)))
                .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 22, y: 12)
                .animation(.easeOut(duration: 0.2), value: isFocused)
        }
    }
}

/// Small glass pill («تعديل»).
private struct PickerGlassPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { PillBody(configuration: configuration) }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(isFocused ? Color.black : Color.white.opacity(0.85))
                .environment(\.colorScheme, isFocused ? .light : .dark)
                .padding(.horizontal, 34)
                .frame(height: 56)
                .background {
                    if isFocused {
                        Capsule().fill(Color.white)
                    } else {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    }
                }
                .scaleEffect(isFocused ? 1.06 : 1)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}
