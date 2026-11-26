// SPIKE (branch claude/dolby-spike only, never merged): can Lumen rewrap a Dolby Vision /
// Atmos MKV into MP4 on the Apple TV, without re-encoding, so Apple's player shows real
// Dolby Vision and passes Atmos? Finds test movies on the server, rewraps a one-minute clip
// with the FFmpeg inside MPVKit, reports what the file contains, and plays it with AVPlayer.

import AVFoundation
import AVKit
import SwiftUI
import Libavformat
import Libavcodec
import Libavutil

// MARK: - Candidates

struct DolbySpikeCandidate: Identifiable, Hashable {
    let id: String
    let title: String
    let partKey: String
    let dvProfile: Int?
    let audioIndex: Int32
    let audioLabel: String
    let kind: String
}

enum DolbySpikeFinder {
    private static func get(_ client: PlexServerClient, _ path: String, _ q: [(String, String)] = []) async throws -> [String: Any] {
        guard let url = client.url(path, q) else { throw URLError(.badURL) }
        var req = PlexHTTP.request(url, token: client.token)
        req.timeoutInterval = 60
        let data = try await PlexHTTP.data(for: req)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["MediaContainer"] as? [String: Any] ?? [:]
    }

    private static func str(_ v: Any?) -> String? { v as? String ?? (v as? Int).map(String.init) }
    private static func int(_ v: Any?) -> Int? { v as? Int ?? (v as? String).flatMap(Int.init) }

    /// Up to one movie per kind: DV 8 + EAC3 Atmos, DV 5, HDR10 + EAC3 Atmos.
    static func find(_ client: PlexServerClient, log: @escaping @MainActor (String) -> Void) async -> [DolbySpikeCandidate] {
        var found: [String: DolbySpikeCandidate] = [:]
        let wanted = ["DV8+Atmos", "DV5", "Atmos"]
        do {
            let sections = try await get(client, "/library/sections")["Directory"] as? [[String: Any]] ?? []
            var keys: [String] = []
            for s in sections where (s["type"] as? String) == "movie" {
                guard let key = str(s["key"]) else { continue }
                let items = try await get(client, "/library/sections/\(key)/all",
                                          [("type", "1"), ("resolution", "4k"),
                                           ("X-Plex-Container-Start", "0"), ("X-Plex-Container-Size", "150")])["Metadata"] as? [[String: Any]] ?? []
                keys += items.compactMap { str($0["ratingKey"]) }
            }
            await log("أفلام 4K للبحث: \(keys.count)")
            var checked = 0
            for start in stride(from: 0, to: min(keys.count, 400), by: 10) {
                if wanted.allSatisfy({ found[$0] != nil }) { break }
                let chunk = keys[start..<min(start + 10, keys.count)]
                let meta = (try? await get(client, "/library/metadata/" + chunk.joined(separator: ","))["Metadata"] as? [[String: Any]]) ?? []
                checked += chunk.count
                for m in meta {
                    guard let rk = str(m["ratingKey"]), let title = m["title"] as? String else { continue }
                    let media = (m["Media"] as? [[String: Any]])?.first ?? [:]
                    let part = (media["Part"] as? [[String: Any]])?.first ?? [:]
                    guard let partKey = part["key"] as? String,
                          ((media["container"] as? String) ?? "") == "mkv" else { continue }
                    let streams = part["Stream"] as? [[String: Any]] ?? []
                    let video = streams.first { int($0["streamType"]) == 1 } ?? [:]
                    let audios = streams.filter { int($0["streamType"]) == 2 }
                    func text(_ a: [String: Any]) -> String {
                        ["displayTitle", "extendedDisplayTitle", "title"].compactMap { a[$0] as? String }.joined(separator: " ")
                    }
                    let atmos = audios.first { ($0["codec"] as? String) == "eac3" && text($0).lowercased().contains("atmos") }
                    let dolby = atmos ?? audios.first { ["eac3", "ac3"].contains(($0["codec"] as? String) ?? "") }
                    let dv = (video["DOVIPresent"] as? Bool) ?? (int(video["DOVIPresent"]) == 1)
                    let profile = int(video["DOVIProfile"])
                    func make(_ kind: String, _ a: [String: Any]) -> DolbySpikeCandidate? {
                        guard let idx = int(a["index"]) else { return nil }
                        return DolbySpikeCandidate(id: kind + rk, title: title, partKey: partKey, dvProfile: dv ? profile : nil,
                                                   audioIndex: Int32(idx), audioLabel: text(a), kind: kind)
                    }
                    if found["DV8+Atmos"] == nil, dv, profile == 8, let atmos { found["DV8+Atmos"] = make("DV8+Atmos", atmos) }
                    if found["DV5"] == nil, dv, profile == 5, let dolby { found["DV5"] = make("DV5", dolby) }
                    if found["Atmos"] == nil, !dv, let atmos { found["Atmos"] = make("Atmos", atmos) }
                }
            }
            await log("فحصت \(checked) فيلم")
        } catch {
            await log("خطأ في البحث: \(error.localizedDescription)")
        }
        return wanted.compactMap { found[$0] }
    }
}

