import Foundation
import QuartzCore
import Libmpv

/// Works around MoltenVK briefly forcing a 1×1 drawable, which causes flicker.
/// https://github.com/mpv-player/mpv/pull/13651
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}

struct MPVTrack: Identifiable, Hashable {
    enum Kind: String { case video, audio, sub }

    let id: Int
    let kind: Kind
    let title: String?
    let language: String?
    let codec: String?
    let channels: Int?
    let isExternal: Bool
    let isSelected: Bool
    /// Stream index inside the container (Plex's stream `index`).
    let ffIndex: Int?
    /// The file marks it as the default track.
    var isDefault = false

    /// Player menus: «اليابانية – AAC 2.0 (افتراضي)» for audio; «العربية (Arabic) – Full – ASS»
    /// for subtitles (the track title tells apart several tracks of one language).
    var menuName: String {
        var parts: [String] = []
        if let language, !language.isEmpty {
            let arabic = Self.languageName(language)
            let english = Locale(identifier: "en").localizedString(forLanguageCode: language)
            parts.append(kind == .sub && english != nil && english != arabic ? "\(arabic) (\(english!))" : arabic)
        }
        if let title = title.flatMap(Self.readableTitle), !Self.repeatsLanguage(title, language) {
            parts.append(title)
        }
        switch kind {
        case .audio:
            var tech = codec.map { Self.audioCodecName($0) } ?? ""
            if let channels { tech += (tech.isEmpty ? "" : " ") + Self.channelLayout(channels) }
            if !tech.isEmpty { parts.append(tech) }
        case .sub:
            if let codec { parts.append(Self.subtitleFormat(codec)) }
            if isExternal { parts.append("ملف خارجي") }
        case .video:
            break
        }
        if parts.isEmpty { parts.append("مسار \(id)") }
        // Isolated pieces: Latin names and codecs keep their order inside the Arabic line.
        let line = parts.map { "\u{2068}\($0)\u{2069}" }.joined(separator: " – ")
        return isDefault && kind == .audio ? line + " (افتراضي)" : line
    }

    /// «Arabic», «Japanese [Original]»: the language again in English.
    private static func repeatsLanguage(_ title: String, _ language: String?) -> Bool {
        guard let language else { return false }
        let lower = title.lowercased()
        if lower == language.lowercased() { return true }
        let names = [Locale(identifier: "en").localizedString(forLanguageCode: language), languageName(language)]
        return names.compactMap { $0?.lowercased() }.contains { lower == $0 }
    }

    static func audioCodecName(_ codec: String) -> String {
        switch codec.lowercased() {
        case "eac3": return "E-AC3"
        case "truehd": return "TrueHD"
        case "dts": return "DTS"
        case "opus": return "Opus"
        case "flac": return "FLAC"
        case "vorbis": return "Vorbis"
        default: return codec.uppercased()
        }
    }

