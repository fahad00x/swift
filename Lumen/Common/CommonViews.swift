import SwiftUI

// MARK: - Remote image

/// Decoded images already shown this session, readable synchronously so a view that appears
/// again (or a page opening on the same artwork) draws it on its first frame.
final class ImageMemo: @unchecked Sendable {
    static let shared = ImageMemo()
    let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 80
        return cache
    }()
}

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var loadedURL: URL?

    init(url: URL?, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
        let memo = url.flatMap { ImageMemo.shared.cache.object(forKey: $0 as NSURL) }
        _image = State(initialValue: memo)
        _loadedURL = State(initialValue: memo == nil ? nil : url)
    }

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
                guard let url else { image = nil; loadedURL = nil; return }
                if loadedURL == url, image != nil { return }
                if let memo = ImageMemo.shared.cache.object(forKey: url as NSURL) {
                    image = memo
                    loadedURL = url
                    return
                }
                let loaded = await ImageLoader.shared.image(for: url)
                if let loaded { ImageMemo.shared.cache.setObject(loaded, forKey: url as NSURL) }
                withAnimation(.easeOut(duration: 0.15)) { image = loaded }
                loadedURL = url
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
