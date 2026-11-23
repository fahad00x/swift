import Foundation

/// Audio / subtitle choice for one file and one profile: the profile's own choice for that
/// item, else its preferred languages, else the file's defaults. Never stored on the server.
enum StreamPreference {
    struct Choice {
        var audio: PlexStream?
        /// nil = subtitles off.
        var subtitle: PlexStream?
    }

    static func resolve(for item: PlexItem, state: MediaState?, profile: UserProfile?) -> Choice {
        let audios = item.audioStreams
        let subtitles = item.subtitleStreams

        var audio = state?.audioStreamID.flatMap { id in audios.first { $0.id == id } }
        if audio == nil, let language = profile?.preferredAudioLanguage {
            audio = audios.first { sameLanguage($0.languageCode, language) }
        }
        if audio == nil { audio = audios.first(where: \.selected) ?? audios.first }

        if let id = state?.subtitleStreamID {
            return Choice(audio: audio, subtitle: id == 0 ? nil : subtitles.first { $0.id == id })
        }
        if let profile {
            if profile.subtitlesOff { return Choice(audio: audio, subtitle: nil) }
            if let language = profile.preferredSubtitleLanguage,
               let match = subtitles.first(where: { sameLanguage($0.languageCode, language) }) {
                return Choice(audio: audio, subtitle: match)
            }
        }
        return Choice(audio: audio, subtitle: subtitles.first(where: \.selected))
    }

    static func sameLanguage(_ a: String?, _ b: String?) -> Bool {
        guard let a = normalize(a), let b = normalize(b) else { return false }
        return a == b
    }

    /// Plex reports ISO 639-2 ("ara"), mpv may report ISO 639-1 ("ar") or 639-2/B ("fre").
    static func normalize(_ code: String?) -> String? {
        guard let code = code?.lowercased(), !code.isEmpty else { return nil }
        let map = ["ar": "ara", "en": "eng", "ja": "jpn", "fr": "fra", "fre": "fra", "de": "deu", "ger": "deu",
                   "es": "spa", "it": "ita", "ko": "kor", "zh": "zho", "chi": "zho", "tr": "tur", "hi": "hin",
                   "ru": "rus", "pt": "por", "nl": "nld", "dut": "nld", "fa": "fas", "per": "fas", "ur": "urd"]
        return map[code] ?? code
    }
}
