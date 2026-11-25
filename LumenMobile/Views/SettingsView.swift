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
    @AppStorage(PlaybackSettings.fastProfileKey) private var fastProfile = false
    @AppStorage(PlaybackSettings.skipSecondsKey) private var skipSeconds = PlaybackSettings.defaultSkip
    @AppStorage(PlaybackSettings.subtitleLookKey) private var subtitleLook: SubtitleLook = .original
    @AppStorage(PlaybackSettings.subtitleSizeKey) private var subtitleSize = PlaybackSettings.defaultSubtitleSize
    @Environment(\.contentFilter) private var filter
    @State private var confirmUndo = false
    @State private var confirmSignOut = false
    @State private var connection: ConnectionCheck = .idle
    @State private var artworkSize: Int?
    @State private var responseSize: Int?

    private enum ConnectionCheck: Equatable { case idle, checking, reachable(ms: Int), unreachable }
    @State private var editing: UserProfile?
    @State private var pin: PinRequest?
    @State private var versionTaps = HiddenTapCounter()
    @State private var path = NavigationPath()

    /// Pages Settings opens (by value, so the pages inside them can open theirs).
    private enum Page: Hashable { case libraries, importHistory, diagnostics }
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        BrowseStack(client: client, path: $path) {
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
                        Picker("ترتيب متابعة المشاهدة", selection: Binding(
                            get: { store.activeProfile?.settings?.continueNewFirst ?? false },
                            set: { on in store.updateSettings { $0.continueNewFirst = on } })) {
                            Text("الأحدث مشاهدة أولًا").tag(false)
                            Text("الجديد أولًا").tag(true)
                        }
                    } header: {
                        Text("الرئيسية")
                    } footer: {
                        Text("«الجديد أولًا»: المسلسلات اللي نزلت لها حلقة أو موسم جديد تطلع أول الصف.")
                    }

                    Section("سجل المشاهدة") {
                        Button("استيراد سجل المشاهدة من Plex") { guarded { path.append(Page.importHistory) } }
                        if store.canUndoImport {
                            Button("التراجع عن آخر استيراد", role: .destructive) { confirmUndo = true }
                        }
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

                if store.cloudStatus != .localOnly, store.activeProfile?.isKids == false {
                    Section {
                        ForEach(store.profiles) { profile in
                            if store.isSharedWithMe(profile) {
                                HStack(spacing: 14) {
                                    ProfileAvatar(profile: profile, size: 36)
                                    Text(profile.name)
                                    Spacer()
                                    Text("مشارَك معك").font(.caption).foregroundStyle(.secondary)
                                }
                            } else {
                                ShareProfileRow(profile: profile)
                            }
                        }
                    } header: {
                        Text("المشاركة مع حساب iCloud آخر")
                    } footer: {
                        Text("أرسل دعوة لمستخدم (مثلاً لجهاز زوجتك بحساب iCloud مختلف). بعد قبولها يظهر المستخدم في Lumen على جهازها، ويتزامن تقدّمه وقائمته وإعداداته بين الجهازين.")
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
                    Button("تسجيل الخروج", role: .destructive) { guarded { confirmSignOut = true } }
                }

                Section("الخادم") {
                    LabeledContent("متصل بـ", value: client.name)
                    LabeledContent("نوع الاتصال", value: client.isLocal ? "شبكة محلية" : "عن بُعد")
                    Button {
                        Task { await checkConnection() }
                    } label: {
                        LabeledContent("فحص الاتصال", value: connectionText ?? "")
                    }
                    .foregroundStyle(.primary)
                    LibrarySyncStatusRow()
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
                    if engine == .mpv {
                        Picker("التقديم والترجيع", selection: $skipSeconds) {
                            ForEach([5, 10, 15, 30], id: \.self) { Text(Self.seconds($0)).tag($0) }
                        }
                        Toggle("وضع الأداء العالي", isOn: $fastProfile)
                    }
                    Toggle("فرض التحويل عبر الخادم (Transcode)", isOn: $forceTranscode)
                } header: {
                    Text("التشغيل")
                } footer: {
                    Text("خارج البيت (بيانات الجوال) قلّل الجودة لتوفير البيانات وتجنّب التقطيع. «وضع الأداء العالي» للأجهزة الأقدم إذا تقطّع الفيديو.")
                }

                Section {
                    Picker("لغة الصوت", selection: audioLanguage) {
                        Text("لغة الملف").tag("")
                        ForEach(Self.languages, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    Picker("لغة الترجمة", selection: subtitleLanguage) {
                        Text("حسب الملف").tag("")
                        Text("بدون ترجمة").tag(Self.off)
                        ForEach(Self.languages, id: \.1) { Text($0.0).tag($0.1) }
                    }
                } header: {
                    Text("الصوت والترجمة")
                } footer: {
                    Text("لهذا المستخدم وتتزامن مع أجهزته. اختيارك لحلقة معيّنة داخل المشغّل له الأولوية.")
                }

                if engine == .mpv {
                    Section {
                        Picker("ترجمات ASS", selection: $subtitleLook) {
                            ForEach(SubtitleLook.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("حجم الخط", selection: $subtitleSize) {
                            ForEach(PlaybackSettings.subtitleSizes, id: \.size) { Text($0.title).tag($0.size) }
                        }
                        // How it looks, at the size chosen (mpv sizes text for a 720-line screen).
                        ZStack {
                            LinearGradient(colors: [Color(white: 0.28), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                            Text("هكذا تظهر الترجمة")
                                .font(.system(size: CGFloat(subtitleSize) * 0.6, weight: .bold))
                                .foregroundStyle(.white)
                                .shadow(color: .black, radius: 2)
                        }
                        .frame(height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    } header: {
                        Text("شكل الترجمة")
                    } footer: {
                        Text("«توحيد الحوار» يعطي حوار ASS نفس الخط واللون والحجم ويترك اللوحات والأغاني. ترجمات الصور لا تتغيّر.")
                    }
                }

                Section("المقدمة والختام") {
                    Toggle("تخطي المقدمة تلقائياً", isOn: $autoSkipIntro)
                    Toggle("تشغيل الحلقة التالية تلقائياً", isOn: $autoPlayNext)
                }

                Section {
                    Button {
                        Task { await ImageLoader.shared.clearDisk(); await measure() }
                    } label: {
                        LabeledContent("مسح الصور", value: Self.bytes(artworkSize))
                    }
                    Button {
                        Task {
                            await Task.detached { PlexResponseCache.clear() }.value
                            await measure()
                        }
                    } label: {
                        LabeledContent("مسح بيانات المكتبة المؤقتة", value: Self.bytes(responseSize))
                    }
                } header: {
                    Text("التخزين على هذا الجهاز")
                } footer: {
                    Text("مسحها آمن: تُحمَّل من جديد عند الحاجة، ولا يتأثر تقدّم المشاهدة ولا قائمتي.")
                }
                .foregroundStyle(.primary)
                .task { await measure() }

                Section("حول") {
                    // Five taps open the hidden Home tuning screen.
                    LabeledContent("الإصدار", value: ArabicFormat.digits("\(PlexClientInfo.version) (\(PlexClientInfo.build))"))
                        .contentShape(Rectangle())
                        .onTapGesture { if versionTaps.tap() { path.append(Page.diagnostics) } }
                    LabeledContent("النظام", value: ArabicFormat.digits("\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"))
                    LabeledContent("المشغّل", value: engine == .mpv ? "MPV" : "AVPlayer")
                }

                Section("المصادر والتراخيص") {
                    license("MPV / MPVKit", "مشغّل الفيديو، بترخيص GPL.")
                    license("TMDB", "يستخدم التطبيق واجهة TMDB، وهو غير معتمد منها ولا مصدّق عليه.")
                    license("anime-offline-database", "تصنيفات الأنمي وتقييماته، من manami-project بترخيص ODbL 1.0. ربط المعرّفات من Fribb/anime-lists.")
                }
            }
            .readableColumn(Metrics(sizeClass))
            .navigationTitle("الإعدادات")
            // Follow the profile to its other devices.
            .onChange(of: autoSkipIntro) { _, on in store.updateSettings { $0.autoSkipIntro = on } }
            .onChange(of: autoPlayNext) { _, on in store.updateSettings { $0.autoPlayNext = on } }
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .libraries:
                    LibrariesSettingsView(client: client, sections: sections)
                case .diagnostics:
                    HomeDiagnosticsView(client: client)
                case .importHistory:
                    if let profile = store.activeProfile {
                        PlexImportPage(client: client, sections: filter.sections, profile: profile)
                    }
                }
            }
        }
        .alert("تسجيل الخروج من Plex؟", isPresented: $confirmSignOut) {
            Button("تسجيل الخروج", role: .destructive) { session.signOut() }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("ستحتاج ربط الجهاز من جديد برمز plex.tv/link.")
        }
        .alert("التراجع عن آخر استيراد؟", isPresented: $confirmUndo) {
            Button("تراجع", role: .destructive) { store.undoImport() }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("يرجع سجل هذا المستخدم كما كان قبل الاستيراد. ما شاهدته بعده يبقى.")
        }
        .sheet(item: $editing) { profile in
            ProfileEditorView(client: client, sections: sections, existing: profile)
        }
        .pinRequest($pin)
    }

    /// A kids profile needs the main profile's PIN to change its libraries.
    private func openLibraries() {
        guard let profile = store.activeProfile, profile.isKids else { path.append(Page.libraries); return }
        let editors = ProfileGate.editors(for: profile, store: store)
        guard !editors.isEmpty else { path.append(Page.libraries); return }
        pin = PinRequest(title: "رمز المستخدم الرئيسي", subtitle: "مطلوب لتغيير مكتبات حساب الأطفال",
                         profiles: editors) { path.append(Page.libraries) }
    }

    /// A kids profile needs the main profile's PIN to open its settings.
    private func editProfile(_ profile: UserProfile) {
        let editors = profile.isKids ? ProfileGate.editors(for: profile, store: store) : []
        guard !editors.isEmpty else { editing = profile; return }
        pin = PinRequest(title: "رمز المستخدم الرئيسي", subtitle: "مطلوب لتغيير إعدادات حساب الأطفال",
                         profiles: editors) { editing = profile }
    }

    private func license(_ name: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Values

    private static let off = "off"
    /// ISO 639-2, as Plex and the player report them.
    private static let languages: [(String, String)] = [
        ("العربية", "ara"), ("الإنجليزية", "eng"), ("اليابانية", "jpn"), ("الكورية", "kor"), ("التركية", "tur"),
        ("الهندية", "hin"), ("الصينية", "zho"), ("الفرنسية", "fra"), ("الإسبانية", "spa"), ("الألمانية", "deu"),
    ]

    private var audioLanguage: Binding<String> {
        Binding {
            StreamPreference.normalize(store.activeProfile?.preferredAudioLanguage) ?? ""
        } set: { code in
            guard var profile = store.activeProfile else { return }
            profile.preferredAudioLanguage = code.isEmpty ? nil : code
            store.update(profile)
        }
    }

    private var subtitleLanguage: Binding<String> {
        Binding {
            guard let profile = store.activeProfile else { return "" }
            if profile.subtitlesOff { return Self.off }
            return StreamPreference.normalize(profile.preferredSubtitleLanguage) ?? ""
        } set: { code in
            guard var profile = store.activeProfile else { return }
            profile.subtitlesOff = code == Self.off
            // «بدون ترجمة» keeps the language for when subtitles come back.
            if code != Self.off { profile.preferredSubtitleLanguage = code.isEmpty ? nil : code }
            store.update(profile)
        }
    }

    private static func seconds(_ n: Int) -> String {
        ArabicFormat.digits(n) + ((3...10).contains(n) ? " ثوانٍ" : " ثانية")
    }

    private static func bytes(_ size: Int?) -> String {
        guard let size else { return "…" }
        let mb = Double(size) / 1_048_576
        return mb >= 1024 ? ArabicFormat.digits(String(format: "%.1f", mb / 1024)) + " ج.ب"
                          : ArabicFormat.digits(Int(mb.rounded())) + " م.ب"
    }

    private func measure() async {
        artworkSize = await ImageLoader.shared.diskSize()
        responseSize = await Task.detached { PlexResponseCache.size() }.value
    }

    private var connectionText: String? {
        switch connection {
        case .idle: return nil
        case .checking: return "جارٍ الفحص…"
        case .reachable(let ms): return "متصل، \(ArabicFormat.digits(ms)) مللي ثانية"
        case .unreachable: return "لا يستجيب"
        }
    }

    private func checkConnection() async {
        guard connection != .checking else { return }
        connection = .checking
        let start = Date()
        let ok = await client.isReachable()
        connection = ok ? .reachable(ms: Int(Date().timeIntervalSince(start) * 1000)) : .unreachable
    }

    private func guarded(_ action: @escaping () -> Void) {
        guard let profile = store.activeProfile, profile.isKids else { action(); return }
        let editors = ProfileGate.editors(for: profile, store: store)
        guard !editors.isEmpty else { action(); return }
        pin = PinRequest(title: "رمز المستخدم الرئيسي", profiles: editors, onSuccess: action)
    }
}
