import SwiftUI

// MARK: - PIN pad

/// Four-digit PIN entry with big buttons for the Siri Remote.
struct PinPadView: View {
    let title: String
    var subtitle: String?
    /// Return true to accept (the caller closes the pad); false shows an error and clears.
    let onSubmit: (String) -> Bool
    let onCancel: () -> Void

    @State private var digits = ""
    @State private var error: String?
    @State private var shake: CGFloat = 0
    @FocusState private var focusedKey: String?

    private let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["cancel", "0", "delete"]]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 44) {
                VStack(spacing: 14) {
                    Text(title).font(.title2.weight(.bold))
                    if let subtitle {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 30) {
                    ForEach(0..<ProfilePIN.length, id: \.self) { i in
                        Circle()
                            .fill(i < digits.count ? Color.white : Color.white.opacity(0.18))
                            .frame(width: 34, height: 34)
                    }
                }
                .offset(x: shake)
                .environment(\.layoutDirection, .leftToRight)

                Text(error ?? " ")
                    .font(.callout)
                    .foregroundStyle(.red)

                VStack(spacing: 26) {
                    ForEach(rows, id: \.self) { row in
                        HStack(spacing: 34) {
                            ForEach(row, id: \.self) { key in keyButton(key) }
                        }
                    }
                }
                .environment(\.layoutDirection, .leftToRight)
                .focusSection()
            }
        }
        .defaultFocus($focusedKey, "5")
        .onExitCommand(perform: onCancel)
    }

    @ViewBuilder
    private func keyButton(_ key: String) -> some View {
        Button { press(key) } label: {
            switch key {
            case "cancel": Image(systemName: "xmark")
            case "delete": Image(systemName: "delete.left")
            default: Text(ArabicFormat.digits(key)).font(.system(size: 48, weight: .semibold))
            }
        }
        .buttonStyle(PinKeyStyle())
        .focused($focusedKey, equals: key)
    }

    private func press(_ key: String) {
        switch key {
        case "cancel":
            onCancel()
        case "delete":
            if !digits.isEmpty { digits.removeLast() }
        default:
            guard digits.count < ProfilePIN.length else { return }
            error = nil
            digits.append(key)
            if digits.count == ProfilePIN.length {
                let pin = digits
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if !onSubmit(pin) { reject() }
                }
            }
        }
    }

    private func reject() {
        error = "الرمز غير صحيح"
        digits = ""
        withAnimation(.spring(response: 0.08, dampingFraction: 0.2)) { shake = 24 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.spring()) { shake = 0 }
        }
    }
}

private struct PinKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        KeyBody(configuration: configuration)
    }

    private struct KeyBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .frame(width: 130, height: 130)
                .background(Circle().fill(isFocused ? Color.white : Color.white.opacity(0.14)))
                .scaleEffect(configuration.isPressed ? 0.92 : (isFocused ? 1.12 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 16, y: 8)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

/// Choose a new PIN: enter it, then confirm it.
struct PinSetupView: View {
    let onDone: (String) -> Void
    let onCancel: () -> Void
    @State private var first: String?

    var body: some View {
        if let first {
            PinPadView(title: "أكّد الرمز", subtitle: "أدخل الرمز مرة ثانية") { pin in
                guard pin == first else { return false }
                onDone(pin)
                return true
            } onCancel: { self.first = nil }
            .id("confirm")
        } else {
            PinPadView(title: "رمز PIN جديد", subtitle: "اختر ٤ أرقام") { pin in
                first = pin
                return true
            } onCancel: {
                onCancel()
            }
            .id("first")
        }
    }
}

extension View {
    /// Presents `request` as a PIN pad; runs its action once a matching PIN is entered.
    func pinRequest(_ request: Binding<PinRequest?>) -> some View {
        fullScreenCover(item: request) { req in
            PinPadView(title: req.title, subtitle: req.subtitle) { pin in
                guard req.profiles.contains(where: { ProfilePIN.verify(pin, profile: $0) }) else { return false }
                request.wrappedValue = nil
                DispatchQueue.main.async { req.onSuccess() }
                return true
            } onCancel: {
                request.wrappedValue = nil
            }
        }
    }
}

