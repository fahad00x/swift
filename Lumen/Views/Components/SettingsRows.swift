import SwiftUI

/// Settings switch with Arabic state words (a system Toggle shows its own), optionally with an icon.
struct ArabicToggle: View {
    let title: String
    let systemImage: String?
    @Binding var isOn: Bool

    init(_ title: String, systemImage: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.systemImage = systemImage
        _isOn = isOn
    }

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 20) {
                if let systemImage { RowIcon(name: systemImage) }
                Text(title)
                Spacer(minLength: 20)
                Text(isOn ? "مفعّل" : "متوقف").foregroundStyle(.secondary)
            }
        }
    }

    /// Amber; black on the white focused row.
    private struct RowIcon: View {
        let name: String
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            Image(systemName: name)
                .foregroundStyle(isFocused ? Color.black : Color(red: 1, green: 0.68, blue: 0.16))
                .frame(width: 50)
        }
    }
}

/// Section explanation: smaller and grey, under the rows it explains.
struct FooterText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 22))
            .foregroundStyle(.white.opacity(0.55))
    }
}

/// White page title that scrolls with the content (a tvOS navigation title is dark grey and stays put).
struct PageTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 57, weight: .bold))
            .foregroundStyle(.white)
            .textCase(nil)
            .frame(maxWidth: .infinity)
    }
}
