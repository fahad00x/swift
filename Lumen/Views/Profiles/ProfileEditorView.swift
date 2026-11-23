import SwiftUI

/// Create or edit a profile: name, colour and symbol, kids mode, PIN, libraries (with the
/// anime / non-anime split), genre focus and tab order.
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
            HStack(alignment: .top, spacing: 80) {
                VStack(spacing: 30) {
                    ProfileAvatar(profile: draft, size: 300)
                    Text(trimmedName.isEmpty ? "مستخدم جديد" : trimmedName)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                    if draft.isKids {
                        Text("حساب أطفال").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 440)
                .padding(.top, 60)

                form
            }
            .padding(.horizontal, 60)
            .navigationTitle(existing == nil ? "إضافة مستخدم" : "تعديل المستخدم")
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

    private var form: some View {
        List {
            Section {
                TextField("الاسم", text: $draft.name)
                NavigationLink {
                    AvatarPickerPage(symbol: $draft.symbol, colorHex: $draft.colorHex)
                } label: {
                    HStack {
                        Text("الصورة واللون")
                        Spacer()
                        ProfileAvatar(profile: draft, size: 56)
                    }
                }
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
                Text(draft.isKids
                     ? "يظهر فقط المحتوى المناسب للأطفال (G وPG وTV-Y وTV-Y7 وTV-G وTV-PG). تغيير إعداداته يحتاج رمز المستخدم الرئيسي."
                     : (draft.isOwner ? "رمز المستخدم الرئيسي يحمي إعدادات حسابات الأطفال." : ""))
            }

            Section("المحتوى") {
                NavigationLink {
                    LibrariesPage(client: client, sections: sections, scopes: $draft.scopes)
                } label: {
                    LabeledContent("المكتبات", value: librariesSummary)
                }
                NavigationLink {
                    GenresPage(client: client, sections: sections, genres: $draft.genres)
                } label: {
                    LabeledContent("الأنواع المفضّلة", value: genresSummary)
                }
                NavigationLink {
                    TabOrderPage(sections: sections, scopes: $draft.scopes)
                } label: {
                    Text("ترتيب التبويبات")
                }
                .disabled(draft.scopes.count < 2)
            }

            Section {
                Button(existing == nil ? "إنشاء المستخدم" : "حفظ") { save() }
                    .disabled(trimmedName.isEmpty)
                Button("إلغاء", role: .cancel) { dismiss() }
                if let existing, !existing.isOwner {
                    Button("حذف المستخدم", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .frame(maxWidth: 1100)
    }

    private var librariesSummary: String {
        let count = draft.scopes.count
        return count == 0 ? "لا شيء" : "\(ArabicFormat.digits(count)) مفتوحة"
    }

    private var genresSummary: String {
        draft.genres.isEmpty ? "الكل" : draft.genres.prefix(3).map(ArabicFormat.genre).joined(separator: "، ")
    }

    private func save() {
        var profile = draft
        profile.name = trimmedName
        if profile.isOwner { profile.isKids = false }
        dismiss()
        // After the sheet closes: saving can rebuild the browsing UI behind it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if existing == nil {
                store.createProfile(profile)
            } else {
                store.update(profile)
            }
        }
    }
}

// MARK: - Avatar

private struct AvatarPickerPage: View {
    @Binding var symbol: String
    @Binding var colorHex: String

    private let columns = Array(repeating: GridItem(.fixed(150), spacing: 40), count: 8)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                Text("اللون").font(.title3.weight(.semibold)).padding(.horizontal, 80)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 36) {
                        ForEach(ProfileStyle.colors, id: \.self) { hex in
                            Button { colorHex = hex } label: {
                                Circle().fill(Color(hex: hex))
                                    .frame(width: 110, height: 110)
                                    .overlay {
                                        if hex == colorHex {
                                            Image(systemName: "checkmark").font(.title2.weight(.bold)).foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 30)
                }
                .scrollClipDisabled()
                .focusSection()

                Text("الصورة الرمزية").font(.title3.weight(.semibold)).padding(.horizontal, 80)
                LazyVGrid(columns: columns, spacing: 40) {
                    ForEach(ProfileStyle.symbols, id: \.self) { name in
                        Button { symbol = name } label: {
                            ProfileAvatar(symbol: name, colorHex: name == symbol ? colorHex : "#3A3A3C", size: 140)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.horizontal, 80)
                .focusSection()
            }
            .padding(.vertical, 40)
        }
        .navigationTitle("الصورة واللون")
    }
}

// MARK: - Tab order

struct TabOrderPage: View {
    let sections: [PlexDirectory]
    @Binding var scopes: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("رتّب التبويبات اللي تطلع فوق. الرئيسية أولاً دائماً، والبحث والإعدادات آخراً.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 10)
                ForEach(Array(scopes.enumerated()), id: \.element) { index, raw in
                    HStack(spacing: 30) {
                        Text(ArabicFormat.digits(index + 1))
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 50)
                        Text(title(raw)).font(.headline)
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == scopes.count - 1)
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 16)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.06)))
                    .focusSection()
                }
            }
            .frame(maxWidth: 1100)
            .padding(60)
        }
        .navigationTitle("ترتيب التبويبات")
    }

    private func title(_ raw: String) -> String {
        guard let id = ScopeID(raw: raw), let section = sections.first(where: { $0.key == id.sectionKey }) else { return raw }
        return LibraryScope.defaultTitles(kind: id.kind, section: section).title
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard scopes.indices.contains(target) else { return }
        withAnimation { scopes.swapAt(index, target) }
    }
}
