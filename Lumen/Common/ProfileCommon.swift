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
