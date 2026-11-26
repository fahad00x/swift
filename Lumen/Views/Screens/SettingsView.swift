import SwiftUI

/// Settings like a page of the Apple TV's own: the categories on the reading side, the focused
/// one's settings next to them on glass cards. Back goes from the settings to the categories,
/// then to the sidebar.
struct SettingsView: View {
    let client: PlexServerClient
    let sections: [PlexDirectory]

    enum Page: String, CaseIterable, Identifiable {
        case user, playback, tracks, libraries, server, storage, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .user: return "المستخدم"
            case .playback: return "التشغيل"
            case .tracks: return "الصوت والترجمة"
            case .libraries: return "الشريط الجانبي"
            case .server: return "الخادم والحساب"
            case .storage: return "التخزين"
            case .about: return "حول التطبيق"
            }
        }

        var icon: String {
            switch self {
            case .user: return "person.fill"
            case .playback: return "play.fill"
            case .tracks: return "captions.bubble.fill"
            case .libraries: return "sidebar.right"
            case .server: return "server.rack"
            case .storage: return "internaldrive.fill"
            case .about: return "info"
            }
        }

        var color: Color {
            switch self {
            case .user: return .blue
            case .playback: return .orange
            case .tracks: return .purple
            case .libraries: return .teal
            case .server: return .green
            case .storage: return .gray
            case .about: return .indigo
            }
        }
    }

    @Environment(AppSession.self) private var session
    @State private var showDolbySpike = false // SPIKE
    @Environment(ProfileStore.self) private var store
    @Environment(SidebarPrefs.self) private var sidebarPrefs
    @Environment(\.contentFilter) private var filter
    @Environment(\.focusSidebar) private var focusSidebar
    @AppStorage(PlaybackSettings.forceTranscodeKey) private var forceTranscode = false
    @AppStorage(PlaybackSettings.engineKey) private var engine: PlaybackEngine = .mpv
    @AppStorage(PlaybackSettings.fastProfileKey) private var fastProfile = false
    @AppStorage(PlaybackSettings.autoSkipIntroKey) private var autoSkipIntro = false
    @AppStorage(PlaybackSettings.autoPlayNextKey) private var autoPlayNext = true
    @AppStorage(PlaybackSettings.maxBitrateKey) private var maxBitrate = PlaybackSettings.defaultBitrate
    @AppStorage(PlaybackSettings.skipSecondsKey) private var skipSeconds = PlaybackSettings.defaultSkip
    @AppStorage(PlaybackSettings.subtitleLookKey) private var subtitleLook: SubtitleLook = .original
    @AppStorage(PlaybackSettings.subtitleSizeKey) private var subtitleSize = PlaybackSettings.defaultSubtitleSize

    @State private var page: Page = .user
    @FocusState private var focusedPage: Page?
    @FocusState private var focusedLibrary: String?
    @State private var editing: UserProfile?
    @State private var pin: PinRequest?
    @State private var choosing: ChoiceList?
    @State private var versionTaps = HiddenTapCounter()
    @State private var showDiagnostics = false
    @State private var showHomeRows = false
    @State private var confirmSignOut = false
    @State private var importing = false
    @State private var confirmUndo = false
    @State private var connection: ConnectionCheck = .idle
    @State private var artworkSize: Int?
    @State private var responseSize: Int?
    @State private var hasSearches = !RecentSearches.load().isEmpty

    private enum ConnectionCheck: Equatable { case idle, checking, reachable(ms: Int), unreachable }

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 70) {
                categories
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 40) { content }
                        .padding(.vertical, 60)
                        .padding(.horizontal, 24)
                }
                .scrollClipDisabled()
                .id(page)
                .frame(maxWidth: .infinity)
                .focusSection()
                // Back from the settings: to their category.
                .onExitCommand { focusedPage = page }
            }
            .padding(.horizontal, CardKind.inset)
            .sidebarPadding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(white: 0.07).ignoresSafeArea())
            .ignoresSafeArea()
            // Follow the profile to its other devices.
            .onChange(of: autoSkipIntro) { _, on in store.updateSettings { $0.autoSkipIntro = on } }
            .onChange(of: autoPlayNext) { _, on in store.updateSettings { $0.autoPlayNext = on } }
            .navigationDestination(isPresented: $showDiagnostics) {
                HomeDiagnosticsView(client: client)
            }
            .navigationDestination(isPresented: $showHomeRows) {
                HomeRowsEditor(client: client)
            }
            .navigationDestination(isPresented: $showDolbySpike) {
                DolbySpikeView(client: client) // SPIKE
            }
        }
        .fullScreenCover(item: $editing) { profile in
            ProfileEditorView(client: client, sections: sections, existing: profile)
        }
        .fullScreenCover(isPresented: $importing) {
            if let profile = store.activeProfile {
                PlexImportView(client: client, sections: filter.sections, profile: profile)
            }
        }
        .fullScreenCover(item: $choosing) { ChoicePanel(list: $0) }
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
        .pinRequest($pin)
    }

    // MARK: Categories

    private var categories: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("الإعدادات")
                .font(.system(size: 52, weight: .bold))
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            ForEach(Page.allCases) { item in
                Button { } label: {
                    HStack(spacing: 22) {
                        Image(systemName: item.icon)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 50, height: 50)
                            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(item.color.gradient))
                        Text(item.title)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(SettingsRowStyle(selected: item == page, standalone: true))
                .focused($focusedPage, equals: item)
            }
        }
        .padding(.top, 70)
        .frame(width: 500)
        .focusSection()
        .defaultFocus($focusedPage, page)
        .onChange(of: focusedPage) { old, new in
            guard let new else { return }
            // Coming back from the settings lands on their category, not the nearest one.
            if old == nil, new != page {
                DispatchQueue.main.async { focusedPage = page }
            } else {
                page = new
            }
        }
        .onExitCommand(perform: focusSidebar)
    }

    // MARK: Pages

    @ViewBuilder
    private var content: some View {
        switch page {
        case .user: userPage
        case .playback: playbackPage
        case .tracks: tracksPage
        case .libraries: librariesPage
        case .server: serverPage
        case .storage: storagePage
        case .about: aboutPage
        }
    }

    @ViewBuilder
    private var userPage: some View {
        if let profile = store.activeProfile {
            HStack(spacing: 30) {
                ProfileAvatar(profile: profile, size: 120)
                VStack(alignment: .leading, spacing: 6) {
                    Text(profile.name).font(.system(size: 42, weight: .bold))
                    if profile.isKids {
                        Text("حساب أطفال").font(.system(size: 24)).foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            .padding(.horizontal, 10)

            SettingsCard {
                SettingsRow("تبديل المستخدم", arrow: true) { store.deactivate() }
                SettingsRow("تعديل المستخدم", detail: "الاسم والصورة والرمز والمكتبات", arrow: true) { editProfile(profile) }
                SettingsSwitch("تذكّر آخر مستخدم", detail: "يفتح عليه مباشرة بدون شاشة «مين يشاهد؟»",
                               isOn: Binding(get: { store.rememberLastProfile }, set: { store.setRememberLastProfile($0) }))
            }
            SettingsCard("الرئيسية") {
                SettingsRow("صفوف الرئيسية", detail: "الترتيب، ثابت أو ديناميكي، الإضافة والحذف", arrow: true) { showHomeRows = true }
                SettingsSwitch("إظهار «قائمتي» في الرئيسية", detail: "بعد متابعة المشاهدة مباشرة", isOn: TVMyListView.onHome(store))
                choice("ترتيب متابعة المشاهدة",
                       selection: Binding(get: { store.activeProfile?.settings?.continueNewFirst ?? false },
                                          set: { on in store.updateSettings { $0.continueNewFirst = on } }),
                       options: [("الأحدث مشاهدة أولًا", false), ("الجديد أولًا", true)])
            }
            SettingsCard("سجل المشاهدة") {
                SettingsRow("استيراد سجل المشاهدة من Plex", detail: "لهذا المستخدم فقط", arrow: true) { guarded { importing = true } }
                if store.canUndoImport {
                    SettingsRow("التراجع عن آخر استيراد", detail: "يرجّع السجل كما كان قبله") { confirmUndo = true }
                }
            }
            SettingsCard("iCloud", footer: "تقدّم المشاهدة والمشاهَد وقائمتي والمكتبات محفوظة في iCloud وعلى الجهاز، ولا تُرسل إلى Plex.") {
                if store.cloudStatus == .localOnly {
                    SettingsInfo("المزامنة", value: store.cloudStatus.description)
                } else {
                    SettingsRow("مزامنة الآن", value: store.cloudStatus.description) { Task { await store.syncNow() } }
                }
            }
        }
    }

    @ViewBuilder
    private var playbackPage: some View {
        SettingsCard("المشغّل", footer: engine == .mpv
            ? "يشغّل الملف الأصلي مباشرة بكل صيغه. فعّل «مطابقة المحتوى» في إعدادات Apple TV ← الفيديو والصوت ليتحوّل التلفاز إلى HDR ومعدل الإطارات الصحيح."
            : "يشغّل MP4/MOV مباشرة، وباقي الصيغ يحوّلها خادم Plex. أزرار مشغّل Lumen لا تظهر معه.") {
            choice("مشغّل الفيديو", selection: $engine, options: PlaybackEngine.allCases.map { ($0.title, $0) })
            choice("الحد الأقصى للجودة", selection: $maxBitrate,
                   options: PlaybackSettings.bitrateOptions.map { ($0.title, $0.kbps) })
            if engine == .mpv {
                choice("التقديم والترجيع", detail: "ضغطة يمين أو يسار في المشغّل", selection: $skipSeconds,
                       options: [5, 10, 15, 30].map { (Self.seconds($0), $0) })
            }
        }
        SettingsCard("الحلقات", footer: "يكتشف خادم Plex المقدمة والختام (Plex Pass: فعّل Intro/Credits detection في إعدادات المكتبة).") {
            SettingsSwitch("تخطي المقدمة تلقائيًا", isOn: $autoSkipIntro)
            SettingsSwitch("تشغيل الحلقة التالية تلقائيًا", isOn: $autoPlayNext)
        }
        SettingsCard("متقدم") {
            if engine == .mpv {
                SettingsSwitch("وضع الأداء العالي", detail: "لأجهزة Apple TV الأقدم إذا تقطّع الفيديو", isOn: $fastProfile)
            }
            SettingsSwitch("التحويل عبر الخادم دائمًا", detail: "إذا كانت الشبكة بطيئة (Transcode)", isOn: $forceTranscode)
        }
    }

    @ViewBuilder
    private var tracksPage: some View {
        SettingsCard("اللغة المفضّلة", footer: "لهذا المستخدم وتتزامن مع أجهزته. اختيارك لحلقة معيّنة داخل المشغّل له الأولوية.") {
            choice("لغة الصوت", selection: audioLanguage, options: [("لغة الملف", "")] + Self.languages)
            choice("لغة الترجمة", selection: subtitleLanguage,
                   options: [("حسب الملف", ""), ("بدون ترجمة", Self.off)] + Self.languages)
        }
        SettingsCard("شكل الترجمة", footer: "في مشغّل Lumen. «توحيد الحوار» يعطي حوار ASS نفس الخط واللون والحجم ويترك اللوحات والأغاني. ترجمات الصور لا تتغيّر.") {
            choice("ترجمات ASS", detail: "الترجمات المصمّمة", selection: $subtitleLook,
                   options: SubtitleLook.allCases.map { ($0.title, $0) })
            choice("حجم الخط", selection: $subtitleSize,
                   options: PlaybackSettings.subtitleSizes.map { ($0.title, $0.size) })
            // How it looks, at the size chosen (mpv sizes text for a 720-line screen).
            ZStack {
                LinearGradient(colors: [Color(white: 0.28), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                Text("هكذا تظهر الترجمة")
                    .font(.system(size: CGFloat(subtitleSize) * 1.5, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 2)
                    .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
            }
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(12)
        }
    }

    @ViewBuilder
    private var librariesPage: some View {
        let pinned = sidebarPrefs.pinned(from: filter.scopes)
        let rest = filter.scopes.filter { scope in !pinned.contains { $0.id == scope.id } }
        SettingsCard("في الشريط الجانبي", footer: "حتى \(ArabicFormat.digits(SidebarPrefs.maxPinned)) مكتبات بهذا الترتيب. اضغط على المكتبة لإزالتها، وبالأسهم ترتّبها.") {
            if pinned.isEmpty { SettingsInfo("لا توجد مكتبات", value: "") }
            ForEach(Array(pinned.enumerated()), id: \.element.id) { index, scope in
                HStack(spacing: 10) {
                    libraryRow(scope, number: index + 1)
                    moveButton("chevron.up", enabled: index > 0) { sidebarPrefs.moveUp(scope, in: filter.scopes) }
                    moveButton("chevron.down", enabled: index < pinned.count - 1) {
                        sidebarPrefs.moveUp(pinned[index + 1], in: filter.scopes)
                    }
                }
            }
        }
        if !rest.isEmpty {
            SettingsCard("تحت «المزيد»") {
                ForEach(rest) { libraryRow($0, number: nil) }
            }
        }
    }

    private func libraryRow(_ scope: LibraryScope, number: Int?) -> some View {
        Button {
            sidebarPrefs.toggle(scope, in: filter.scopes)
            // The row moves to the other card: the focus goes with it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focusedLibrary = scope.id }
        } label: {
            HStack(spacing: 20) {
                Image(systemName: number != nil ? "minus.circle.fill" : "plus.circle")
                    .foregroundStyle(number != nil ? Color.red : Color.green)
                Image(systemName: scope.icon).frame(width: 40)
                Text(scope.title).lineLimit(1)
                Spacer(minLength: 10)
                if let number { Text(ArabicFormat.digits(number)).opacity(0.5) }
            }
        }
        .buttonStyle(SettingsRowStyle(selected: false, standalone: false))
        .focused($focusedLibrary, equals: scope.id)
    }

    private func moveButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 24, weight: .semibold)).frame(width: 30) }
            .buttonStyle(SettingsRowStyle(selected: false, standalone: false))
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.25)
    }

    @ViewBuilder
    private var serverPage: some View {
        SettingsCard("الخادم") {
            SettingsInfo("متصل بـ", value: client.name)
            SettingsInfo("نوع الاتصال", value: client.isLocal ? "شبكة محلية" : "عن بُعد")
            SettingsRow("فحص الاتصال", value: connectionText) { Task { await checkConnection() } }
            if session.servers.count > 1 {
                SettingsRow("تغيير الخادم", arrow: true) { guarded { session.chooseAnotherServer() } }
            }
        }
        SettingsCard("المكتبة", footer: "يعيد تحميل الاتصال والمكتبات وكل الشاشات من الخادم.") {
            LibrarySyncStatusRow()
                .font(.system(size: 28))
                .padding(.horizontal, 20)
                .frame(minHeight: 76)
            SettingsRow("تحديث المكتبة", value: session.isRefreshing ? "جارٍ التحديث…" : nil) {
                Task { await session.refreshLibrary() }
            }
            .disabled(session.isRefreshing)
        }
        SettingsCard("حساب Plex") {
            HStack(spacing: 24) {
                RemoteImage(url: session.user?.thumb.flatMap(URL.init(string:)))
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.user?.displayName ?? "Plex").font(.system(size: 28))
                    if let email = session.user?.email {
                        Text(email).font(.system(size: 22)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            SettingsRow("تسجيل الخروج", destructive: true) { guarded { confirmSignOut = true } }
        }
    }

    @ViewBuilder
    private var storagePage: some View {
        SettingsCard("على هذا الجهاز", footer: "مسحها آمن: تُحمَّل من جديد عند الحاجة، ولا يتأثر تقدّم المشاهدة ولا قائمتي.") {
            SettingsRow("مسح الصور", detail: "البوسترات والخلفيات", value: Self.bytes(artworkSize)) {
                Task { await ImageLoader.shared.clearDisk(); await measure() }
            }
            SettingsRow("مسح بيانات المكتبة المؤقتة", detail: "الصفوف وصفحات التفاصيل", value: Self.bytes(responseSize)) {
                Task {
                    await Task.detached { PlexResponseCache.clear() }.value
                    await measure()
                }
            }
        }
        .task { await measure() }
        SettingsCard("البحث") {
            SettingsRow("مسح عمليات البحث الأخيرة", value: hasSearches ? nil : "لا يوجد") {
                RecentSearches.clear()
                hasSearches = false
            }
            .disabled(!hasSearches)
        }
    }

    @ViewBuilder
    private var aboutPage: some View {
        SettingsCard("Lumen") {
            // Five presses open the hidden Home tuning screen.
            SettingsRow("الإصدار", value: ArabicFormat.digits("\(PlexClientInfo.version) (\(PlexClientInfo.build))")) {
                if versionTaps.tap() { showDiagnostics = true }
            }
            SettingsInfo("النظام", value: ArabicFormat.digits("tvOS \(UIDevice.current.systemVersion)"))
            SettingsInfo("المشغّل", value: engine == .mpv ? "MPV" : "AVPlayer")
        }
        SettingsCard("تجربة Dolby (مؤقت)") {
            SettingsRow("تجربة Dolby Vision و Atmos", arrow: true) { showDolbySpike = true } // SPIKE
        }
        SettingsCard("المصادر والتراخيص") {
            license("MPV / MPVKit", "مشغّل الفيديو، بترخيص GPL.")
            license("TMDB", "يستخدم التطبيق واجهة TMDB، وهو غير معتمد منها ولا مصدّق عليه.")
            license("anime-offline-database", "تصنيفات الأنمي وتقييماته، من manami-project بترخيص ODbL 1.0. ربط المعرّفات من Fribb/anime-lists.")
        }
    }

    private func license(_ name: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.system(size: 28))
            Text(text).font(.system(size: 22)).foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Values

    private func choice<Value: Hashable>(_ title: String, detail: String? = nil, selection: Binding<Value>,
                                         options: [(String, Value)]) -> some View {
        SettingsRow(title, detail: detail,
                    value: options.first { $0.1 == selection.wrappedValue }?.0 ?? "—", arrow: true) {
            choosing = ChoiceList(title: title, options: options.map(\.0),
                                  selected: options.firstIndex { $0.1 == selection.wrappedValue }) {
                selection.wrappedValue = options[$0].1
            }
        }
    }

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
        return ArabicFormat.fileSize(Int64(size))
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

    /// A kids profile needs the main profile's PIN to open its settings.
    private func editProfile(_ profile: UserProfile) {
        let editors = profile.isKids ? ProfileGate.editors(for: profile, store: store) : []
        guard !editors.isEmpty else { editing = profile; return }
        pin = PinRequest(title: "رمز المستخدم الرئيسي", subtitle: "مطلوب لتغيير إعدادات حساب الأطفال",
                         profiles: editors) { editing = profile }
    }

    /// Account-wide actions from a kids profile also need the main PIN.
    private func guarded(_ action: @escaping () -> Void) {
        guard let profile = store.activeProfile, profile.isKids else { action(); return }
        let editors = ProfileGate.editors(for: profile, store: store)
        guard !editors.isEmpty else { action(); return }
        pin = PinRequest(title: "رمز المستخدم الرئيسي", profiles: editors, onSuccess: action)
    }
}

// MARK: - Pieces

/// Rows on a rounded card, with an optional title above and note under it.
struct SettingsCard<Content: View>: View {
    let title: String?
    let footer: String?
    let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 20)
            }
            VStack(alignment: .leading, spacing: 2) { content }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.white.opacity(0.07)))
            if let footer {
                Text(footer)
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }
        }
    }
}