// MARK: - Remux (FFmpeg, stream copy)

final class DolbySpikeRemuxer: @unchecked Sendable {
    private(set) var lines: [String] = []
    private func note(_ s: String) { lines.append(s) }

    private static func fourcc(_ s: String) -> UInt32 {
        let b = Array(s.utf8)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    private static func err(_ code: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buf, 256)
        return String(cString: buf)
    }

    private func dovi(_ par: UnsafeMutablePointer<AVCodecParameters>) -> String {
        guard let sd = av_packet_side_data_get(par.pointee.coded_side_data, par.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF),
              let raw = sd.pointee.data else { return "لا يوجد" }
        let c = UnsafeRawPointer(raw).assumingMemoryBound(to: AVDOVIDecoderConfigurationRecord.self).pointee
        return "profile \(c.dv_profile) level \(c.dv_level) rpu \(c.rpu_present_flag) el \(c.el_present_flag) bl \(c.bl_present_flag) compat \(c.dv_bl_signal_compatibility_id)"
    }

    /// Copies `seconds` of video + one audio stream from `start` into an MP4 at `output`.
    func run(input: String, output: String, start: Double, seconds: Double, videoTag: String,
             audioIndex: Int32, progress: @escaping @Sendable (Double) -> Void) -> Bool {
        var inCtx: UnsafeMutablePointer<AVFormatContext>?
        var opts: OpaquePointer?
        av_dict_set(&opts, "rw_timeout", "30000000", 0)
        av_dict_set(&opts, "reconnect", "1", 0)
        var r = avformat_open_input(&inCtx, input, nil, &opts)
        av_dict_free(&opts)
        guard r >= 0, let inCtx else { note("فتح الملف فشل: \(Self.err(r))"); return false }
        defer { var p: UnsafeMutablePointer<AVFormatContext>? = inCtx; avformat_close_input(&p) }
        r = avformat_find_stream_info(inCtx, nil)
        if r < 0 { note("قراءة المسارات فشلت: \(Self.err(r))") }

        let videoIndex = av_find_best_stream(inCtx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard videoIndex >= 0, audioIndex >= 0, audioIndex < Int32(inCtx.pointee.nb_streams) else {
            note("ما لقيت الفيديو أو الصوت (video \(videoIndex), audio \(audioIndex))"); return false
        }
        let inVideo = inCtx.pointee.streams[Int(videoIndex)]!
        let inAudio = inCtx.pointee.streams[Int(audioIndex)]!
        note("المصدر: Dolby Vision = \(dovi(inVideo.pointee.codecpar))")
        if let name = avcodec_get_name(inAudio.pointee.codecpar.pointee.codec_id) {
            note("الصوت المصدر: \(String(cString: name)) \(inAudio.pointee.codecpar.pointee.ch_layout.nb_channels)ch")
        }

        var outCtx: UnsafeMutablePointer<AVFormatContext>?
        r = avformat_alloc_output_context2(&outCtx, nil, "mp4", output)
        guard r >= 0, let outCtx else { note("إنشاء MP4 فشل: \(Self.err(r))"); return false }
        defer { if outCtx.pointee.pb != nil { avio_closep(&outCtx.pointee.pb) }; avformat_free_context(outCtx) }
        // FFmpeg writes the Dolby Vision box (dvcC/dvvC) into MP4 only with this.
        outCtx.pointee.strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL

        var map: [Int32: Int32] = [:]
        for (inIdx, tag) in [(videoIndex, videoTag), (audioIndex, "")] {
            let inStream = inCtx.pointee.streams[Int(inIdx)]!
            guard let os = avformat_new_stream(outCtx, nil) else { note("مسار جديد فشل"); return false }
            r = avcodec_parameters_copy(os.pointee.codecpar, inStream.pointee.codecpar)
            guard r >= 0 else { note("نسخ المسار فشل: \(Self.err(r))"); return false }
            os.pointee.codecpar.pointee.codec_tag = tag.isEmpty ? 0 : Self.fourcc(tag)
            os.pointee.time_base = inStream.pointee.time_base
            map[inIdx] = os.pointee.index
        }
        note("بعد النسخ: Dolby Vision = \(dovi(outCtx.pointee.streams[0]!.pointee.codecpar)) ، الوسم \(videoTag)")

        r = avio_open(&outCtx.pointee.pb, output, AVIO_FLAG_WRITE)
        guard r >= 0 else { note("فتح ملف الكتابة فشل: \(Self.err(r))"); return false }
        r = avformat_write_header(outCtx, nil)
        guard r >= 0 else { note("كتابة رأس MP4 فشلت: \(Self.err(r))"); return false }

        r = av_seek_frame(inCtx, -1, Int64(start * 1_000_000), Int32(AVSEEK_FLAG_BACKWARD))
        if r < 0 { note("القفز للدقيقة فشل، من البداية: \(Self.err(r))") }

        let noPTS = Int64.min
        let vtb = inVideo.pointee.time_base
        var startSeconds: Double?
        var lastSeconds = 0.0
        var packets = 0
        guard let pkt = av_packet_alloc() else { return false }
        defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }

        while av_read_frame(inCtx, pkt) >= 0 {
            let idx = pkt.pointee.stream_index
            guard let outIdx = map[idx] else { av_packet_unref(pkt); continue }
            let inTB = inCtx.pointee.streams[Int(idx)]!.pointee.time_base
            let ts = pkt.pointee.pts != noPTS ? pkt.pointee.pts : pkt.pointee.dts
            let tsSeconds = ts == noPTS ? lastSeconds : Double(ts) * av_q2d(inTB)
            if startSeconds == nil {
                // Start on a video keyframe; drop what comes before it.
                guard idx == videoIndex, (pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0 else { av_packet_unref(pkt); continue }
                startSeconds = tsSeconds
                note("بداية المقطع: \(Int(tsSeconds)) ث")
            }
            guard let startSeconds else { continue }
            if tsSeconds < startSeconds { av_packet_unref(pkt); continue }
            if idx == videoIndex {
                lastSeconds = tsSeconds
                if tsSeconds - startSeconds > seconds { av_packet_unref(pkt); break }
                progress((tsSeconds - startSeconds) / seconds)
            }
            let shift = Int64((startSeconds / av_q2d(inTB)).rounded())
            if pkt.pointee.pts != noPTS { pkt.pointee.pts -= shift }
            if pkt.pointee.dts != noPTS { pkt.pointee.dts -= shift }
            av_packet_rescale_ts(pkt, inTB, outCtx.pointee.streams[Int(outIdx)]!.pointee.time_base)
            pkt.pointee.stream_index = outIdx
            pkt.pointee.pos = -1
            r = av_interleaved_write_frame(outCtx, pkt)
            if r < 0 { note("كتابة فشلت: \(Self.err(r))"); return false }
            packets += 1
        }
        _ = vtb
        r = av_write_trailer(outCtx)
        guard r >= 0 else { note("إنهاء MP4 فشل: \(Self.err(r))"); return false }
        note("كُتبت \(packets) حزمة")
        return true
    }
}

// MARK: - Inspect the MP4 with AVFoundation

enum DolbySpikeInspector {
    static func fourcc(_ v: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(v)"
    }

