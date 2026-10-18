import Testing
import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
}
private func fixtureExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: fixtureURL(name).path)
}

/// AE#783: a Matroska remux (Opus bridged to FLAC) declared `BANDWIDTH` as twice the container's
/// average, and AVPlayer refused a segment of the VBR ending with -12318 "Segment exceeds specified
/// bandwidth for variant". The keyframe index knows where every planned segment starts in the file,
/// so the peak it measures, plus the bridged track's ceiling, now raises the declaration.
@Suite("AE#783 peak-safe master BANDWIDTH")
struct Issue783PeakBandwidthTests {

    private static func plan(_ bounds: [(pts: Int64, seconds: Double)]) -> [HLSVideoEngine.Segment] {
        zip(bounds, bounds.dropFirst()).map { a, b in
            HLSVideoEngine.Segment(startPts: a.pts, endPts: b.pts, startSeconds: a.seconds,
                                   durationSeconds: b.seconds - a.seconds)
        }
    }

    @Test("the peak is the densest measured segment, the final one unmeasured")
    func peakIsDensestSegment() {
        let plan = Self.plan([(0, 0), (4000, 4), (8000, 8), (12000, 12)])
        // 4 MB over 4 s, then 12 MB over 4 s; the last segment has no indexed end.
        let positions: [Int64: Int64] = [0: 1_000, 4000: 4_001_000, 8000: 16_001_000]
        #expect(HLSVideoEngine.peakSegmentBitrate(plan: plan, keyframeBytePositions: positions) == 24_000_000)
    }

