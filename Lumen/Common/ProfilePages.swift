import SwiftUI

// Profile settings pages shared by the Apple TV and iPhone apps.

// MARK: - Libraries

/// Every Plex library on the server by its real name, each with a switch; libraries that mix
/// anime with other titles also offer «أنمي» and «بدون أنمي» scopes.
struct LibrariesPage: View {
    let client: PlexServerClient
    let sections: [PlexDirectory]
    @Binding var scopes: [String]

    @State private var animeSections: Set<String> = []
    @State private var checking = true

    var body: some View {
        List {
            ForEach(sections) { section in
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
            }
            if checking {
                HStack(spacing: 20) {
                    ProgressView()
                    Text("جارٍ البحث عن الأنمي في المكتبات…").foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 1200)
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
            Section {
                Button("كل الأنواع") { genres = [] }
                    .foregroundStyle(genres.isEmpty ? Color.accentColor : .primary)
            } footer: {
                Text("اختر أنواعاً لتركّز عليها الصفوف والاقتراحات. إذا ما اخترت شي، تطلع كل الأنواع.")
            }
            Section {
                if loading { ProgressView() }
                ForEach(available, id: \.self) { genre in
                    Toggle(ArabicFormat.genre(genre), isOn: Binding {
                        genres.contains(genre)
                    } set: { on in
                        if on { genres.append(genre) } else { genres.removeAll { $0 == genre } }
                    })
                }
            }
        }
        .frame(maxWidth: 1100)
        .navigationTitle("الأنواع المفضّلة")
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
