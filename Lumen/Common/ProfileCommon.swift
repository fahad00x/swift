import SwiftUI

// Profile pieces shared by the Apple TV and iPhone apps.

enum ProfileStyle {
    static let colors: [String] = [
        "#F5A524", "#E5484D", "#D6409F", "#8E4EC6", "#3E63DD",
        "#0091FF", "#12A594", "#30A46C", "#F76B15", "#6E6E73",
    ]

    static let symbols: [String] = [
        "person.fill", "face.smiling.fill", "star.fill", "heart.fill", "bolt.fill",
        "flame.fill", "leaf.fill", "moon.stars.fill", "sun.max.fill", "cloud.fill",
        "pawprint.fill", "hare.fill", "tortoise.fill", "fish.fill", "bird.fill",
        "ladybug.fill", "gamecontroller.fill", "music.note", "film.fill", "tv.fill",
        "car.fill", "airplane", "crown.fill", "sparkles", "theatermasks.fill",
        "popcorn.fill", "graduationcap.fill", "book.fill", "paintpalette.fill", "globe.americas.fill",
    ]
}

extension Color {
    /// "#RRGGBB"
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(digits, radix: 16) ?? 0xF5A524
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

/// Coloured circle with the profile's symbol.
struct ProfileAvatar: View {
    let symbol: String
    let colorHex: String
    var size: CGFloat = 220

    init(symbol: String, colorHex: String, size: CGFloat = 220) {
        self.symbol = symbol
        self.colorHex = colorHex
        self.size = size
    }

    init(profile: UserProfile, size: CGFloat = 220) {
        self.init(symbol: profile.symbol, colorHex: profile.colorHex, size: size)
    }

    var body: some View {
        let color = Color(hex: colorHex)
        ZStack {
            Circle().fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.65)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: size * 0.03, y: size * 0.02)
        }
        .frame(width: size, height: size)
    }
}

/// A PIN check: any of `profiles`' PINs unlocks.
struct PinRequest: Identifiable {
    let id = UUID()
    let title: String
    var subtitle: String?
    let profiles: [UserProfile]
    let onSuccess: () -> Void
}

@MainActor
enum ProfileGate {
    /// PINs that unlock editing `target`: a kids profile needs the main profile's PIN; a profile
    /// with its own PIN accepts it (or the main PIN). Empty = no PIN needed.
    static func editors(for target: UserProfile, store: ProfileStore) -> [UserProfile] {
        let owner = store.owner.flatMap { $0.hasPIN ? $0 : nil }
        if target.isKids { return [owner].compactMap { $0 } }
        var list = target.hasPIN ? [target] : []
        if let owner, owner.id != target.id, target.hasPIN { list.append(owner) }
        return list
    }
}

// MARK: - «مين يشاهد؟» pieces (system user picker look), shared by both apps

/// Profile circle: initials (up to 2 letters) on a soft, muted gradient of the profile colour,
/// with a small lock badge when it has a PIN.
struct ProfileInitialsCircle: View {
    let profile: UserProfile
    var size: CGFloat = 170

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace }).prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "؟" : letters
    }

    var body: some View {
        let color = Color(hex: profile.colorHex)
        ZStack {
            Circle().fill(Color(white: 0.32))
            Circle().fill(LinearGradient(colors: [color.opacity(0.55), color.opacity(0.3)],
                                         startPoint: .top, endPoint: .bottom))
            Circle().fill(LinearGradient(colors: [.white.opacity(0.12), .clear], startPoint: .top, endPoint: .center))
            Text(Self.initials(profile.name))
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if profile.hasPIN {
                Image(systemName: "lock.fill")
                    .font(.system(size: size * 0.11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.26, height: size * 0.26)
                    .background(Circle().fill(.ultraThinMaterial))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                    .offset(x: -size * 0.02, y: -size * 0.02)
            }
        }
    }
}

/// Full-screen, heavily blurred artwork with a slight darkening; black until it loads.
struct ProfilePickerBackdrop: View {
    let client: PlexServerClient?
    let sections: [PlexDirectory]
    @State private var url: URL?

    var body: some View {
        ZStack {
            Color.black
            RemoteImage(url: url)
                .blur(radius: 60, opaque: true)
                .scaleEffect(1.15)
            Color.black.opacity(0.35)
        }
        .ignoresSafeArea()
        .task {
            // The newest title of the first library with artwork.
            guard let client else { return }
            for section in sections {
                let items = (try? await client.recentlyAdded(section: section, limit: 6)) ?? []
                if let art = items.compactMap(\.backdropPath).first {
                    withAnimation(.easeIn(duration: 0.4)) { url = client.imageURL(art, width: 640, height: 360) }
                    return
                }
            }
        }
    }
}