    /// 2 → «2.0», 6 → «5.1», 8 → «7.1».
    static func channelLayout(_ channels: Int) -> String {
        switch channels {
        case 1: return "1.0"
        case 2: return "2.0"
        case 3: return "2.1"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }

    /// «العربية • SRT • ملف خارجي», «الإنجليزية • AAC Stereo». Technical stream names
    /// (textstream_ara=1000…) and titles repeating the language are left out.
    var displayName: String {
        var parts: [String] = []
        let languageName = language.map(Self.languageName)
        if let languageName { parts.append(languageName) }
        if let title = title.flatMap(Self.readableTitle),
           title.lowercased() != language?.lowercased(), title != languageName {
            // «Arabic», «Chinese (China) [Original]»: the language again in English; keep only
            // what it adds (the original track).
            let english = language.flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0) }
            if let english, title.lowercased().hasPrefix(english.lowercased()) {
                if title.lowercased().contains("original") { parts.append("الأصلية") }
            } else {
                parts.append(title)
            }
        }
        var tech: [String] = []
        if let codec { tech.append(kind == .sub ? Self.subtitleFormat(codec) : codec.uppercased()) }
        if let channels {
            switch channels {
            case 8: tech.append("7.1")
            case 6: tech.append("5.1")
            case 2: tech.append("Stereo")
            case 1: tech.append("Mono")
            default: tech.append("\(channels)ch")
            }
        }
        if !tech.isEmpty { parts.append(tech.joined(separator: " ")) }
        if isExternal { parts.append("ملف خارجي") }
        if parts.isEmpty { parts.append("مسار \(id)") }
        return parts.joined(separator: ArabicFormat.separator)
    }

    /// A track title worth showing: nil for stream ids like «textstream_ara=1000»; common
    /// tags in Arabic.
    static func readableTitle(_ raw: String) -> String? {
        let title = raw.trimmingCharacters(in: .whitespaces)
        let lower = title.lowercased()
        guard !title.isEmpty, !title.contains("="), !lower.hasPrefix("textstream"),
              !lower.hasPrefix("track "), lower != "und" else { return nil }
        switch lower {
        case "forced": return "إجبارية"
        case "sdh", "cc": return "لضعاف السمع"
        case "full": return "كاملة"
        case "commentary": return "تعليق"
        default: return title
        }
    }

    /// Subtitle codec as people know it.
    static func subtitleFormat(_ codec: String) -> String {
        switch codec.lowercased() {
        case "subrip", "srt": return "SRT"
        case "ass", "ssa": return "ASS"
        case "hdmv_pgs_subtitle", "pgs", "pgssub": return "PGS"
        case "dvd_subtitle", "dvdsub", "vobsub": return "VobSub"
        case "webvtt", "vtt": return "WebVTT"
        case "mov_text", "tx3g": return "نص"
        default: return codec.uppercased()
        }
    }

    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}

/// Thin Swift wrapper around a libmpv handle rendering into a CAMetalLayer
/// (vo=gpu-next, Vulkan via MoltenVK, VideoToolbox hardware decoding).
final class MPVPlayer {
    enum Event {
        case property(name: String, value: Any?)
        case fileLoaded
        case endFile(reachedEOF: Bool, error: String?)
    }

    struct Configuration {
        var hdr = false
        var fastProfile = false
        var subtitleSize = 44
        var subtitleLook = SubtitleLook.original
        var preferredLanguages = ["ara", "ar", "eng", "en"]
    }

