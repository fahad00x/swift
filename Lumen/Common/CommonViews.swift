import SwiftUI

// MARK: - Remote image

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: url) {
                guard let url else { image = nil; return }
                let loaded = await ImageLoader.shared.image(for: url)
                withAnimation(.easeOut(duration: 0.15)) { image = loaded }
            }
    }
}

struct ProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Color.accentColor).frame(width: geo.size.width * value)
            }
        }
        .frame(height: 6)
    }
}

struct LoadingView: View {
    var message: String = "جارٍ التحميل…"
    var body: some View {
        VStack(spacing: 30) {
            ProgressView()
            Text(message).font(.headline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