    static func report(_ url: URL) async -> [String] {
        var out: [String] = []
        let asset = AVURLAsset(url: url)
        do {
            for track in try await asset.loadTracks(withMediaType: .video) {
                let descs = try await track.load(.formatDescriptions)
                for d in descs {
                    var line = "فيديو MP4: \(fourcc(CMFormatDescriptionGetMediaSubType(d)))"
                    if let atoms = CMFormatDescriptionGetExtension(d, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any] {
                        line += " — صناديق: " + atoms.keys.sorted().joined(separator: ", ")
                    }
                    out.append(line)
                }
                let hdr = try await track.load(.mediaCharacteristics).contains(.containsHDRVideo)
                out.append("أبل تشوف HDR في الملف: \(hdr ? "نعم" : "لا")")
            }
            for track in try await asset.loadTracks(withMediaType: .audio) {
                for d in try await track.load(.formatDescriptions) {
                    var line = "صوت MP4: \(fourcc(CMFormatDescriptionGetMediaSubType(d)))"
                    if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
                        line += " \(asbd.mChannelsPerFrame)ch"
                    }
                    out.append(line)
                }
            }
            let playable = try await asset.load(.isPlayable)
            out.append("أبل تقدر تشغّله: \(playable ? "نعم" : "لا")")
        } catch {
            out.append("فحص الملف فشل: \(error.localizedDescription)")
        }
        return out
    }

