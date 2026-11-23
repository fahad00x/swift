import SwiftUI

// Button styles shared by the details page (the Home hero carousel was removed).


/// White capsule (Play / Resume).
struct HeroPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.headline)
                .foregroundStyle(.black)
                .padding(.horizontal, 46)
                .frame(height: 76)
                .background(Capsule().fill(Color.white.opacity(isFocused ? 1 : 0.88)))
                .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.1 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 18, y: 10)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}

/// Small round icon button (+, i, >).
struct HeroCircleButtonStyle: ButtonStyle {
    var dimmed = false

    func makeBody(configuration: Configuration) -> some View {
        CircleBody(configuration: configuration, dimmed: dimmed)
    }

    private struct CircleBody: View {
        let configuration: ButtonStyleConfiguration
        let dimmed: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .frame(width: 76, height: 76)
                .background(Circle().fill(isFocused ? Color.white : Color.white.opacity(0.2)))
                .opacity(dimmed && !isFocused ? 0.45 : 1)
                .scaleEffect(configuration.isPressed ? 0.94 : (isFocused ? 1.12 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 14, y: 8)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}
