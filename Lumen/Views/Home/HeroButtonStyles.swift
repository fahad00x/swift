import SwiftUI

// Banner and details buttons. Every colour is explicit: the system bordered style mixes in
// the app's amber tint differently on a real Apple TV and on the simulator.

extension View {
    /// Play / Resume.
    func nativePillButton() -> some View { buttonStyle(HeroButtonStyle(circle: false)) }
    /// +, i, next, episodes.
    func nativeCircleButton() -> some View { buttonStyle(HeroButtonStyle(circle: true)) }
}

/// Focused: light fill, black label. Otherwise dark glass with an amber label.
private struct HeroButtonStyle: ButtonStyle {
    let circle: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, circle: circle)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        let circle: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(isFocused ? Color.black : Color(red: 1, green: 0.68, blue: 0.16))
                .padding(.horizontal, circle ? 0 : 32)
                .frame(width: circle ? 60 : nil, height: circle ? 60 : 66)
                .background {
                    Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Color(white: 0.82)).opacity(isFocused ? 1 : 0)
                }
                .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.1 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 16, y: 8)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}
