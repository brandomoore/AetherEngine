import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Audit DEC-104 / Vpipeline-101: the 1 Hz telemetry read `swrCtx` and `encoderCtx` without the
/// bridge's lock and called `swr_get_delay` on them, while the pump thread frees and replaces both
/// mid-stream (a decoded format change rebuilds the resampler, a restart after EOF rebuilds the
/// encoder). The read is a use-after-free in a window a few instructions wide, so the defect is pinned
/// as a stress run that is meant to be read under TSan, plus the figures the snapshot must agree on.
@Suite("AudioBridge live bytes snapshot (DEC-104, Vpipeline-101)")
struct AudioBridgeLiveBytesTests {

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func set() { lock.withLock { done = true } }
        var isSet: Bool { lock.withLock { done } }
    }

    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var polls = 0
        private var insane = 0
        func record(sane: Bool) { lock.withLock { polls += 1; if !sane { insane += 1 } } }
        var snapshot: (polls: Int, insane: Int) { lock.withLock { (polls, insane) } }
    }

    private func makeCodecpar() -> UnsafeMutablePointer<AVCodecParameters> {
        let par = avcodec_parameters_alloc()!
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_MP3
        par.pointee.sample_rate = 48_000
        par.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        av_channel_layout_default(&par.pointee.ch_layout, 2)
        return par
    }

    /// One silent MPEG-1 Layer III frame (128 kbps). 44.1 kHz and 48 kHz frames alternate, so the
    /// decoder answers with a different rate every packet and the bridge rebuilds its resampler each time.
    private func makeFrame(rate48k: Bool, pts: Int64) -> UnsafeMutablePointer<AVPacket>? {
        let size = rate48k ? 384 : 417
        guard let pkt = trackedPacketAlloc(), av_new_packet(pkt, Int32(size)) >= 0 else { return nil }
        memset(pkt.pointee.data, 0, size)
        pkt.pointee.data[0] = 0xFF
        pkt.pointee.data[1] = 0xFB
        pkt.pointee.data[2] = rate48k ? 0x94 : 0x90
        pkt.pointee.pts = pts
        pkt.pointee.dts = pts
        return pkt
    }

    private func free(_ packets: [UnsafeMutablePointer<AVPacket>]) {
        for p in packets {
            var pp: UnsafeMutablePointer<AVPacket>? = p
            trackedPacketFree(&pp)
        }
    }

    @Test("a poller reading liveBytes through resampler and encoder swaps sees only sane figures")
    func pollerSurvivesContextSwaps() throws {
        let codecpar = makeCodecpar()
        defer {
            var p: UnsafeMutablePointer<AVCodecParameters>? = codecpar
            avcodec_parameters_free(&p)
        }
        let bridge = try AudioBridge(srcCodecpar: codecpar, srcTimeBase: AVRational(num: 1, den: 1000),
                                     mode: .surroundCompat)
        defer { bridge.close() }

        let finished = Flag()
        let tally = Tally()
        let poller = Thread {
            while !finished.isSet {
                let live = bridge.liveBytes
                let sane = live.fifoSamples >= 0
                    && live.swrDelaySamples >= 0 && live.swrDelaySamples < 1 << 20
                    && live.fifoBytes >= 0 && live.swrDelayBytes >= 0
                    && live.totalBytes == live.fifoBytes + live.swrDelayBytes
                tally.record(sane: sane)
            }
        }
        poller.start()
        while tally.snapshot.polls == 0 { usleep(1000) }

        var produced = 0
        for round in 0..<40 {
            for i in 0..<40 {
                guard let pkt = makeFrame(rate48k: i % 2 == 0, pts: Int64(round * 40 + i) * 26) else { continue }
                let out = (try? bridge.feed(packet: pkt)) ?? []
                produced += out.count
                free(out)
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                trackedPacketFree(&p)
            }
            free(bridge.flush())
            bridge.startSegment()
        }
        finished.set()
        while !poller.isFinished { usleep(1000) }

        #expect(bridge.feedStats.framesDecoded > 0, "the fixture must reach the resampler for the swaps to happen")
        let result = tally.snapshot
        #expect(result.polls > 0)
        #expect(result.insane == 0)
    }

    @Test("the snapshot follows the bridge through feed, restart and close")
    func snapshotTracksOperations() throws {
        let codecpar = makeCodecpar()
        defer {
            var p: UnsafeMutablePointer<AVCodecParameters>? = codecpar
            avcodec_parameters_free(&p)
        }
        let bridge = try AudioBridge(srcCodecpar: codecpar, srcTimeBase: AVRational(num: 1, den: 1000),
                                     mode: .surroundCompat)
        for i in 0..<3 {
            guard let pkt = makeFrame(rate48k: true, pts: Int64(i) * 24) else { continue }
            free((try? bridge.feed(packet: pkt)) ?? [])
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
        }
        let afterFeed = bridge.liveBytes
        #expect(afterFeed.fifoSamples > 0, "three MP3 frames leave a partial encoder frame in the FIFO")
        #expect(afterFeed.fifoSamples == bridge.fifoSampleCount)
        #expect(afterFeed.fifoBytes > 0)

        bridge.startSegment()
        #expect(bridge.liveBytes.fifoSamples == 0)
        #expect(bridge.fifoSampleCount == 0)

        bridge.close()
        let closed = bridge.liveBytes
        #expect(closed.fifoSamples == 0 && closed.fifoBytes == 0)
        #expect(closed.swrDelaySamples == 0 && closed.swrDelayBytes == 0)
    }
}
