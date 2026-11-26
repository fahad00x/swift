import SwiftUI

/// Settings like the Apple TV's: the same seven pages. On a wide iPad the categories sit on the
/// reading side and the chosen one's settings next to them; on the iPhone the categories are a
/// list that opens each page.
struct SettingsView: View {
    let client: PlexServerClient
    let sections: [PlexDirectory]

    enum Page: String, CaseIterable, Identifiable, Hashable {
        case user, playback, tracks, sidebar, server, storage, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .user: return "المستخدم"
            case .playback: return "التشغيل"
            case .tracks: return "الصوت والترجمة"
            case .sidebar: return "المكتبات والشريط الجانبي"
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
            case .sidebar: return "sidebar.right"
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
            case .sidebar: return .teal
            case .server: return .green
            case .storage: return .gray
            case .about: return .indigo
            }
        }
    }

    /// What a page opens (by value, so the pages inside can open theirs).
    private enum Pushed: Hashable { case page(Page), browseLibraries, profileLibraries, importHistory, diagnostics, homeRows, libraryRows(LibraryScope) }

    @Environment(AppSession.self) private var session
    @Environment(ProfileStore.self) private var store
    @Environment(SidebarPrefs.self) private var sidebarPrefs: SidebarPrefs?
    @AppStorage(PlaybackSettings.forceTranscodeKey) private var forceTranscode = false
    @AppStorage(PlaybackSettings.engineKey) private var engine: PlaybackEngine = .mpv
    @AppStorage(PlaybackSettings.autoSkipIntroKey) private var autoSkipIntro = true
    @AppStorage(PlaybackSettings.autoPlayNextKey) private var autoPlayNext = true
    @AppStorage(PlaybackSettings.maxBitrateKey) private var maxBitrate = PlaybackSettings.defaultBitrate
    @AppStorage(PlaybackSettings.fastProfileKey) private var fastProfile = false
    @AppStorage(PlaybackSettings.skipSecondsKey) private var skipSeconds = PlaybackSettings.defaultSkip
    @AppStorage(PlaybackSettings.subtitleLookKey) private var subtitleLook: SubtitleLook = .original
    @AppStorage(PlaybackSettings.subtitlesBelowKey) private var subtitlesBelow = false
    @AppStorage(PlaybackSettings.subtitleSizeKey) private var subtitleSize = PlaybackSettings.defaultSubtitleSize
    @Environment(\.contentFilter) private var filter
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var page: Page = .user
    @State private var path = NavigationPath()
    @State private var confirmUndo = false
    @State private var confirmSignOut = false
    @State private var connection: ConnectionCheck = .idle
    @State private var artworkSize: Int?
    @State private var responseSize: Int?
    @State private var editing: UserProfile?
    @State private var pin: PinRequest?
    @State private var versionTaps = HiddenTapCounter()

    private enum ConnectionCheck: Equatable { case idle, checking, reachable(ms: Int), unreachable }

    private var wide: Bool { Metrics(sizeClass).isWide }

    var body: some View {
        Group {
            if wide {
                HStack(spacing: 0) {
                    categories
                        .frame(width: 330)
                    Divider()
                    BrowseStack(client: client, path: $path) {
                        pageView(page)
                            .navigationTitle(page.title)
                            .navigationBarTitleDisplayMode(.inline)
                            .navigationDestination(for: Pushed.self) { destination($0) }
                    }
                    .id(page)
                }
            } else {
                BrowseStack(client: client, path: $path) {
                    List {
                        Section {
                            NavigationLink(value: Pushed.browseLibraries) {
                                SettingsIcon(title: "تصفّح المكتبات", icon: "square.stack.fill", color: Theme.accent)
                            }
                        }
                        Section {
                            ForEach(Page.allCases) { item in
                                NavigationLink(value: Pushed.page(item)) {
                                    SettingsIcon(title: item.title, icon: item.icon, color: item.color)
                                }
                            }
                        }
                    }
                    .navigationTitle("الإعدادات")
                    .navigationDestination(for: Pushed.self) { destination($0) }
                }
            }
        }
        // Follow the profile to its other devices.
        .onChange(of: autoSkipIntro) { _, on in store.updateSettings { $0.autoSkipIntro = on } }
        .onChange(of: autoPlayNext) { _, on in store.updateSettings { $0.autoPlayNext = on } }
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

    // MARK: Categories (wide iPad)

    private var categories: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("الإعدادات")
                    .font(.largeTitle.weight(.bold))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
                ForEach(Page.allCases) { item in
                    Button {
                        page = item
                        path = NavigationPath()
                    } label: {
                        SettingsIcon(title: item.title, icon: item.icon, color: item.color)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(item == page ? Color.white.opacity(0.14) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 60)
        }
        .background(Color(white: 0.06))
    }

    @ViewBuilder
    private func destination(_ pushed: Pushed) -> some View {
        switch pushed {
        case .page(let page):
            pageView(page).navigationTitle(page.title)
        case .browseLibraries:
            LibrariesSettingsView(client: client, sections: sections)
        case .profileLibraries:
            LibrariesPage(client: client, sections: sections, scopes: activeScopes)
        case .diagnostics:
            HomeDiagnosticsView(client: client)
        case .homeRows:
            HomeRowsPage(client: client)
        case .libraryRows(let scope):
            HomeRowsPage(client: client, target: .library(scope.id), scope: scope)
        case .importHistory:
            if let profile = store.activeProfile {
                PlexImportPage(client: client, sections: filter.sections, profile: profile)
            }
        }
    }

    // MARK: Pages

    @ViewBuilder
    private func pageView(_ page: Page) -> some View {
        Form {
            switch page {
            case .user: userPage
            case .playback: playbackPage
            case .tracks: tracksPage
            case .sidebar: sidebarPage
            case .server: serverPage
            case .storage: storagePage
            case .about: aboutPage
            }
        }
        .readableColumn(Metrics(sizeClass))
    }

    @ViewBuilder
    private var userPage: some View {
        if let profile = store.activeProfile {
            Section {
                HStack(spacing: 16) {
                    ProfileAvatar(profile: profile, size: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name).font(.title2.weight(.bold))
                        if profile.isKids { Text("حساب أطفال").font(.callout).foregroundStyle(.secondary) }
                    }
                }
                .listRowBackground(Color.clear)
            }
            Section {
                row("تبديل المستخدم") { store.deactivate() }
                row("تعديل المستخدم", detail: "الاسم والصورة والرمز والأنواع") { editProfile(profile) }
                row("المكتبات", detail: "إظهار وإخفاء مكتبات هذا المستخدم",
                    value: "\(ArabicFormat.digits(profile.scopes.count)) ظاهرة") {
                    guardedKids("مطلوب لتغيير مكتبات حساب الأطفال") { path.append(Pushed.profileLibraries) }
                }
                Toggle(isOn: Binding(get: { store.rememberLastProfile }, set: { store.setRememberLastProfile($0) })) {
                    labelled("تذكّر آخر مستخدم", "يفتح عليه مباشرة بدون شاشة «مين يشاهد؟»")
                }
            }
            Section("الرئيسية") {
                row("صفوف الرئيسية", detail: "الترتيب، ثابت أو ديناميكي، الإضافة والحذف") { path.append(Pushed.homeRows) }
                Menu {
                    ForEach(filter.scopes.filter(\.section.isVideoLibrary)) { scope in
                        Button(scope.title) { path.append(Pushed.libraryRows(scope)) }
                    }
                } label: {
                    HStack {
                        labelled("صفوف المكتبات", "نفسها لتبويب «مقترح» في كل مكتبة")
                        Spacer()
                        Image(systemName: "chevron.left").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
                Picker("ترتيب متابعة المشاهدة", selection: Binding(
                    get: { store.activeProfile?.settings?.continueNewFirst ?? false },
                    set: { on in store.updateSettings { $0.continueNewFirst = on } })) {
                    Text("الأحدث مشاهدة أولًا").tag(false)
                    Text("الجديد أولًا").tag(true)
                }
            }
            Section("سجل المشاهدة") {
                row("استيراد سجل المشاهدة من Plex", detail: "لهذا المستخدم فقط") {
                    guarded { path.append(Pushed.importHistory) }
                }
                if store.canUndoImport {
                    row("التراجع عن آخر استيراد", detail: "يرجّع السجل كما كان قبله", arrow: false) { confirmUndo = true }
                }
                // Ratings are the profile's own; the server's are the account's, shared by every
                // profile, so only the account's own profile can send them there.
                if store.activeProfile?.isOwner == true {
                    Toggle(isOn: Binding(
                        get: { store.activeProfile?.settings?.ratingsToPlex ?? false },
                        set: { on in store.updateSettings { $0.ratingsToPlex = on } })) {
                        labelled("إرسال التقييمات إلى Plex", "تقييماتك تظهر في Plex أيضًا")
                    }
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
                Text("تقدّم المشاهدة والمشاهَد وقائمتي والمكتبات محفوظة في iCloud وعلى الجهاز، ولا تُرسل إلى Plex.")
            }
            if store.cloudStatus != .localOnly, !profile.isKids {
                Section {
                    ForEach(store.profiles) { other in
                        if store.isSharedWithMe(other) {
                            HStack(spacing: 14) {
                                ProfileAvatar(profile: other, size: 36)
                                Text(other.name)
                                Spacer()
                                Text("مشارَك معك").font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            ShareProfileRow(profile: other)
                        }
                    }
                } header: {
                    Text("المشاركة مع حساب iCloud آخر")
                } footer: {
                    Text("بعد قبول الدعوة يظهر المستخدم في Lumen على الجهاز الثاني، ويتزامن تقدّمه وقائمته وإعداداته بين الجهازين.")
                }
            }
        }
    }

    @ViewBuilder
    private var playbackPage: some View {
        Section {
            Picker("مشغّل الفيديو", selection: $engine) {
                ForEach(PlaybackEngine.allCases) { Text($0.title).tag($0) }
            }
            Picker("الحد الأقصى للجودة", selection: $maxBitrate) {
                ForEach(PlaybackSettings.bitrateOptions, id: \.kbps) { Text($0.title).tag($0.kbps) }
            }
            if engine == .mpv {
                Picker(selection: $skipSeconds) {
                    ForEach([5, 10, 15, 30], id: \.self) { Text(Self.seconds($0)).tag($0) }
                } label: { labelled("التقديم والترجيع", "ضغطتين على طرف الشاشة، وأزرار المشغّل") }
            }
        } header: {
            Text("المشغّل")
        } footer: {
            Text(engine == .mpv
                 ? "يشغّل الملف الأصلي مباشرة بكل صيغه. خارج البيت قلّل الجودة لتوفير البيانات."
                 : "يشغّل MP4/MOV مباشرة، وباقي الصيغ يحوّلها خادم Plex. أزرار مشغّل Lumen لا تظهر معه.")
        }
        Section {
            Toggle("التخطي التلقائي", isOn: $autoSkipIntro)
            Toggle("تشغيل الحلقة التالية تلقائيًا", isOn: $autoPlayNext)
        } header: {
            Text("الحلقات")
        } footer: {
            Text("يكتشف خادم Plex المقدمة والختام (Plex Pass: فعّل Intro/Credits detection في إعدادات المكتبة).")
        }
        Section("متقدم") {
            if engine == .mpv {
                Toggle(isOn: $fastProfile) { labelled("وضع الأداء العالي", "للأجهزة الأقدم إذا تقطّع الفيديو") }
            }
            Toggle(isOn: $forceTranscode) { labelled("التحويل عبر الخادم دائمًا", "إذا كانت الشبكة بطيئة (Transcode)") }
        }
    }

    @ViewBuilder
    private var tracksPage: some View {
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
            Text("اللغة المفضّلة")
        } footer: {
            Text("لهذا المستخدم وتتزامن مع أجهزته. اختيارك لحلقة معيّنة داخل المشغّل له الأولوية.")
        }
        Section {
            Picker(selection: $subtitleLook) {
                ForEach(SubtitleLook.allCases) { Text($0.title).tag($0) }
            } label: { labelled("ترجمات ASS", "الترجمات المصمّمة") }
            Toggle(isOn: $subtitlesBelow) {
                labelled("الترجمة تحت الصورة", "في الشريط الأسود لما يكون الجهاز عمودي")
            }
            Picker("حجم الخط", selection: $subtitleSize) {
                ForEach(PlaybackSettings.subtitleSizes, id: \.size) { Text($0.title).tag($0.size) }
            }
            // How it looks, at the size chosen (mpv sizes text for a 720-line screen).
            ZStack {
                LinearGradient(colors: [Color(white: 0.28), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                Text("هكذا تظهر الترجمة")
                    .font(.system(size: CGFloat(subtitleSize) * (wide ? 0.9 : 0.6), weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 2)
                    .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
            }
            .frame(height: wide ? 130 : 90)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        } header: {
            Text("شكل الترجمة")
        } footer: {
            Text("في مشغّل Lumen. «توحيد الحوار» يعطي حوار ASS نفس الخط واللون والحجم ويترك اللوحات والأغاني. ترجمات الصور لا تتغيّر.")
        }
    }

    /// The Apple TV's «الشريط الجانبي»: up to four libraries pinned, in order; the rest under «المزيد».
    @ViewBuilder
    private var sidebarPage: some View {
        let scopes = filter.scopes
        if let prefs = sidebarPrefs {
            let pinned = prefs.pinned(from: scopes)
            let rest = scopes.filter { scope in !pinned.contains { $0.id == scope.id } }
            Section {
                if pinned.isEmpty { Text("لا توجد مكتبات").foregroundStyle(.secondary) }
                ForEach(Array(pinned.enumerated()), id: \.element.id) { index, scope in
                    HStack(spacing: 14) {
                        Button { prefs.toggle(scope, in: scopes) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red).font(.title3)
                        }
                        .buttonStyle(.borderless)
                        Label(scope.title, systemImage: scope.icon)
                        Spacer()
                        Button { prefs.moveUp(scope, in: scopes) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                        Button { prefs.moveUp(pinned[index + 1], in: scopes) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                            .disabled(index == pinned.count - 1)
                    }
                }
            } header: {
                Text("في الشريط الجانبي")
            } footer: {
                Text("حتى \(ArabicFormat.digits(SidebarPrefs.maxPinned)) مكتبات بهذا الترتيب، على الآيباد والآبل تي في. اضغط «−» لإزالتها، والأسهم ترتّبها.")
            }
            if !rest.isEmpty {
                Section("تحت «المزيد»") {
                    ForEach(rest) { scope in
                        HStack(spacing: 14) {
                            Button { prefs.toggle(scope, in: scopes) } label: {
                                Image(systemName: "plus.circle.fill").foregroundStyle(.green).font(.title3)
                            }
                            .buttonStyle(.borderless)
                            Label(scope.title, systemImage: scope.icon)
                        }
                    }
                }
            }
        }
        Section {
            row("إظهار وإخفاء المكتبات", value: "\(ArabicFormat.digits(scopes.count)) ظاهرة") {
                guardedKids("مطلوب لتغيير مكتبات حساب الأطفال") { path.append(Pushed.profileLibraries) }
            }
            row("تصفّح المكتبات") { path.append(Pushed.browseLibraries) }
        } footer: {
            Text("المكتبات المخفية تختفي من الرئيسية والبحث ومتابعة المشاهدة لهذا المستخدم فقط.")
        }
    }

    @ViewBuilder
    private var serverPage: some View {
        Section("الخادم") {
            LabeledContent("متصل بـ", value: client.name)
            LabeledContent("نوع الاتصال", value: client.isLocal ? "شبكة محلية" : "عن بُعد")
            Button {
                Task { await checkConnection() }
            } label: {
                LabeledContent("فحص الاتصال", value: connectionText ?? "")
            }
            .foregroundStyle(.primary)
            if session.servers.count > 1 {
                row("تغيير الخادم") { guarded { session.chooseAnotherServer() } }
            }
        }
        Section {
            LibrarySyncStatusRow()
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
        } header: {
            Text("المكتبة")
        } footer: {
            Text("يعيد تحميل الاتصال والمكتبات وكل الشاشات من الخادم.")
        }
        Section("حساب Plex") {
            HStack(spacing: 14) {
                RemoteImage(url: session.user?.thumb.flatMap(URL.init(string:)))
                    .frame(width: 48, height: 48)
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
    }

    @ViewBuilder
    private var storagePage: some View {
        Section {
            Button {
                Task { await ImageLoader.shared.clearDisk(); await measure() }
            } label: {
                LabeledContent { Text(Self.bytes(artworkSize)) } label: { labelled("مسح الصور", "البوسترات والخلفيات") }
            }
            Button {
                Task {
                    await Task.detached { PlexResponseCache.clear() }.value
                    await measure()
                }
            } label: {
                LabeledContent { Text(Self.bytes(responseSize)) } label: {
                    labelled("مسح بيانات المكتبة المؤقتة", "الصفوف وصفحات التفاصيل")
                }
            }
        } header: {
            Text("على هذا الجهاز")
        } footer: {
            Text("مسحها آمن: تُحمَّل من جديد عند الحاجة، ولا يتأثر تقدّم المشاهدة ولا قائمتي.")
        }
        .foregroundStyle(.primary)
        .task { await measure() }
        Section {
            LabeledContent("التنزيلات",
                           value: ArabicFormat.fileSize(Downloads.shared.usedBytes))
        } footer: {
            Text("تحذفها من تبويب «التنزيلات».")
        }
    }

    @ViewBuilder
    private var aboutPage: some View {
        Section("Lumen") {
            // Five taps open the hidden Home tuning screen.
            LabeledContent("الإصدار", value: ArabicFormat.digits("\(PlexClientInfo.version) (\(PlexClientInfo.build))"))
                .contentShape(Rectangle())
                .onTapGesture { if versionTaps.tap() { path.append(Pushed.diagnostics) } }
            LabeledContent("النظام", value: ArabicFormat.digits("\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"))
            LabeledContent("المشغّل", value: engine == .mpv ? "MPV" : "AVPlayer")
        }
        Section("المصادر والتراخيص") {
            license("MPV / MPVKit", "مشغّل الفيديو، بترخيص GPL.")
            license("TMDB", "يستخدم التطبيق واجهة TMDB، وهو غير معتمد منها ولا مصدّق عليه.")
            license("anime-offline-database", "تصنيفات الأنمي وتقييماته، من manami-project بترخيص ODbL 1.0. ربط المعرّفات من Fribb/anime-lists.")
        }
    }

    // MARK: Rows

    /// A row that does something: title (and a note), its value, an arrow when it opens a page.
    private func row(_ title: String, detail: String? = nil, value: String? = nil, arrow: Bool = true,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                labelled(title, detail)
                Spacer()
                if let value { Text(value).foregroundStyle(.secondary) }
                if arrow { Image(systemName: "chevron.left").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func labelled(_ title: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }

    /// Saves straight to the active profile.
    private var activeScopes: Binding<[String]> {
        Binding {
            store.activeProfile?.scopes ?? []
        } set: { scopes in
            guard var profile = store.activeProfile else { return }
            profile.scopes = scopes
            store.update(profile)
        }
    }

    /// A kids profile needs the main profile's PIN to change its settings.
    private func guardedKids(_ subtitle: String, _ action: @escaping () -> Void) {
        guard let profile = store.activeProfile, profile.isKids else { action(); return }
        let editors = ProfileGate.editors(for: profile, store: store)
        guard !editors.isEmpty else { action(); return }
        pin = PinRequest(title: "رمز المستخدم الرئيسي", subtitle: subtitle, profiles: editors, onSuccess: action)
    }

    private func editProfile(_ profile: UserProfile) {
        guardedKids("مطلوب لتغيير إعدادات حساب الأطفال") { editing = profile }
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

    private func guarded(_ action: @escaping () -> Void) {
        guard let profile = store.activeProfile, profile.isKids else { action(); return }
        let editors = ProfileGate.editors(for: profile, store: store)
        guard !editors.isEmpty else { action(); return }
        pin = PinRequest(title: "رمز المستخدم الرئيسي", profiles: editors, onSuccess: action)
    }
}
