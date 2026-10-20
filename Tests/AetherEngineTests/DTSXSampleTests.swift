// Only with the DTSXObjectAudio trait (off by default): the decoder is not built without it.
#if DTSXObjectAudio
import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// End to end on real DTS-HD elementary streams: verdict, decode, render, encode. The samples are
/// not in the repository, so each test runs only when its variable names a `.dts` file:
/// `AE_DTSX_SAMPLE` the "DTS:X Object Emulator" demo (standard 7.1.4, 95 s),
/// `AE_DTSX_ALTERNATE_SAMPLE` Trinnov's "Experience" trailer (7.1.4 plus five moving objects, 44 s,
/// refused),
/// `AE_DTS_HD_MA_SAMPLE` a DTS-HD Master Audio stream without DTS:X (FFmpeg's FATE
/// `dts/master_audio_7.1_24bit.dts`). LibDTSX's README (the decoder these replaced) says where to
/// get them.
@Suite("DTS:X samples, decode to APAC")
struct DTSXSampleTests {

    private static func sample(_ variable: String) -> Data? {
        ProcessInfo.processInfo.environment[variable].flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
    }

    /// Frames the decoder hands out for the whole stream, the held last one included.
    private static func decodedFrames(_ data: Data) throws -> Int {
        let decoder = try DTSXObjectAudioDecoder()
        var frames = 0
        try data.withUnsafeBytes { try decoder.push($0) }
        decoder.releaseHeldBlocks()
        while let block = try decoder.nextBlock() { frames += block.frameCount }
        return frames
    }

