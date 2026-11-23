import SwiftUI
import UIKit

/// Sign-in with a PIN: open plex.tv/link, sign in and type the code shown here.
struct LinkAccountView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openURL) private var openURL
    @State private var pin: PlexPin?
    @State private var errorMessage: String?
    @State private var attempt = 0
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Image(systemName: "play.rectangle.on.rectangle.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(Theme.accent)
                    Text("Lumen")
                        .font(.system(size: 46, weight: .heavy, design: .rounded))
                    Text("اربط حسابك في Plex")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)

                Group {
                    if let pin {
                        Text(pin.code)
                            .font(.system(size: 56, weight: .bold, design: .monospaced))
                            .kerning(10)
                            .environment(\.layoutDirection, .leftToRight)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.08)))
                    } else {
                        ProgressView().frame(height: 90)
                    }
                }

                VStack(spacing: 12) {
                    Button {
                        if let code = pin?.code { UIPasteboard.general.string = code; copied = true }
                        openURL(URL(string: "https://plex.tv/link")!)
                    } label: {
                        Label("نسخ الرمز وفتح plex.tv/link", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(pin == nil)

                    if copied {
                        Text("تم نسخ الرمز — الصقه في الصفحة ثم ارجع هنا")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    step(1, "افتح plex.tv/link وسجّل الدخول إلى حسابك في Plex")
                    step(2, "أدخل الرمز الظاهر أعلاه")
                    step(3, "ارجع للتطبيق، يرتبط تلقائياً")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }

                HStack(spacing: 10) {
                    ProgressView()
                    Text("بانتظار تأكيد الربط…").foregroundStyle(.secondary)
                    Spacer()
                    Button("رمز جديد") { attempt += 1 }
                }
            }
            .padding(24)
        }
        .task(id: attempt) { await runLinkFlow() }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text(ArabicFormat.digits(n))
                .font(.callout.weight(.bold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.accent))
                .foregroundStyle(.black)
            Text(text).font(.callout)
        }
    }

    private func runLinkFlow() async {
        pin = nil
        copied = false
        while !Task.isCancelled {
            do {
                let newPin = try await PlexAccount.createPin()
                pin = newPin
                errorMessage = nil
                let deadline = Date().addingTimeInterval(TimeInterval(newPin.expiresIn ?? 900))
                while Date() < deadline {
                    try await Task.sleep(for: .seconds(2))
                    let checked = try await PlexAccount.checkPin(id: newPin.id)
                    if let token = checked.authToken, !token.isEmpty {
                        await session.completeSignIn(token: token)
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = "تعذّر الاتصال بـ plex.tv — سنحاول مجدداً."
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

struct ServerPickerView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        NavigationStack {
            List {
                if let user = session.user {
                    Section { Text("مرحباً \(user.displayName)").foregroundStyle(.secondary) }
                }
                Section("الخوادم") {
                    ForEach(session.servers) { server in
                        Button {
                            Task { await session.connect(to: server) }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "server.rack").font(.title2)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(server.name).font(.headline)
                                    Text(server.owned ? "خادمك" : "خادم مشترك معك")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Circle().fill(server.presence ? Color.green : Color.gray).frame(width: 10, height: 10)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                Section {
                    Button("تسجيل الخروج", role: .destructive) { session.signOut() }
                }
            }
            .navigationTitle("اختر خادم Plex")
        }
    }
}
