import Foundation

/// The player's quality menu: the file as it is, or a Plex transcode capped at a bitrate.
enum PlaybackQuality: String, CaseIterable, Identifiable, Hashable {
    case original
    case kbps8000, kbps6000
    case kbps4000, kbps3000, kbps2000
    case kbps1500, kbps750
    case kbps400

    var id: String { rawValue }

    /// nil: the original file (no transcoding).
    var maxBitrateKbps: Int? {
        switch self {
        case .original: return nil
        case .kbps8000: return 8000
        case .kbps6000: return 6000
        case .kbps4000: return 4000
        case .kbps3000: return 3000
        case .kbps2000: return 2000
        case .kbps1500: return 1500
        case .kbps750: return 750
        case .kbps400: return 400
        }
    }

    /// Plex `videoResolution` for the transcode.
    var resolution: String? {
        switch self {
        case .original: return nil
        case .kbps8000, .kbps6000: return "1920x1080"
        case .kbps4000, .kbps3000, .kbps2000: return "1280x720"
        case .kbps1500, .kbps750: return "854x480"
        case .kbps400: return "640x360"
        }
    }

    private var height: String {
        switch self {
        case .original: return ""
        case .kbps8000, .kbps6000: return "1080p"
        case .kbps4000, .kbps3000, .kbps2000: return "720p"
        case .kbps1500, .kbps750: return "480p"
        case .kbps400: return "360p"
        }
    }

    /// «الأصلي», «1080p – 8 Mbps», «480p – 0.75 Mbps».
    var title: String {
        guard let kbps = maxBitrateKbps else { return "الأصلي" }
        return ArabicFormat.isolated("\(height) – " + ArabicFormat.bitrate(kbps: kbps))
    }
}