    /// The verdict on the head of a stream, fed in 4096-byte pieces as packets would arrive.
    private static func verdict(_ data: Data) throws -> DTSXObjectAudioDecoder.Verdict? {
        let decoder = try DTSXObjectAudioDecoder()
        return data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = min(4096, raw.count - offset)
                if let verdict = decoder.verdict(feeding: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + n])) {
                    return verdict
                }
                offset += n
            }
            return nil
        }
    }

    @Test("DTS:X is recognised on its head; objects and plain DTS-HD MA are refused")
    func verdicts() throws {
        if let data = Self.sample("AE_DTSX_SAMPLE") {
            #expect(try Self.verdict(data.prefix(1 << 20)) == .renders("7.1.4"))
        }
        if let data = Self.sample("AE_DTSX_ALTERNATE_SAMPLE") {
            let verdict = try Self.verdict(data.prefix(1 << 20))
            // FFmpeg does not recognise this trailer's extension at all, so it decodes as the 7.1 bed.
            guard case .refused = verdict else {
                Issue.record("the alternate presentation was not refused: \(String(describing: verdict))")
                return
            }
        }
        if let data = Self.sample("AE_DTS_HD_MA_SAMPLE") {
            let verdict = try Self.verdict(data.prefix(1 << 20))
            guard case .refused(let reason) = verdict else {
                Issue.record("plain DTS-HD MA was not refused: \(String(describing: verdict))")
                return
            }
            #expect(reason.contains("no DTS:X extension"), "\(reason)")
        }
    }

    @Test("the standard presentation plays each channel on its own speaker, the heights overhead")
    func standardPresentationOnItsSpeakers() throws {
        guard let data = Self.sample("AE_DTSX_SAMPLE") else { return }
        let decoder = try DTSXObjectAudioDecoder()
        let layout = SpatialSpeakerLayout.l714
        var renderer: ObjectAudioRenderer?
        let out = (0..<layout.channelCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 4096) }
        defer { out.forEach { $0.deallocate() } }
        var energy = [Double](repeating: 0, count: layout.channelCount)
        var frames = 0, firstInputFrame: Int64 = -1
        var roles: [ObjectAudioRole] = []
        var misplaced = 0

        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = min(4096, raw.count - offset)
                try decoder.push(UnsafeRawBufferPointer(rebasing: raw[offset..<offset + n]))
                offset += n
                while let block = try decoder.nextBlock() {
                    if renderer == nil {
                        renderer = ObjectAudioRenderer(layout: layout, roles: block.roles)
                        roles = block.roles
                        firstInputFrame = block.inputFrameOffset
                    }
                    renderer!.render(inputs: block.planes, frameCount: block.frameCount,
                                     updates: block.updates, outputs: out)
                    // Every bed and height channel routes discretely: each output channel is exactly
                    // the decoded channel for its speaker.
                    for (input, role) in block.roles.enumerated() {
                        let speaker: SpatialSpeaker
                        switch role {
                        case .bed(let s): speaker = s
                        case .lfe: speaker = .lfe
                        default: continue
                        }
                        let c = layout.speakers.firstIndex(of: speaker)!
                        for i in 0..<block.frameCount where out[c][i] != block.planes[input][i] { misplaced += 1 }
                    }
                    for c in 0..<layout.channelCount {
                        for i in 0..<block.frameCount { energy[c] += Double(out[c][i] * out[c][i]) }
                    }
                    frames += block.frameCount
                }
            }
        }
        // The last frame is held until something follows it; at the end of input it is released.
        decoder.releaseHeldBlocks()
        while let block = try decoder.nextBlock() { frames += block.frameCount }
        let rms = energy.map { ($0 / Double(max(frames, 1))).squareRoot() }
        print("[DTSXSample] frames=\(frames) roles=\(roles)")
        print("[DTSXSample] 7.1.4 rms dBFS: " + zip(layout.speakers, rms).map {
            "\($0.0.rawValue)=\(String(format: "%.1f", 20 * log10(max($0.1, 1e-9))))" }.joined(separator: " "))

        // Whole frames of 512, the first two of which only prime the decoder (8,902 frames in the
        // Object Emulator sample, so 4,556,800 here).
        #expect(firstInputFrame == 1024)
        #expect(frames > 0 && frames % 512 == 0)
        #expect(frames == (try Self.decodedFrames(data)))
        #expect(roles == [.bed(.center), .bed(.left), .bed(.right), .bed(.sideLeft), .bed(.sideRight), .lfe,
                          .bed(.rearLeft), .bed(.rearRight), .bed(.topFrontLeft), .bed(.topFrontRight),
                          .bed(.topRearLeft), .bed(.topRearRight)])
        #expect(misplaced == 0)
        for (c, speaker) in layout.speakers.enumerated() where speaker.isHeight {
            #expect(rms[c] > 1e-3, "\(speaker.rawValue) carries its height channel")
        }
    }

    @Test("the bridge turns the whole standard sample into contiguous APAC packets")
    func bridgesToAPAC() throws {
        guard let data = Self.sample("AE_DTSX_SAMPLE") else { return }
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 48_000), layout: .l714, decoder: DTSXObjectAudioDecoder())
        defer { bridge.close() }
        var pts: [Int64] = []
        var bytes = 0
        let start = Date()
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = min(3000, raw.count - offset)
                let pkt = av_packet_alloc()!
                defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
                _ = av_new_packet(pkt, Int32(n))
                pkt.pointee.data.update(from: raw.baseAddress!.assumingMemoryBound(to: UInt8.self) + offset, count: n)
                pkt.pointee.pts = offset == 0 ? 0 : Int64.min
                for fp in try bridge.feed(packet: pkt) {
                    pts.append(fp.pointee.pts); bytes += Int(fp.pointee.size)
                    var p: UnsafeMutablePointer<AVPacket>? = fp; trackedPacketFree(&p)
                }
                offset += n
            }
        }
        for fp in bridge.flush() {
            pts.append(fp.pointee.pts); bytes += Int(fp.pointee.size)
            var p: UnsafeMutablePointer<AVPacket>? = fp; trackedPacketFree(&p)
        }
        let elapsed = Date().timeIntervalSince(start)
        let seconds = Double(pts.count * 1024) / 48_000
        print("[DTSXSample] 7.1.4 APAC: \(pts.count) packets, \(String(format: "%.2f", seconds)) s, "
              + "\(bytes * 8 / Int(seconds) / 1000) kbps, \(String(format: "%.1f", seconds / elapsed))x realtime (debug build)")
        // The first block sits after the two priming frames, so the encoder starts 1024 frames in.
        #expect(pts.first == Int64(1024))
        #expect(zip(pts, pts.dropFirst()).allSatisfy { $1 - $0 == 1024 })
        // Two packets of encoder priming, then every frame after the priming frames.
        #expect(pts.count == 2 + Int((Double(try Self.decodedFrames(data)) / 1024).rounded(.up)))
    }
}
#endif
