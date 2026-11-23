import SwiftUI

// MARK: - Who's watching?

struct ProfilePickerView: View {
    let client: PlexServerClient
    let sections: [PlexDirectory]

    @Environment(ProfileStore.self) private var store
    @State private var editor: EditorTarget?
    @State private var pin: PinRequest?
    @State private var pendingDelete: UserProfile?

    enum EditorTarget: Identifiable {
        case create
        case edit(UserProfile)
        var id: String {
            switch self {
            case .create: return "new"
            case .edit(let p): return p.id
            }
        }
        var profile: UserProfile? {
            if case .edit(let p) = self { return p }
            return nil
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 24, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(spacing: 36) {
                Text("مين يشاهد؟")
                    .font(.system(size: 34, weight: .bold))
                    .padding(.top, 60)

                LazyVGrid(columns: columns, spacing: 28) {
                    ForEach(store.profiles) { profile in tile(profile) }
                    addTile
                }
                .padding(.horizontal, 24)

                Text("اضغط مطوّلاً على أي مستخدم لتعديله أو حذفه")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .background(LinearGradient(colors: [Color(white: 0.1), .black], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .sheet(item: $editor) { target in
            ProfileEditorView(client: client, sections: sections, existing: target.profile)
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
        Button { choose(profile) } label: {
            VStack(spacing: 10) {
                ProfileAvatar(profile: profile, size: 110)
                HStack(spacing: 4) {
                    if profile.hasPIN { Image(systemName: "lock.fill").font(.caption2) }
                    Text(profile.name).font(.headline).lineLimit(1)
                }
                if profile.isKids {
                    Text("أطفال")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.15)))
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { authorize(profile) { editor = .edit(profile) } } label: {
                Label("تعديل", systemImage: "pencil")
            }
            if !profile.isOwner {
                Button(role: .destructive) { authorize(profile) { pendingDelete = profile } } label: {
                    Label("حذف", systemImage: "trash")
                }
            }
        }
    }

    private var addTile: some View {
        Button { editor = .create } label: {
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.12))
                    Image(systemName: "plus").font(.system(size: 40, weight: .semibold))
                }
                .frame(width: 110, height: 110)
                Text("إضافة مستخدم").font(.headline)
            }
        }
        .buttonStyle(.plain)
    }

    private func choose(_ profile: UserProfile) {
        guard profile.hasPIN else { store.activate(profile); return }
        pin = PinRequest(title: "أدخل رمز «\(profile.name)»", profiles: [profile]) { store.activate(profile) }
    }

    private func authorize(_ profile: UserProfile, then action: @escaping () -> Void) {
        let editors = ProfileGate.editors(for: profile, store: store)
        guard !editors.isEmpty else { action(); return }
        let subtitle = profile.isKids ? "حساب الأطفال يحتاج رمز المستخدم الرئيسي" : nil
        pin = PinRequest(title: "أدخل الرمز لتعديل «\(profile.name)»", subtitle: subtitle, profiles: editors, onSuccess: action)
    }
}

// MARK: - Editor

struct ProfileEditorView: View {
    let client: PlexServerClient
    let sections: [PlexDirectory]
    let existing: UserProfile?

    @Environment(ProfileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: UserProfile
    @State private var settingPIN = false
    @State private var confirmDelete = false

    init(client: PlexServerClient, sections: [PlexDirectory], existing: UserProfile?) {
        self.client = client
        self.sections = sections
        self.existing = existing
        let keys = sections.map(\.key)
        _draft = State(initialValue: existing ?? UserProfile(
            name: "",
            symbol: ProfileStyle.symbols.randomElement() ?? "person.fill",
            colorHex: ProfileStyle.colors.randomElement() ?? "#F5A524",
            scopes: keys.map { ScopeID(.all, $0).raw },
            knownSections: keys))
    }

    private var trimmedName: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        ProfileAvatar(profile: draft, size: 110)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    TextField("الاسم", text: $draft.name)
                }

                Section("اللون") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(ProfileStyle.colors, id: \.self) { hex in
                                Button { draft.colorHex = hex } label: {
                                    Circle().fill(Color(hex: hex))
                                        .frame(width: 40, height: 40)
                                        .overlay { if hex == draft.colorHex { Image(systemName: "checkmark").foregroundStyle(.white) } }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("الصورة الرمزية") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                        ForEach(ProfileStyle.symbols, id: \.self) { name in
                            Button { draft.symbol = name } label: {
                                ProfileAvatar(symbol: name, colorHex: name == draft.symbol ? draft.colorHex : "#3A3A3C", size: 44)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    if !draft.isOwner {
                        Toggle("حساب أطفال", isOn: $draft.isKids)
                    }
                    if draft.hasPIN {
                        Button("تغيير رمز PIN") { settingPIN = true }
                        Button("إزالة رمز PIN", role: .destructive) { draft.pinHash = nil }
                    } else {
                        Button("تعيين رمز PIN (٤ أرقام)") { settingPIN = true }
                    }
                } footer: {
                    if draft.isKids {
                        Text("يظهر فقط المحتوى المناسب للأطفال (G وPG وTV-Y وTV-Y7 وTV-G وTV-PG). تغيير إعداداته يحتاج رمز المستخدم الرئيسي.")
                    } else if draft.isOwner {
                        Text("رمز المستخدم الرئيسي يحمي إعدادات حسابات الأطفال.")
                    }
                }

                Section("المحتوى") {
                    NavigationLink {
                        LibrariesPage(client: client, sections: sections, scopes: $draft.scopes)
                    } label: {
                        LabeledContent("المكتبات", value: draft.scopes.isEmpty ? "لا شيء" : "\(ArabicFormat.digits(draft.scopes.count)) مفتوحة")
                    }
                    NavigationLink {
                        GenresPage(client: client, sections: sections, genres: $draft.genres)
                    } label: {
                        LabeledContent("الأنواع المفضّلة",
                                       value: draft.genres.isEmpty ? "الكل" : ArabicFormat.list(ArabicFormat.genres(draft.genres, limit: 3)))
                    }
                    NavigationLink {
                        ScopeOrderPage(sections: sections, scopes: $draft.scopes)
                    } label: {
                        Text("ترتيب المكتبات")
                    }
                    .disabled(draft.scopes.count < 2)
                }

                if let existing, !existing.isOwner {
                    Section {
                        Button("حذف المستخدم", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(existing == nil ? "إضافة مستخدم" : "تعديل المستخدم")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "إنشاء" : "حفظ") { save() }.disabled(trimmedName.isEmpty)
                }
            }
        }
        .fullScreenCover(isPresented: $settingPIN) {
            PinSetupView { pin in
                draft.pinHash = ProfilePIN.hash(pin, profileID: draft.id)
                settingPIN = false
            } onCancel: {
                settingPIN = false
            }
        }
        .alert("حذف «\(draft.name)»؟", isPresented: $confirmDelete) {
            Button("حذف", role: .destructive) {
                if let existing { store.delete(existing) }
                dismiss()
            }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("سيُحذف تقدّم المشاهدة وقائمته من كل الأجهزة.")
        }
    }

    private func save() {
        var profile = draft
        profile.name = trimmedName
        if profile.isOwner { profile.isKids = false }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if existing == nil { store.createProfile(profile) } else { store.update(profile) }
        }
    }
}