    @Test("a boundary without a position, or one that does not rise, measures nothing")
    func unusablePositionsMeasureNothing() {
        let plan = Self.plan([(0, 0), (4000, 4), (8000, 8), (12000, 12)])
        #expect(HLSVideoEngine.peakSegmentBitrate(
            plan: plan, keyframeBytePositions: [0: 0, 8000: 9_000_000]) == nil)
        // Two IRAPs in one Matroska Cluster share its position.
        #expect(HLSVideoEngine.peakSegmentBitrate(
            plan: plan, keyframeBytePositions: [0: 0, 4000: 0, 8000: 9_000_000]) == nil)
        #expect(HLSVideoEngine.peakSegmentBitrate(
            plan: plan, keyframeBytePositions: [0: -1, 4000: 10, 8000: 20]) == nil)
        #expect(HLSVideoEngine.peakSegmentBitrate(plan: Self.plan([(0, 0), (4000, 4)]),
                                                  keyframeBytePositions: [0: 0, 4000: 100]) == nil)
    }

    @Test("the reporter's session: a 3.46 s ending segment above twice the 9.15 Mb/s average")
    func reporterSessionDeclaresTheMeasuredPeak() {
        let average = 9_148_953
        #expect(VideoSegmentProvider.declaredPeakBandwidth(
            averageBandwidth: average, sourcePeakBitrate: nil, bridgedAudioPeakBitrate: 0) == 18_297_906)
        // A 21 Mb/s segment, and a stereo FLAC bridge from Opus (S16, 48 kHz).
        let flac = AudioBridge.peakBitRate(bitRate: 0, channels: 2, sampleRate: 48_000, bitsPerRawSample: 16)
        #expect(flac == 1_536_000)
        let declared = VideoSegmentProvider.declaredPeakBandwidth(
            averageBandwidth: average, sourcePeakBitrate: 21_000_000, bridgedAudioPeakBitrate: flac)
        #expect(declared == 21_000_000 * 12 / 10 + 1_536_000)
    }

    @Test("a measured peak never lowers the declaration below twice the average")
    func measuredPeakNeverLowers() {
        #expect(VideoSegmentProvider.declaredPeakBandwidth(
            averageBandwidth: 10_000_000, sourcePeakBitrate: 12_000_000, bridgedAudioPeakBitrate: 0) == 20_000_000)
        #expect(VideoSegmentProvider.declaredPeakBandwidth(
            averageBandwidth: 1_000_000, sourcePeakBitrate: nil, bridgedAudioPeakBitrate: 9_000_000) == 5_000_000)
    }

    @Test("a measured peak past the ceiling is held at it, so AVPlayer can still pick the variant")
    func implausiblePeakIsClamped() {
        // An index position far down the file reads as a 2 Gb/s segment.
        #expect(VideoSegmentProvider.declaredPeakBandwidth(
            averageBandwidth: 9_000_000, sourcePeakBitrate: 2_000_000_000, bridgedAudioPeakBitrate: 0) == 40_000_000)
        #expect(VideoSegmentProvider.declaredPeakBandwidth(
            averageBandwidth: 30_000_000, sourcePeakBitrate: 500_000_000, bridgedAudioPeakBitrate: 0) == 120_000_000)
        #expect(VideoSegmentProvider.declaredPeakBandwidth(
            averageBandwidth: 60_000_000, sourcePeakBitrate: 500_000_000, bridgedAudioPeakBitrate: 0) == 160_000_000)
        // Twice an average above the ceiling's cap is still the floor.
        #expect(VideoSegmentProvider.declaredPeakBandwidth(
            averageBandwidth: 90_000_000, sourcePeakBitrate: 500_000_000, bridgedAudioPeakBitrate: 0) == 180_000_000)
    }

    @Test("an E-AC-3 bridge states its rate, a lossless FLAC one its PCM ceiling")
    func bridgeCeilings() {
        #expect(AudioBridge.peakBitRate(bitRate: 768_000, channels: 6, sampleRate: 48_000, bitsPerRawSample: 0)
                == 768_000)
        #expect(AudioBridge.peakBitRate(bitRate: 0, channels: 8, sampleRate: 48_000, bitsPerRawSample: 24)
                == 9_216_000)
        #expect(AudioBridge.peakBitRate(bitRate: 0, channels: 2, sampleRate: 48_000, bitsPerRawSample: 0)
                == 3_072_000)
    }

    /// The index-measured peak has to cover what each planned segment really carries. Read every
    /// packet of the file, sum the bytes per segment, and compare.
    @Test("on a real Matroska file the index peak covers every segment's packets",
          .enabled(if: fixtureExists("restart-witness-subs.mkv")))
    func indexPeakCoversPacketBytes() throws {
        let dem = Demuxer()
        try dem.open(url: fixtureURL("restart-witness-subs.mkv"))
        defer { dem.close() }
        let video = dem.videoStreamIndex
        _ = dem.seekBounded(to: dem.duration * 0.5, timeout: 2)
        let entries = dem.indexedKeyframeEntries(streamIndex: video)
        try #require(entries.count >= 3)
        guard let stream = dem.stream(at: video) else {
            Issue.record("no video stream"); return
        }
        let tb = stream.pointee.time_base
        let plan = HLSVideoEngine.buildKeyframeSegmentPlan(
            keyframes: entries.map(\.pts), videoTimeBase: tb, sourceDurationSeconds: dem.duration)
        let positions = Dictionary(entries.map { ($0.pts, $0.pos) }, uniquingKeysWith: { a, _ in a })
        let peak = try #require(HLSVideoEngine.peakSegmentBitrate(plan: plan, keyframeBytePositions: positions))

        _ = dem.seekBounded(to: 0, timeout: 2)
        var bytesPerSegment = [Int64](repeating: 0, count: plan.count)
        let videoTb = Double(tb.num) / Double(tb.den)
        while let pkt = try dem.readPacket() {
            var owned: UnsafeMutablePointer<AVPacket>? = pkt
            defer { av_packet_free(&owned) }
            guard let s = dem.stream(at: pkt.pointee.stream_index) else { continue }
            let ts = pkt.pointee.dts != Int64.min ? pkt.pointee.dts : pkt.pointee.pts
            guard ts != Int64.min else { continue }
            let seconds = Double(ts) * Double(s.pointee.time_base.num) / Double(s.pointee.time_base.den)
            let firstStart = Double(plan[0].startPts) * videoTb
            guard let idx = plan.lastIndex(where: { $0.startSeconds <= seconds - firstStart }) else { continue }
            bytesPerSegment[idx] += Int64(pkt.pointee.size)
        }
        for (idx, segment) in plan.enumerated().dropLast() {
            let rate = Double(bytesPerSegment[idx]) * 8 / segment.durationSeconds
            #expect(Double(peak) >= rate, "segment \(idx): \(Int(rate)) bps above the index peak \(peak)")
        }
    }
}
