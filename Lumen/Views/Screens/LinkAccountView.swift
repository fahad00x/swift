import SwiftUI

/// Sign-in with a PIN: the user visits plex.tv/link on any device and types the code.
struct LinkAccountView: View {
    @Environment(AppSession.self) private var session
    @State private var pin: PlexPin?
    @State private var errorMessage: String?
    @State private var attempt = 0

    var body: some View {
        HStack(spacing: 140) {
            VStack(alignment: .leading, spacing: 36) {
                HStack(spacing: 20) {
                    Image(systemName: "play.rectangle.on.rectangle.fill")
                        .font(.system(size: 70))
                        .foregroundStyle(Color.accentColor)
                    Text("Lumen")
                        .font(.system(size: 84, weight: .heavy, design: .rounded))
                }

                Text("اربط حسابك في Plex")
                    .font(.title2.weight(.semibold))

                VStack(alignment: .leading, spacing: 16) {
                    step(1, "على هاتفك أو حاسوبك افتح الرابط:  plex.tv/link")
                    step(2, "سجّل الدخول إلى حسابك في Plex")
                    step(3, "أدخل الرمز الظاهر هنا")
                }

                Group {
                    if let pin {
                        Text(pin.code)
                            .font(.system(size: 120, weight: .bold, design: .monospaced))
                            .kerning(28)
                            .environment(\.layoutDirection, .leftToRight)
                            .padding(.horizontal, 50)
                            .padding(.vertical, 20)
                            .background(RoundedRectangle(cornerRadius: 28).fill(Color.white.opacity(0.08)))
                    } else {
                        ProgressView().frame(height: 180)
                    }
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }

                HStack(spacing: 18) {
                    ProgressView()
                    Text("بانتظار تأكيد الربط…").foregroundStyle(.secondary)
                    Spacer().frame(width: 40)
                    Button("رمز جديد") { attempt += 1 }
                }
            }

            VStack(spacing: 24) {
                QRCodeView(text: "https://plex.tv/link")
                    .frame(width: 360, height: 360)
                    .padding(24)
                    .background(RoundedRectangle(cornerRadius: 28).fill(.white))
                Text("امسح الرمز بالكاميرا")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(100)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: attempt) { await runLinkFlow() }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 18) {
            Text("\(n)")
                .font(.callout.weight(.bold))
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.accentColor))
                .foregroundStyle(.black)
            Text(text).font(.callout)
        }
    }

    private func runLinkFlow() async {
        pin = nil
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
                        // Not awaited here: signing in replaces this screen, which cancels this
                        // view's task (and any request still running in it).
                        session.beginSignIn(token: token)
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
        VStack(alignment: .leading, spacing: 40) {
            Text("اختر خادم Plex")
                .font(.title.weight(.bold))
            if let user = session.user {
                Text("مرحباً \(user.displayName)").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 24) {
                    ForEach(session.servers) { server in
                        Button {
                            Task { await session.connect(to: server) }
                        } label: {
                            HStack(spacing: 30) {
                                Image(systemName: "server.rack")
                                    .font(.system(size: 44))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(server.name).font(.headline)
                                    Text(server.owned ? "خادمك" : "خادم مشترك معك")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Circle()
                                    .fill(server.presence ? Color.green : Color.gray)
                                    .frame(width: 16, height: 16)
                            }
                            .padding(.horizontal, 30)
                            .padding(.vertical, 20)
                            .frame(maxWidth: 1200)
                        }
                    }
                }
                .padding(40)
            }
            Button("تسجيل الخروج", role: .destructive) { session.signOut() }
        }
        .padding(100)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
