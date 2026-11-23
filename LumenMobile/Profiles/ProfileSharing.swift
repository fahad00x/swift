import CloudKit
import SwiftUI
import UIKit

// Sharing a profile with another iCloud account (e.g. a family member's own iPhone):
// the owner invites from Settings with the system sharing screen; the invitation link opens
// Lumen on the other iPhone, which joins the profile (see LumenSceneDelegate).

/// «مشاركة» row for one profile in Settings.
struct ShareProfileRow: View {
    let profile: UserProfile

    @Environment(ProfileStore.self) private var store
    @State private var sharing: SharingItem?
    @State private var isPreparing = false
    @State private var errorMessage: String?

    var body: some View {
        Button {
            Task { await prepare() }
        } label: {
            HStack(spacing: 14) {
                ProfileAvatar(profile: profile, size: 36)
                Text("مشاركة «\(profile.name)»")
                Spacer()
                if isPreparing { ProgressView() } else { Image(systemName: "person.crop.circle.badge.plus") }
            }
        }
        .foregroundStyle(.primary)
        .disabled(isPreparing)
        .sheet(item: $sharing) { item in
            CloudSharingSheet(share: item.share, container: item.container)
                .ignoresSafeArea()
        }
        .alert("تعذّرت المشاركة", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func prepare() async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            let (share, container) = try await store.prepareShare(for: profile)
            sharing = SharingItem(share: share, container: container)
        } catch {
            errorMessage = CloudKitSync.describe(error)
        }
    }
}

private struct SharingItem: Identifiable {
    let id = UUID()
    let share: CKShare
    let container: CKContainer
}

/// The system screen to invite people (Messages, Mail, link) and manage who has access.
private struct CloudSharingSheet: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(title: share[CKShare.SystemFieldKey.title] as? String) }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let title: String?
        init(title: String?) { self.title = title }

        func itemTitle(for csc: UICloudSharingController) -> String? { title.map { "Lumen" + ArabicFormat.separator + $0 } }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {}
    }
}

// MARK: - Accepting an invitation

/// Receives the invitation when its link is opened (app running or launched by it).
final class LumenAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = LumenSceneDelegate.self
        return configuration
    }
}

final class LumenSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata { accept(metadata) }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        accept(cloudKitShareMetadata)
    }

    private func accept(_ metadata: CKShare.Metadata) {
        Task { @MainActor in await ProfileStore.shared.acceptShare(metadata) }
    }
}
