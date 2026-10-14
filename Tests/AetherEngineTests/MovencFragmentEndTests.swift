import Testing
import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// StreamX crash 2026-10-10: `Assertion next_dts >= 0 failed at libavformat/movenc.c:1247`, abort on the
/// `HLSSegmentProducer.pump` thread inside `mov_flush_fragment`. movenc moves the first sample of a
/// fragment up to the previous fragment's declared end and `check_pkt` clamps every following sample
/// that still sits below it (`Packet duration ... out of range`), so the written DTS can run AHEAD of
/// the real ones. A flush that finds a packet still waiting in the interleaver takes that packet's REAL
/// DTS as the track end (`ff_interleaved_peek`), which is then behind the last written sample, and
/// `get_cluster_duration` aborts the process instead of returning an error.
@Suite("movenc: a fragment end behind a clamped sample does not abort")
struct MovencFragmentEndTests {

    /// Runs the shape in a child process: before the fix it is a SIGABRT, which would take the whole
    /// test runner down with it. Exit tests exist on macOS only, not in the tvOS/iOS/visionOS simulators.
    #if os(macOS)
    @Test("finalize with a queued packet behind a clamped written sample")
    func finalizeWithQueuedPacketBehindClampedSample() async {
        await #expect(processExitsWith: .success) {
            try MovencFragmentEndTests.runOvershootThenFinalize()
        }
    }
    #endif

    // MARK: - Scenario

    static func runOvershootThenFinalize() throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(
            reader: DataIOReader(data: Data(
                base64Encoded: AtmosDetectionProbeIntegrationTests.videoOnlyBase64,
                options: .ignoreUnknownCharacters) ?? Data()),
            formatHint: "mp4"
        )
        guard let vStream = demuxer.stream(at: demuxer.videoStreamIndex) else { throw ScenarioError.noVideo }

        var videoPackets: [UnsafeMutablePointer<AVPacket>] = []
        defer { for p in videoPackets { var o: UnsafeMutablePointer<AVPacket>? = p; trackedPacketFree(&o) } }
        while let pkt = try demuxer.readPacket() {
            if pkt.pointee.stream_index == demuxer.videoStreamIndex, videoPackets.count < 3 {
                videoPackets.append(pkt)
            } else {
                var o: UnsafeMutablePointer<AVPacket>? = pkt
                trackedPacketFree(&o)
            }
        }
        guard videoPackets.count == 3 else { throw ScenarioError.tooFewFrames(videoPackets.count) }

        let audioPar = makeAACCodecpar()
        defer { var p: UnsafeMutablePointer<AVCodecParameters>? = audioPar; avcodec_parameters_free(&p) }

        let sessionDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("movenc-fragment-end-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionDir) }

        let muxer = try MP4SegmentMuxer(
            initialSegmentIndex: 0,
            sessionDir: sessionDir,
            video: MP4SegmentMuxer.VideoConfig(
                codecpar: UnsafePointer(vStream.pointee.codecpar),
                timeBase: vStream.pointee.time_base,
                codecTagOverride: nil
            ),
            audio: MP4SegmentMuxer.AudioConfig(
                codecpar: UnsafePointer(audioPar),
                timeBase: AVRational(num: 1, den: 48_000)
            ),
            onInitCaptured: { _ in }
        )

        // Frame duration in the muxer's video time base, and the same instant in its audio base.
        let vTb = muxer.muxerVideoTimeBase
        let aTb = muxer.muxerAudioTimeBase
        let frame = av_rescale_q(1, AVRational(num: 1, den: 25), vTb)
        func audioTicks(frames: Double) -> Int64 {
            av_rescale_q(Int64(frames * 1000), AVRational(num: 1, den: 25_000), aTb)
        }

        func writeVideo(_ index: Int, duration: Int64) {
            guard let pkt = av_packet_clone(videoPackets[index % videoPackets.count]) else { return }
            pkt.pointee.stream_index = muxer.videoOutputStreamIndex
            pkt.pointee.dts = Int64(index) * frame
            pkt.pointee.pts = pkt.pointee.dts
            pkt.pointee.duration = duration
            if index == 0 || index == 3 { pkt.pointee.flags |= AV_PKT_FLAG_KEY }
            _ = muxer.writePacket(pkt)
            var o: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_free(&o)
        }
        func writeAudio(atFrame f: Double) {
            guard let pkt = av_packet_alloc(), av_new_packet(pkt, 32) >= 0 else { return }
            memset(pkt.pointee.data, 0x21, 32)
            pkt.pointee.stream_index = muxer.audioOutputStreamIndex
            pkt.pointee.dts = audioTicks(frames: f)
            pkt.pointee.pts = pkt.pointee.dts
            pkt.pointee.duration = audioTicks(frames: 0.5)
            pkt.pointee.flags |= AV_PKT_FLAG_KEY
            _ = muxer.writePacket(pkt)
            var o: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_free(&o)
        }

        // Fragment 1: the last video sample declares ten frames although the next one follows after one.
        writeAudio(atFrame: 0)
        writeVideo(0, duration: frame)
        writeVideo(1, duration: frame)
        writeVideo(2, duration: 10 * frame)
        writeAudio(atFrame: 2.5)
        guard case .completed = muxer.cutFragmentForNextSegment(1) else { throw ScenarioError.cutFailed }

        // Fragment 2: frames 3...6 land below the declared end and are clamped up past it. Audio at 6.5
        // releases them; frame 7 then releases that audio and stays queued at its real, lower DTS.
        for i in 3...6 { writeVideo(i, duration: frame) }
        writeAudio(atFrame: 6.5)
        writeVideo(7, duration: frame)

        _ = muxer.finalize()
    }

    private static func makeAACCodecpar() -> UnsafeMutablePointer<AVCodecParameters> {
        let par = avcodec_parameters_alloc()!
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_AAC
        par.pointee.sample_rate = 48_000
        par.pointee.frame_size = 1024
        av_channel_layout_default(&par.pointee.ch_layout, 2)
        // AudioSpecificConfig: AAC LC, 48 kHz, stereo.
        let asc: [UInt8] = [0x11, 0x90]
        let buf = av_mallocz(asc.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))!.assumingMemoryBound(to: UInt8.self)
        buf.update(from: asc, count: asc.count)
        par.pointee.extradata = buf
        par.pointee.extradata_size = Int32(asc.count)
        return par
    }

    enum ScenarioError: Error { case noVideo, tooFewFrames(Int), cutFailed }
}