/// A row that does something: title (and a note), its value, an arrow when it opens something.
struct SettingsRow: View {
    let title: String
    let detail: String?
    let value: String?
    let arrow: Bool
    let destructive: Bool
    let action: () -> Void

    init(_ title: String, detail: String? = nil, value: String? = nil, arrow: Bool = false,
         destructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.value = value
        self.arrow = arrow
        self.destructive = destructive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                if destructive {
                    SettingsTitle(title: title, detail: detail).foregroundStyle(Color.red)
                } else {
                    SettingsTitle(title: title, detail: detail)
                }
                Spacer(minLength: 20)
                if let value { Text(value).lineLimit(1).opacity(0.55) }
                if arrow {
                    Image(systemName: "chevron.forward").font(.system(size: 20, weight: .semibold)).opacity(0.4)
                }
            }
        }
        .buttonStyle(SettingsRowStyle(selected: false, standalone: false))
    }
}

/// On / off, drawn as a switch.
struct SettingsSwitch: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 18) {
                SettingsTitle(title: title, detail: detail)
                Spacer(minLength: 20)
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? Color.green : Color.gray.opacity(0.5))
                    Circle().fill(.white).padding(4).shadow(radius: 2)
                }
                .frame(width: 70, height: 42)
                .animation(.easeOut(duration: 0.18), value: isOn)
            }
        }
        .buttonStyle(SettingsRowStyle(selected: false, standalone: false))
        .accessibilityValue(isOn ? "مفعّل" : "متوقف")
    }
}