    /// Called on the main queue.
    var onEvent: ((Event) -> Void)?

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "lumen.mpv.events", qos: .userInitiated)
    private var retainedSelf: Unmanaged<MPVPlayer>?

    static let observed: [(String, mpv_format)] = [
        ("time-pos", MPV_FORMAT_DOUBLE),
        ("duration", MPV_FORMAT_DOUBLE),
        ("pause", MPV_FORMAT_FLAG),
        ("paused-for-cache", MPV_FORMAT_FLAG),
        ("track-list/count", MPV_FORMAT_INT64),
        ("aid", MPV_FORMAT_INT64),
        ("sid", MPV_FORMAT_INT64),
    ]

    init?(layer: CAMetalLayer, configuration: Configuration) {
        guard let mpv = mpv_create() else { return nil }
        handle = mpv

        var layerRef = layer
        mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &layerRef)

        #if DEBUG
        mpv_request_log_messages(mpv, "warn")
        #else
        mpv_request_log_messages(mpv, "no")
        #endif

        var options: [(String, String)] = [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"),
            ("video-rotate", "no"),
            ("idle", "yes"),
            // Generous network cache for high bitrate 4K remuxes.
            ("cache", "yes"),
            ("demuxer-max-bytes", "400MiB"),
            ("demuxer-max-back-bytes", "100MiB"),
            ("demuxer-readahead-secs", "60"),
            ("network-timeout", "30"),
            ("user-agent", "\(PlexClientInfo.product)/\(PlexClientInfo.version) (\(PlexClientInfo.platform))"),
            // Tracks & subtitles.
            ("alang", configuration.preferredLanguages.joined(separator: ",")),
            ("slang", configuration.preferredLanguages.joined(separator: ",")),
            ("subs-match-os-language", "yes"),
            ("subs-fallback", "yes"),
            ("sub-auto", "no"),
            // Text subtitles (SRT…): white, bold, dark outline. Styled ASS keeps its own look:
            // `scale` only resizes it with the video, never replaces its fonts or colours
            // (unless the profile asked for one look, see `assOverride`).
            ("sub-font-size", "\(configuration.subtitleSize)"),
            ("sub-bold", "yes"),
            ("sub-color", "#FFFFFFFF"),
            ("sub-border-color", "#CC000000"),
            ("sub-border-size", "1.6"),
            ("sub-shadow-color", "#80000000"),
            ("sub-shadow-offset", "2"),
            ("sub-ass-override", Self.assOverride(configuration.subtitleLook)),
            ("sub-margin-y", "60"),
            ("audio-channels", "auto-safe"),
            // On iOS / tvOS this only means a non-mixable audio session: by default mpv sets
            // MixWithOthers, and the system then never treats the app as Now Playing.
            ("audio-exclusive", "yes"),
            ("tone-mapping", "auto"),
        ]
        // HDR passthrough: must be set before initialisation.
        options.append(("target-colorspace-hint", configuration.hdr ? "yes" : "no"))
        if configuration.fastProfile { options.append(("profile", "fast")) }

        for (key, value) in options { mpv_set_option_string(mpv, key, value) }

        guard mpv_initialize(mpv) >= 0 else {
            mpv_terminate_destroy(mpv)
            handle = nil
            return nil
        }

        for (name, format) in Self.observed { mpv_observe_property(mpv, 0, name, format) }

        let unmanaged = Unmanaged.passRetained(self)
        retainedSelf = unmanaged
        mpv_set_wakeup_callback(mpv, { ctx in
            guard let ctx else { return }
            Unmanaged<MPVPlayer>.fromOpaque(ctx).takeUnretainedValue().drainEvents()
        }, unmanaged.toOpaque())
    }

    deinit {
        if let handle { mpv_terminate_destroy(handle) }
    }

    // MARK: Control

    func load(_ url: URL, start seconds: Double = 0) {
        let opts = "start=\(max(0, Int(seconds)))"
        // loadfile <url> <flags> <index> <options>
        command("loadfile", url.absoluteString, "replace", "-1", opts)
    }

    func addSubtitle(_ url: URL, title: String?, language: String?, select: Bool = false) {
        command("sub-add", url.absoluteString, select ? "select" : "auto", title ?? "", language ?? "")
    }

    func seek(to seconds: Double) {
        command("seek", String(format: "%.3f", max(0, seconds)), "absolute+exact")
    }

    func seek(by seconds: Double) {
        command("seek", String(format: "%.3f", seconds), "relative+exact")
    }

    var isPaused: Bool {
        get { flag("pause") }
        set { setFlag("pause", newValue) }
    }

    /// mpv's own: `force` restyles what libass takes for dialogue (events with a position keep
    /// their style). Not `strip`: it misplaces Arabic punctuation.
    private static func assOverride(_ look: SubtitleLook) -> String {
        switch look {
        case .original: return "scale"
        case .dialogue: return "force"
        }
    }

    func setSubtitleLook(_ look: SubtitleLook) {
        setString("sub-ass-override", Self.assOverride(look))
    }

    /// Text subtitles move up while the controls show (and back down after).
    /// mpv sizes its picture to the layer only when its video output is set up. After the screen
    /// turns (iPad) it keeps drawing at the old size: choosing the video track again sets the
    /// output up at the new size (a blink of black).
    func refreshOutputSize() {
        guard let track = string("vid"), track != "no" else { return }
        setString("vid", "no")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.setString("vid", track)
        }
    }

    func setSubtitleLifted(_ lifted: Bool) { setString("sub-margin-y", lifted ? "210" : "60") }

    func selectAudio(_ id: Int) { setString("aid", "\(id)") }
    func selectSubtitle(_ id: Int?) { setString("sid", id.map(String.init) ?? "no") }

    var position: Double { double("time-pos") }
    var duration: Double { double("duration") }

    func tracks() -> [MPVTrack] {
        let count = int("track-list/count")
        guard count > 0 else { return [] }
        return (0..<count).compactMap { i in
            let p = "track-list/\(i)"
            guard let rawKind = string("\(p)/type"), let kind = MPVTrack.Kind(rawValue: rawKind) else { return nil }
            let channels = int("\(p)/demux-channel-count")
            return MPVTrack(id: int("\(p)/id"), kind: kind,
                            title: string("\(p)/title"), language: string("\(p)/lang"),
                            codec: string("\(p)/codec"), channels: channels > 0 ? channels : nil,
                            isExternal: flag("\(p)/external"), isSelected: flag("\(p)/selected"),
                            ffIndex: string("\(p)/ff-index").flatMap { Int($0) },
                            isDefault: flag("\(p)/default"))
        }
    }

    /// Chapters in the file, in ms: (title, start, end); the last one ends at the file's end.
    func chapters() -> [(title: String?, startMs: Int, endMs: Int)] {
        let count = int("chapter-list/count")
        guard count > 0 else { return [] }
        let starts = (0..<count).map { double("chapter-list/\($0)/time") }
        let total = duration
        return (0..<count).map { i in
            let end = i + 1 < count ? starts[i + 1] : (total > 0 ? total : starts[i])
            return (string("chapter-list/\(i)/title"), Int(starts[i] * 1000), Int(end * 1000))
        }
    }

    /// Tears the player down; safe to call more than once. mpv is destroyed in the background:
    /// `completion` runs on the main queue once it's really gone.
    func shutdown(completion: (@MainActor () -> Void)? = nil) {
        guard let mpv = handle else {
            if let completion { DispatchQueue.main.async { completion() } }
            return
        }
        onEvent = nil
        handle = nil
        queue.async { [retainedSelf] in
            mpv_set_wakeup_callback(mpv, nil, nil)
            mpv_terminate_destroy(mpv)
            retainedSelf?.release()
            if let completion { DispatchQueue.main.async { completion() } }
        }
        retainedSelf = nil
    }

    // MARK: Low-level helpers

    private func command(_ args: String...) {
        guard let handle else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { for ptr in cargs { if let ptr { free(UnsafeMutablePointer(mutating: ptr)) } } }
        mpv_command_async(handle, 0, &cargs)
    }

    private func setString(_ name: String, _ value: String) {
        guard let handle else { return }
        mpv_set_property_string(handle, name, value)
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let handle else { return }
        var v: Int32 = value ? 1 : 0
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &v)
    }

    private func flag(_ name: String) -> Bool {
        guard let handle else { return false }
        var v: Int32 = 0
        mpv_get_property(handle, name, MPV_FORMAT_FLAG, &v)
        return v != 0
    }

    private func double(_ name: String) -> Double {
        guard let handle else { return 0 }
        var v: Double = 0
        mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &v)
        return v
    }

    private func int(_ name: String) -> Int {
        guard let handle else { return 0 }
        var v: Int64 = 0
        mpv_get_property(handle, name, MPV_FORMAT_INT64, &v)
        return Int(v)
    }

    private func string(_ name: String) -> String? {
        guard let handle, let cstr = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(cstr) }
        return String(cString: cstr)
    }

    // MARK: Events

    private func drainEvents() {
        queue.async { [weak self] in
            guard let self else { return }
            while let mpv = self.handle, let event = mpv_wait_event(mpv, 0) {
                let id = event.pointee.event_id
                if id == MPV_EVENT_NONE { break }
                if let parsed = Self.parse(event.pointee) {
                    DispatchQueue.main.async { [weak self] in self?.onEvent?(parsed) }
                }
                if id == MPV_EVENT_SHUTDOWN { break }
            }
        }
    }

    private static func parse(_ event: mpv_event) -> Event? {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let raw = event.data else { return nil }
            let property = raw.assumingMemoryBound(to: mpv_event_property.self).pointee
            let name = String(cString: property.name)
            var value: Any?
            if let data = property.data {
                switch property.format {
                case MPV_FORMAT_DOUBLE: value = data.assumingMemoryBound(to: Double.self).pointee
                case MPV_FORMAT_FLAG: value = data.assumingMemoryBound(to: Int32.self).pointee != 0
                case MPV_FORMAT_INT64: value = Int(data.assumingMemoryBound(to: Int64.self).pointee)
                default: value = nil
                }
            }
            return .property(name: name, value: value)
        case MPV_EVENT_FILE_LOADED:
            return .fileLoaded
        case MPV_EVENT_END_FILE:
            guard let raw = event.data else { return nil }
            let end = raw.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            if end.reason == MPV_END_FILE_REASON_EOF { return .endFile(reachedEOF: true, error: nil) }
            if end.reason == MPV_END_FILE_REASON_ERROR {
                return .endFile(reachedEOF: false, error: String(cString: mpv_error_string(end.error)))
            }
            return nil
        default:
            return nil
        }
    }
}