/// Drag to reorder the enabled libraries (the order of «المكتبات» and the Home rows).
private struct ScopeOrderPage: View {
    let sections: [PlexDirectory]
    @Binding var scopes: [String]

    var body: some View {
        List {
            ForEach(scopes, id: \.self) { raw in
                Text(title(raw))
            }
            .onMove { scopes.move(fromOffsets: $0, toOffset: $1) }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("ترتيب المكتبات")
    }

    private func title(_ raw: String) -> String {
        guard let id = ScopeID(raw: raw), let section = sections.first(where: { $0.key == id.sectionKey }) else { return raw }
        return LibraryScope.defaultTitles(kind: id.kind, section: section).title
    }
}

// MARK: - PIN

struct PinPadView: View {
    let title: String
    var subtitle: String?
    /// Return true to accept; false shows an error and clears.
    let onSubmit: (String) -> Bool
    let onCancel: () -> Void

    @State private var digits = ""
    @State private var error: String?
    @State private var shake: CGFloat = 0

    private let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["cancel", "0", "delete"]]

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 8) {
                Text(title).font(.title3.weight(.bold)).multilineTextAlignment(.center)
                if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
            }
            HStack(spacing: 18) {
                ForEach(0..<ProfilePIN.length, id: \.self) { i in
                    Circle()
                        .fill(i < digits.count ? Color.white : Color.white.opacity(0.18))
                        .frame(width: 16, height: 16)
                }
            }
            .offset(x: shake)
            .environment(\.layoutDirection, .leftToRight)
            Text(error ?? " ").font(.footnote).foregroundStyle(.red)

            VStack(spacing: 16) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 26) {
                        ForEach(row, id: \.self) { key in keyButton(key) }
                    }
                }
            }
            .environment(\.layoutDirection, .leftToRight)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }

    @ViewBuilder
    private func keyButton(_ key: String) -> some View {
        Button { press(key) } label: {
            Group {
                switch key {
                case "cancel": Text("إلغاء").font(.callout)
                case "delete": Image(systemName: "delete.left").font(.title2)
                default: Text(ArabicFormat.digits(key)).font(.system(size: 32, weight: .medium))
                }
            }
            .frame(width: 78, height: 78)
            .background(Circle().fill(key.count == 1 ? Color.white.opacity(0.14) : Color.clear))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func press(_ key: String) {
        switch key {
        case "cancel":
            onCancel()
        case "delete":
            if !digits.isEmpty { digits.removeLast() }
        default:
            guard digits.count < ProfilePIN.length else { return }
            error = nil
            digits.append(key)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if digits.count == ProfilePIN.length {
                let pin = digits
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if !onSubmit(pin) { reject() }
                }
            }
        }
    }

    private func reject() {
        error = "الرمز غير صحيح"
        digits = ""
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        withAnimation(.spring(response: 0.08, dampingFraction: 0.2)) { shake = 14 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { withAnimation(.spring()) { shake = 0 } }
    }
}

struct PinSetupView: View {
    let onDone: (String) -> Void
    let onCancel: () -> Void
    @State private var first: String?

    var body: some View {
        if let first {
            PinPadView(title: "أكّد الرمز", subtitle: "أدخل الرمز مرة ثانية") { pin in
                guard pin == first else { return false }
                onDone(pin)
                return true
            } onCancel: {
                self.first = nil
            }
            .id("confirm")
        } else {
            PinPadView(title: "رمز PIN جديد", subtitle: "اختر ٤ أرقام") { pin in
                first = pin
                return true
            } onCancel: {
                onCancel()
            }
            .id("first")
        }
    }
}

extension View {
    /// Presents `request` as a PIN pad; runs its action once a matching PIN is entered.
    func pinRequest(_ request: Binding<PinRequest?>) -> some View {
        fullScreenCover(item: request) { req in
            PinPadView(title: req.title, subtitle: req.subtitle) { pin in
                guard req.profiles.contains(where: { ProfilePIN.verify(pin, profile: $0) }) else { return false }
                request.wrappedValue = nil
                DispatchQueue.main.async { req.onSuccess() }
                return true
            } onCancel: {
                request.wrappedValue = nil
            }
        }
    }
}
