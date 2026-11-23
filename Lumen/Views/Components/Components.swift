import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - Full-screen backdrop

struct BackdropView: View {
    let url: URL?
    /// Follows `url` only once focus rests briefly, so scrolling a grid loads no images.
    @State private var shown: URL?

    var body: some View {
        ZStack {
            Color.black
            RemoteImage(url: shown)
                .id(shown)
                .transition(.opacity)
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.75), .black.opacity(0.95)],
                           startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.35), value: shown)
        .ignoresSafeArea()
        .task(id: url) {
            if shown == nil { shown = url; return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            shown = url
        }
    }
}

// MARK: - Focus styles

/// Lifts the focused card and reports focus so the backdrop can follow it.
struct FocusCardStyle: ButtonStyle {
    var onFocus: (@MainActor (Bool) -> Void)?

    func makeBody(configuration: Configuration) -> some View {
        FocusCardBody(configuration: configuration, onFocus: onFocus)
    }

    private struct FocusCardBody: View {
        let configuration: ButtonStyleConfiguration
        let onFocus: (@MainActor (Bool) -> Void)?
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.1 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.7 : 0), radius: isFocused ? 28 : 0, y: isFocused ? 18 : 0)
                .brightness(isFocused ? 0.04 : 0)
                .animation(.easeOut(duration: 0.18), value: isFocused)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .onChange(of: isFocused) { _, focused in onFocus?(focused) }
        }
    }
}

/// Capsule chip (season picker). The selected chip is white; focus lifts it.
struct ChipButtonStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, isSelected: isSelected)
    }

    private struct ChipBody: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 34)
                .padding(.vertical, 14)
                .foregroundStyle(isSelected ? Color.black : Color.white)
                .background(
                    Capsule().fill(isSelected ? Color.white : Color.white.opacity(isFocused ? 0.32 : 0.12))
                )
                .scaleEffect(configuration.isPressed ? 0.95 : (isFocused ? 1.1 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 14, y: 8)
                .animation(.easeOut(duration: 0.15), value: isFocused)
                .animation(.easeOut(duration: 0.2), value: isSelected)
        }
    }
}

// MARK: - Badges

struct Badge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.7), lineWidth: 1.5))
            .foregroundStyle(.white.opacity(0.9))
    }
}

// MARK: - Misc

struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        }
    }

    static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Every title opens the same Apple TV–style details page
/// (seasons and episodes open their show, with that season / episode ready to play).
struct ItemRouter: View {
    let item: PlexItem
    let client: PlexServerClient

    var body: some View {
        DetailPage(client: client, entry: item)
    }
}
