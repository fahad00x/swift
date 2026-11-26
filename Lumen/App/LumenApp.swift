import SwiftUI

@main
struct LumenApp: App {
    @State private var session = AppSession()
    @State private var backdrop = BackdropState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(backdrop)
                .environment(session.profiles)
                .preferredColorScheme(.dark)
                .tint(Color(red: 1.0, green: 0.68, blue: 0.16))
                .task { DolbySpikeAuto.runIfAsked(session) } // SPIKE
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive: session.profiles.flush()
            case .active:
                session.profiles.scheduleSync(after: 0)
                if let client = session.client { LibrarySync.shared.start(client: client) }
            @unknown default: break
            }
        }
    }
}

struct RootView: View {
    @Environment(AppSession.self) private var session
    @Environment(ProfileStore.self) private var profiles

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch session.phase {
            case .launching:
                LoadingView()
            case .signedOut:
                LinkAccountView()
            case .selectingServer:
                ServerPickerView()
            case .connecting(let message):
                LoadingView(message: message)
            case .failed(let message):
                ErrorView(message: message)
            case .ready:
                if let client = session.client {
                    if let profile = profiles.activeProfile {
                        // Rebuilt only for another profile or server: editing the profile's libraries
                        // in Settings must not tear down the screen that is presenting the editor.
                        MainTabView(client: client, sections: session.sections, profile: profile)
                            .id("\(client.machineIdentifier)|\(profile.id)")
                            .transition(.opacity)
                    } else {
                        ProfilePickerView(client: client, sections: session.sections)
                            .transition(.opacity)
                    }
                }
            }
        }
        // «مين يشاهد؟» ↔ Home cross-fade (~0.4 s).
        .animation(.easeInOut(duration: 0.4), value: profiles.activeProfile?.id)
        .task { await session.bootstrap() }
    }
}

struct ErrorView: View {
    let message: String
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(spacing: 40) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 90))
                .foregroundStyle(.yellow)
            Text(message)
                .font(.title3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1100)
            HStack(spacing: 40) {
                Button("إعادة المحاولة") { Task { await session.retry() } }
                if session.servers.count > 1 {
                    Button("اختيار خادم آخر") { session.chooseAnotherServer() }
                }
                Button("تسجيل الخروج", role: .destructive) { session.signOut() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