struct SettingsTitle: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).lineLimit(1)
            if let detail { Text(detail).font(.system(size: 21)).opacity(0.55).lineLimit(1) }
        }
    }
}

/// Information only (not focusable).
struct SettingsInfo: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(spacing: 18) {
            Text(title)
            Spacer(minLength: 20)
            Text(value).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
        }
        .font(.system(size: 28))
        .padding(.horizontal, 20)
        .frame(minHeight: 76)
    }
}

/// Focused: white with dark text. A category that's open: lighter.
struct SettingsRowStyle: ButtonStyle {
    let selected: Bool
    /// A category (more room), not a row on a card.
    let standalone: Bool

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, selected: selected, standalone: standalone)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let standalone: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.system(size: standalone ? 30 : 28, weight: standalone && selected ? .semibold : .regular))
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(minHeight: standalone ? 78 : 76)
                .frame(maxWidth: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(isFocused ? Color.white : Color.white.opacity(selected ? 0.12 : 0))
                }
                .scaleEffect(configuration.isPressed ? 0.98 : (isFocused ? 1.015 : 1))
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

/// The options of one setting.
struct ChoiceList: Identifiable {
    let id = UUID()
    let title: String
    let options: [String]
    let selected: Int?
    let choose: (Int) -> Void
}

/// Options on a glass card over the page (like the filter's); choosing one closes it.
struct ChoicePanel: View {
    let list: ChoiceList

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Int?

    var body: some View {
        VStack(spacing: 30) {
            Text(list.title).font(.system(size: 42, weight: .bold))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(list.options.indices, id: \.self) { index in
                        Button {
                            list.choose(index)
                            dismiss()
                        } label: {
                            HStack(spacing: 18) {
                                Text(list.options[index])
                                Spacer(minLength: 20)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundStyle(ArtworkStatusOverlay.orange)
                                    .opacity(index == list.selected ? 1 : 0)
                            }
                        }
                        .buttonStyle(SettingsRowStyle(selected: false, standalone: false))
                        .focused($focused, equals: index)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 720)
            .fixedSize(horizontal: false, vertical: true)
            .defaultFocus($focused, list.selected ?? 0)
        }
        .padding(.vertical, 46)
        .frame(width: 860)
        .background {
            RoundedRectangle(cornerRadius: 48, style: .continuous).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 48, style: .continuous).fill(Color.black.opacity(0.35))
            RoundedRectangle(cornerRadius: 48, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.6).ignoresSafeArea())
        .presentationBackground(.clear)
    }
}
