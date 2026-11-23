import SwiftUI

struct SettingsView: View {
    let client: PlexServerClient
    let sections: [PlexDirectory]

    @Environment(AppSession.self) private var session
    @Environment(ProfileStore.self) private var store
    @AppStorage(PlaybackSettings.forceTranscodeKey) private var forceTranscode = false
    @AppStorage(PlaybackSettings.engineKey) private var engine: PlaybackEngine = .mpv
    @AppStorage(PlaybackSettings.autoSkipIntroKey) private var autoSkipIntro = false
    @AppStorage(PlaybackSettings.autoPlayNextKey) private var autoPlayNext = true
    @AppStorage(PlaybackSettings.maxBitrateKey) private var maxBitrate = PlaybackSettings.defaultBitrate
    @State private var editing: UserProfile?
    @State private var pin: PinRequest?
    @State private var showLibraries = false

    var body: some View {
        BrowseStack(client: client) {
            Form {
                Section {
                    Button {
                        openLibraries()
                    } label: {
                        HStack {
                            Label("المكتبات", systemImage: "square.stack.fill")
                            Spacer()
                            Image(systemName: "chevron.left").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }

                if let profile = store.activeProfile {
                    Section {
                        HStack(spacing: 14) {
                            ProfileAvatar(profile: profile, size: 50)
                            VStack(alignment: .leading) {
                                Text(profile.name).font(.headline)
                                if profile.isKids {
                                    Text("حساب أطفال").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button("تبديل المستخدم") { store.deactivate() }
                        Button("إعدادات المستخدم") { editProfile(profile) }
                        Toggle("تذكّر آخر مستخدم", isOn: Binding(get: { store.rememberLastProfile },
                                                               set: { store.setRememberLastProfile($0) }))
                    } header: {
                        Text("المستخدم")
                    } footer: {
                        Text("مع «تذكّر آخر مستخدم» يفتح التطبيق على آخر مستخدم مباشرة بدون شاشة «مين يشاهد؟».")
                    }

                    Section {
                        LabeledContent("المزامنة", value: store.cloudStatus.description)
                        if store.cloudStatus != .localOnly {
                            Button("مزامنة الآن") { Task { await store.syncNow() } }
                        }
                    } header: {
                        Text("iCloud")
                    } footer: {
                        Text("نفس المستخدمين وبياناتهم على الآيفون والآبل تي في عن طريق iCloud، ولا تُرسل إلى Plex.")
                    }
                }

                Section("حساب Plex") {
                    HStack(spacing: 14) {
                        RemoteImage(url: session.user?.thumb.flatMap(URL.init(string:)))
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.white.opacity(0.1)))
                            .clipShape(Circle())
                        VStack(alignment: .leading) {
                            Text(session.user?.displayName ?? "Plex")
                            if let email = session.user?.email {
                                Text(email).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("تسجيل الخروج", role: .destructive) { guarded { session.signOut() } }
                }

                Section("الخادم") {
                    LabeledContent("متصل بـ", value: client.name)
                    LabeledContent("نوع الاتصال", value: client.isLocal ? "شبكة محلية" : "عن بُعد")
                    // Full reload: connection, libraries and every screen from the server.
                    Button {
                        Task { await session.refreshLibrary() }
                    } label: {
                        HStack {
                            Text("تحديث المكتبة")
                            Spacer()
                            if session.isRefreshing { ProgressView() }
                        }
                    }
                    .disabled(session.isRefreshing)
                    if session.servers.count > 1 {
                        Button("تغيير الخادم") { guarded { session.chooseAnotherServer() } }
                    }
                }

                Section {
                    Picker("مشغّل الفيديو", selection: $engine) {
                        ForEach(PlaybackEngine.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("الحد الأقصى للجودة", selection: $maxBitrate) {
                        ForEach(PlaybackSettings.bitrateOptions, id: \.kbps) { Text($0.title).tag($0.kbps) }
                    }
                    Toggle("فرض التحويل عبر الخادم (Transcode)", isOn: $forceTranscode)
                } header: {
                    Text("التشغيل")
                } footer: {
                    Text("خارج البيت (بيانات الجوال) قلّل الجودة لتوفير البيانات وتجنّب التقطيع.")
                }

                Section("المقدمة والختام") {
                    Toggle("تخطي المقدمة تلقائياً", isOn: $autoSkipIntro)
                    Toggle("تشغيل الحلقة التالية تلقائياً", isOn: $autoPlayNext)
                }

                Section("حول") {
                    LabeledContent("الإصدار", value: PlexClientInfo.version)
                    LabeledContent("رقم البناء", value: PlexClientInfo.build)
                }
            }
            .navigationTitle("الإعدادات")
            .navigationDestination(isPresented: $showLibraries) {
                LibrariesSettingsView(client: client, sections: sections)
            }
        }
        .sheet(item: $editing) { profile in
            ProfileEditorView(client: client, sections: sections, existing: profile)
        }
        .pinRequest($pin)
    }

    /// A kids profile needs the main profile's PIN to change its libraries.
    private func openLibraries() {
        guard let profile = store.activeProfile, profile.isKids else { showLibraries = true; return }
        let editors = ProfileGate.editors(for: profile, store: store)
        guard !editors.isEmpty else { showLibraries = true; return }
        pin = PinRequest(title: "رمز المستخدم الرئيسي", subtitle: "مطلوب لتغيير مكتبات حساب الأطفال",
                         profiles: editors) { showLibraries = true }
    }

    /// A kids profile needs the main profile's PIN to open its settings.
    private func editProfile(_ profile: UserProfile) {
        let editors = profile.isKids ? ProfileGate.editors(for: profile, store: store) : []
        guard !editors.isEmpty else { editing = profile; return }
        pin = PinRequest(title: "رمز المستخدم الرئيسي", subtitle: "مطلوب لتغيير إعدادات حساب الأطفال",
                         profiles: editors) { editing = profile }
    }

    private func guarded(_ action: @escaping () -> Void) {
        guard let profile = store.activeProfile, profile.isKids else { action(); return }
        let editors = ProfileGate.editors(for: profile, store: store)
        guard !editors.isEmpty else { action(); return }
        pin = PinRequest(title: "رمز المستخدم الرئيسي", profiles: editors, onSuccess: action)
    }
}
