import Foundation

/// Plex chapter (`includeChapters=1`), e.g. "Opening", "Intro", "Ending", "Credits".
struct PlexGuid: Decodable {
    let id: String
}

struct PlexChapter: Codable, Hashable {
    let tag: String?
    let startMs: Int
    let endMs: Int

    enum CodingKeys: String, CodingKey { case tag, startMs = "startTimeOffset", endMs = "endTimeOffset" }

    init(tag: String?, startMs: Int, endMs: Int) {
        self.tag = tag
        self.startMs = startMs
        self.endMs = endMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = c.lenientString(forKey: .tag)
        startMs = c.lenientInt(forKey: .startMs) ?? 0
        endMs = c.lenientInt(forKey: .endMs) ?? 0
    }
}

/// A part of an episode that can be skipped.
struct SkipSegment: Hashable {
    enum Kind { case recap, intro, credits }
    enum Source { case plexMarker, online, chapter }

    let kind: Kind
    let startMs: Int
    let endMs: Int
    let source: Source

    var startSeconds: Double { Double(startMs) / 1000 }
    var endSeconds: Double { Double(endMs) / 1000 }
}

/// Finds intro / recap / credits from Plex's markers first (its intro & credits detection),
/// then from chapter names in the file ("Opening", "OP", "Intro", "Ending", "Credits"…),
/// which is how many releases (anime especially) mark them even when Plex detected nothing.
enum SkipSegmentFinder {
    static func kind(forChapter title: String?) -> SkipSegment.Kind? {
        guard let raw = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
        let words = Set(raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        func has(_ any: [String]) -> Bool { any.contains { raw.contains($0) } }

        if has(["recap", "previously", "ملخص", "سابقا", "سابقاً"]) { return .recap }
        if has(["opening credits", "intro", "opening", "theme song", "مقدمة", "المقدمة", "شارة البداية"])
            || words.contains("op") || words.contains(where: { $0.hasPrefix("op") && $0.dropFirst(2).allSatisfy(\.isNumber) && $0.count <= 4 }) {
            return .intro
        }
        if has(["credits", "ending", "outro", "end card", "preview", "next episode", "شارة النهاية", "الختام", "النهاية"])
            || words.contains("ed") || words.contains(where: { $0.hasPrefix("ed") && $0.dropFirst(2).allSatisfy(\.isNumber) && $0.count <= 4 }) {
            return .credits
        }
        return nil
    }

    /// Chapters as (title, start, end) in ms → segments, with sanity checks on length / position.
    static func segments(fromChapters chapters: [(title: String?, startMs: Int, endMs: Int)], durationMs: Int) -> [SkipSegment] {
        var out: [SkipSegment] = []
        for chapter in chapters {
            guard let kind = kind(forChapter: chapter.title), chapter.endMs > chapter.startMs else { continue }
            let length = chapter.endMs - chapter.startMs
            switch kind {
            case .intro, .recap:
                // 10 s – 4 min, in the first half of the episode.
                guard length >= 10_000, length <= 240_000,
                      durationMs <= 0 || chapter.startMs < durationMs / 2 else { continue }
            case .credits:
                // In the second half.
                guard durationMs <= 0 || chapter.startMs > durationMs / 2 else { continue }
            }
            // Keep the first one of each kind (and the earliest credits start).
            if !out.contains(where: { $0.kind == kind }) {
                out.append(SkipSegment(kind: kind, startMs: chapter.startMs, endMs: chapter.endMs, source: .chapter))
            }
        }
        return out
    }

    /// Plex markers win; chapters fill in whatever kind is missing.
    static func merge(_ primary: [SkipSegment], _ fallback: [SkipSegment]) -> [SkipSegment] {
        var result = primary
        for segment in fallback where !result.contains(where: { $0.kind == segment.kind }) {
            result.append(segment)
        }
        return result.sorted { $0.startMs < $1.startMs }
    }
}

extension PlexItem {
    /// "imdb" → "tt0944947" from the item's guids.
    func externalID(_ scheme: String) -> String? {
        let prefix = scheme + "://"
        return guids.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    /// Intro / recap / credits from Plex markers, else from the chapters Plex read from the file.
    var skipSegments: [SkipSegment] { SkipSegmentFinder.merge(markerSegments, plexChapterSegments) }

    var plexChapterSegments: [SkipSegment] {
        SkipSegmentFinder.segments(fromChapters: chapters.map { ($0.tag, $0.startMs, $0.endMs) }, durationMs: duration ?? 0)
    }

    var markerSegments: [SkipSegment] {
        var markers: [SkipSegment] = []
        if let intro = introMarker {
            markers.append(SkipSegment(kind: .intro, startMs: intro.startMs, endMs: intro.endMs, source: .plexMarker))
        }
        if let credits = creditsMarker, credits.endMs > credits.startMs {
            markers.append(SkipSegment(kind: .credits, startMs: credits.startMs, endMs: credits.endMs, source: .plexMarker))
        }
        return markers
    }

    /// For the details page: where «تخطي المقدمة» comes from.
    var introSkipSourceText: String {
        switch skipSegments.first(where: { $0.kind == .intro })?.source {
        case .plexMarker?: return "تخطي المقدمة: من Plex"
        case .online?: return "تخطي المقدمة: من قاعدة بيانات المقدمات"
        case .chapter?: return "تخطي المقدمة: من فصول الملف"
        case nil: return "تخطي المقدمة: لا توجد علامات"
        }
    }
}