    @MainActor static func device() -> [String] {
        let modes = AVPlayer.availableHDRModes
        var names: [String] = []
        if modes.contains(.dolbyVision) { names.append("Dolby Vision") }
        if modes.contains(.hdr10) { names.append("HDR10") }
        if modes.contains(.hlg) { names.append("HLG") }
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue)" }.joined(separator: ", ")
        return [
            "الشاشة تدعم: \(names.isEmpty ? "ولا شي" : names.joined(separator: "، "))",
            "تشغيل HDR متاح: \(AVPlayer.eligibleForHDRPlayback ? "نعم" : "لا")",
            "مخرج الصوت: \(outputs) — أقصى قنوات: \(session.maximumOutputNumberOfChannels)",
        ]
    }
}

// MARK: - Screen

struct DolbySpikeView: View {
    let client: PlexServerClient
    @State private var log: [String] = []
    @State private var candidates: [DolbySpikeCandidate] = []
    @State private var busy = false
    @State private var progress = 0.0
    @State private var clip: URL?

    private static let clipSeconds = 60.0
    private static let clipStart = 600.0

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 24) {
                Text("تجربة Dolby (مؤقت)").font(.system(size: 44, weight: .bold))
                if busy { ProgressView(value: progress).frame(width: 600) }
                ForEach(candidates) { c in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(c.kind): \(c.title)").font(.headline)
                        Text(c.audioLabel).font(.caption).opacity(0.6)
                        HStack {
                            Button("أ: وسم hvc1") { make(c, tag: "hvc1") }
                            Button("ب: وسم dvh1") { make(c, tag: "dvh1") }
                        }
                        .disabled(busy)
                    }
                }
                if let clip, !busy {
                    Button("▶︎ شغّل المقطع بمشغّل أبل") { play(clip) }
                }
            }
            .frame(width: 760, alignment: .leading)
            .focusSection()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 24, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .focusable()
        }
        .padding(80)
        .task {
            guard candidates.isEmpty else { return }
            log += DolbySpikeInspector.device()
            busy = true
            log.append("أدور على أفلام للتجربة…")
            candidates = await DolbySpikeFinder.find(client) { log.append($0) }
            if candidates.isEmpty { log.append("ما لقيت أفلام مناسبة") }
            busy = false
        }
    }

    private func make(_ c: DolbySpikeCandidate, tag: String) {
        guard let input = client.directURL(partKey: c.partKey)?.absoluteString else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DolbySpike", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let output = dir.appendingPathComponent("clip-\(tag).mp4")
        busy = true
        progress = 0
        clip = nil
        log.append("— \(c.kind) «\(c.title)» بوسم \(tag)")
        Task {
            let remuxer = DolbySpikeRemuxer()
            let started = Date()
            let ok = await Task.detached(priority: .userInitiated) {
                remuxer.run(input: input, output: output.path, start: Self.clipStart, seconds: Self.clipSeconds,
                            videoTag: tag, audioIndex: c.audioIndex) { p in
                    Task { @MainActor in progress = p }
                }
            }.value
            log += remuxer.lines
            let secs = Int(Date().timeIntervalSince(started))
            let size = ((try? FileManager.default.attributesOfItem(atPath: output.path)[.size]) as? Int64) ?? 0
            log.append("الوقت: \(secs) ث — الحجم: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
            if ok {
                log += await DolbySpikeInspector.report(output)
                clip = output
            }
            busy = false
        }
    }

    private func play(_ url: URL) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setSupportsMultichannelContent(true)
        try? session.setActive(true)
        let vc = AVPlayerViewController()
        vc.player = AVPlayer(url: url)
        var top = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }?.rootViewController
        while let p = top?.presentedViewController { top = p }
        top?.present(vc, animated: true) { vc.player?.play() }
        log.append("تشغيل… شيّك على التلفزيون (شعار Dolby Vision) والريسيفر/السماعة (Atmos)")
    }
}
