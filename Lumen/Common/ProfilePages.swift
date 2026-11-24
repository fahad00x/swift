import SwiftUI

// Profile settings pages shared by the Apple TV and iPhone apps.

// MARK: - Libraries

/// Every Plex library on the server by its real name, each with a switch. On iPhone, libraries
/// that mix anime with other titles also offer «أنمي» and «بدون أنمي» scopes; Apple TV shows
/// only the real libraries (no virtual split, no explanation).
struct LibrariesPage: View {
    let client: PlexServerClient
    let sections: [PlexDirectory]
    @Binding var scopes: [String]

    @State private var animeSections: Set<String> = []
    @State private var checking = true

    var body: some View {
        List {
            #if os(tvOS)
            Section {} header: { PageTitle("المكتبات") }
            #endif
            ForEach(sections) { section in
                #if os(tvOS)
                ArabicToggle(section.title, systemImage: section.type == "show" ? "tv" : "film",
                             isOn: libraryBinding(section))
                #else
                Section {
                    Toggle(isOn: binding(.all, section)) {
                        Label(section.title, systemImage: section.type == "show" ? "tv" : "film")
                    }
                    if animeSections.contains(section.key) || hasSplitScope(section) {
                        Toggle(isOn: binding(.anime, section)) {
                            Label("أنمي (من \(section.title))", systemImage: "sparkles")
                        }
                        Toggle(isOn: binding(.noAnime, section)) {
                            Label("\(section.title) بدون أنمي", systemImage: "line.3.horizontal.decrease.circle")
                        }
                    }
                } footer: {
                    if animeSections.contains(section.key) {
                        Text("هذه المكتبة فيها أنمي مخلوط. «أنمي» يعرض العناصر اللي نوعها Anime، أو Animation من اليابان، أو عليها تصنيف أو مجموعة Anime. «بدون أنمي» يعرض الباقي.")
                    }
                }
                #endif
            }
            #if !os(tvOS)
            if checking {
                HStack(spacing: 20) {
                    ProgressView()
                    Text("جارٍ البحث عن الأنمي في المكتبات…").foregroundStyle(.secondary)
                }
            }
            #endif
        }
        .frame(maxWidth: 1200)
        #if !os(tvOS)
        .navigationTitle("المكتبات")
        .task {
            await withTaskGroup(of: (String, Bool).self) { group in
                for section in sections {
                    group.addTask { (section.key, await AnimeClassifier.libraryHasAnime(section, client: client)) }
                }
                for await (key, hasAnime) in group where hasAnime { animeSections.insert(key) }
            }
            checking = false
        }
        #endif
    }

    /// Apple TV: the whole library on / off. An older anime / non-anime choice counts as on;
    /// turning it off removes every scope of that library, turning it on keeps one plain entry.
    private func libraryBinding(_ section: PlexDirectory) -> Binding<Bool> {
        let all = ScopeID(.all, section.key).raw
        let ofSection = { (raw: String) in ScopeID(raw: raw)?.sectionKey == section.key }
        return Binding {
            scopes.contains(where: ofSection)
        } set: { on in
            if on {
                if let i = scopes.firstIndex(where: ofSection) {
                    scopes[i] = all
                    var seen = false
                    scopes.removeAll { raw in
                        guard ofSection(raw) else { return false }
                        if !seen { seen = true; return false }
                        return true
                    }
                } else {
                    scopes.append(all)
                }
            } else {
                scopes.removeAll(where: ofSection)
            }
        }
    }

    private func hasSplitScope(_ section: PlexDirectory) -> Bool {
        scopes.contains(ScopeID(.anime, section.key).raw) || scopes.contains(ScopeID(.noAnime, section.key).raw)
    }

    private func binding(_ kind: ScopeID.Kind, _ section: PlexDirectory) -> Binding<Bool> {
        let id = ScopeID(kind, section.key).raw
        return Binding {
            scopes.contains(id)
        } set: { on in
            if on {
                if !scopes.contains(id) { scopes.append(id) }
            } else {
                scopes.removeAll { $0 == id }
            }
        }
    }
}

// MARK: - Genres

struct GenresPage: View {
    let client: PlexServerClient
    let sections: [PlexDirectory]
    @Binding var genres: [String]

    @State private var available: [String] = []
    @State private var loading = true

    var body: some View {
        List {
            #if os(tvOS)
            Section {} header: { PageTitle("الأنواع المفضّلة") }
            #endif
            Section {
                Button("كل الأنواع") { genres = [] }
                    .foregroundStyle(genres.isEmpty ? Color.accentColor : .primary)
            } footer: {
                #if os(tvOS)
                FooterText("اختر أنواعاً لتركّز عليها الصفوف والاقتراحات. إذا ما اخترت شي، تطلع كل الأنواع.")
                #else
                Text("اختر أنواعاً لتركّز عليها الصفوف والاقتراحات. إذا ما اخترت شي، تطلع كل الأنواع.")
                #endif
            }
            Section {
                if loading { ProgressView() }
                ForEach(available, id: \.self) { genre in
                    let isOn = Binding {
                        genres.contains(genre)
                    } set: { on in
                        if on { genres.append(genre) } else { genres.removeAll { $0 == genre } }
                    }
                    #if os(tvOS)
                    ArabicToggle(ArabicFormat.genre(genre), isOn: isOn)
                    #else
                    Toggle(ArabicFormat.genre(genre), isOn: isOn)
                    #endif
                }
            }
        }
        .frame(maxWidth: 1100)
        #if !os(tvOS)
        .navigationTitle("الأنواع المفضّلة")
        #endif
        .task {
            var all = Set<String>(genres)
            await withTaskGroup(of: [String].self) { group in
                for section in sections { group.addTask { await client.genres(section: section) } }
                for await list in group { all.formUnion(list) }
            }
            available = all.sorted { ArabicFormat.genre($0) < ArabicFormat.genre($1) }
            loading = false
        }
    }
}
