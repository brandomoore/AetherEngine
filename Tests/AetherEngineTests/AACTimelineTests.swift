import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

@Suite("AAC container and sample timelines", .serialized, .offCooperativePool)
struct AACTimelineTests {
    enum Timing: Sendable {
        case regular, jitter, compressed, expanded, lateCompressed

        func timestamp(_ frame: Int) -> Int64 {
            let nominal = Int64(frame) * 1024
            switch self {
            case .regular: return nominal
            case .jitter: return nominal + Int64(frame % 3 - 1)
            case .compressed: return nominal * 59 / 60 + Int64(frame % 7)
            case .expanded: return nominal * 61 / 60 + Int64(frame % 7)
            case .lateCompressed:
                return nominal - Int64(max(0, frame - 1500)) * 1024 / 60
            }
        }
    }

    // A generated AAC-LC silence access unit; the same payload decodes to 1024 samples.
    private static let silence: [UInt8] = [0x21, 0x10, 0x04, 0x60, 0x8c, 0x1c]

    static func fixture(timing: Timing, rate: Int32 = 44_100, seconds: Int = 65) throws -> Data {
        let video = Demuxer()
        defer { video.close() }
        let data = try #require(Data(base64Encoded: AtmosDetectionProbeIntegrationTests.videoOnlyBase64,
                                     options: .ignoreUnknownCharacters))
        try video.open(reader: DataIOReader(data: data), formatHint: "mp4")
        let sourceVideo = try #require(video.stream(at: video.videoStreamIndex))
        let firstVideo = try #require(try video.readPacket())
        var ownedVideo: UnsafeMutablePointer<AVPacket>? = firstVideo
        defer { trackedPacketFree(&ownedVideo) }

        var output: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_alloc_output_context2(&output, nil, "mp4", nil) >= 0)
        let context = try #require(output)
        defer { avformat_free_context(context) }
        var io: UnsafeMutablePointer<AVIOContext>?
        try #require(avio_open_dyn_buf(&io) >= 0)
        let buffer = try #require(io)
        context.pointee.pb = buffer
        var bytes: UnsafeMutablePointer<UInt8>?
        var closed = false
        defer {
            if !closed { _ = avio_close_dyn_buf(buffer, &bytes) }
            av_free(bytes)
        }
        let vs = try #require(avformat_new_stream(context, nil))
        try #require(avcodec_parameters_copy(vs.pointee.codecpar, sourceVideo.pointee.codecpar) >= 0)
        vs.pointee.codecpar.pointee.video_delay = 0
        vs.pointee.time_base = AVRational(num: 1, den: 24_000)
        vs.pointee.avg_frame_rate = AVRational(num: 24_000, den: 1001)
        let audio = try #require(avformat_new_stream(context, nil))
        let cp = audio.pointee.codecpar!
        cp.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        cp.pointee.codec_id = AV_CODEC_ID_AAC
        cp.pointee.sample_rate = rate
        cp.pointee.frame_size = 1024
        cp.pointee.profile = 1
        av_channel_layout_default(&cp.pointee.ch_layout, 2)
        cp.pointee.extradata = av_mallocz(2 + Int(AV_INPUT_BUFFER_PADDING_SIZE))?.assumingMemoryBound(to: UInt8.self)
        let extra = try #require(cp.pointee.extradata)
        extra[0] = rate == 44_100 ? 0x12 : 0x11
        extra[1] = rate == 44_100 ? 0x10 : 0x90
        cp.pointee.extradata_size = 2
        audio.pointee.time_base = AVRational(num: 1, den: rate)
        try #require(avformat_write_header(context, nil) >= 0)

        for n in 0..<(seconds * 24) {
            var packet: UnsafeMutablePointer<AVPacket>? = av_packet_clone(firstVideo)
            defer { av_packet_free(&packet) }
            let p = try #require(packet)
            p.pointee.pts = Int64(n) * 1001
            p.pointee.dts = p.pointee.pts
            p.pointee.duration = 1001
            p.pointee.stream_index = 0
            p.pointee.pos = -1
            try #require(av_interleaved_write_frame(context, p) >= 0)
        }
        for n in 0..<(seconds * Int(rate) / 1024) {
            var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
            defer { av_packet_free(&packet) }
            let p = try #require(packet)
            try #require(av_new_packet(p, Int32(silence.count)) >= 0)
            silence.withUnsafeBufferPointer { p.pointee.data.update(from: $0.baseAddress!, count: $0.count) }
            p.pointee.pts = timing.timestamp(n) + 1
            p.pointee.dts = p.pointee.pts
            p.pointee.duration = timing.timestamp(n + 1) - timing.timestamp(n)
            p.pointee.flags = AV_PKT_FLAG_KEY
            p.pointee.stream_index = 1
            p.pointee.pos = -1
            try #require(av_interleaved_write_frame(context, p) >= 0)
        }
        try #require(av_write_trailer(context) >= 0)
        let count = avio_close_dyn_buf(buffer, &bytes)
        closed = true
        context.pointee.pb = nil
        try #require(count > 0)
        return Data(bytes: try #require(bytes), count: Int(count))
    }

    @Test("Biased AAC is normalized instead of copied to AVPlayer",
          .timeLimit(.minutes(2)), arguments: [Timing.compressed, .expanded, .lateCompressed])
    func routesBiasedAudio(timing: Timing) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aac-timeline-\(UUID()).mp4")
        try Self.fixture(timing: timing).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = HLSVideoEngine(url: url, dvModeAvailable: false)
        _ = try engine.start()
        defer { engine.stop() }
        #expect(engine.audioDelivery != .streamCopy,
                "Plozz#89: native AAC decode must not accumulate a sample clock different from its timestamps")
        #expect(engine.audioDelivery != .droppedNoPipeline)
    }

    @Test("Ordinary AAC and nonaccumulating jitter retain stream copy",
          .timeLimit(.minutes(2)), arguments: [Timing.regular, .jitter])
    func preservesStreamCopy(timing: Timing) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aac-control-\(UUID()).mp4")
        try Self.fixture(timing: timing).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = HLSVideoEngine(url: url, dvModeAvailable: false)
        _ = try engine.start()
        defer { engine.stop() }
        #expect(engine.audioDelivery == .streamCopy)
        let provider = try #require(engine.provider)
        let segment = try #require(provider.mediaSegment(at: 0))
        let header = try #require(provider.initSegment())
        let reader = Demuxer()
        defer { reader.close() }
        try reader.open(reader: DataIOReader(data: header + segment), formatHint: "mp4")
        var copied = 0
        while let packet = try reader.readPacket() {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&owned) }
            guard packet.pointee.stream_index == reader.audioStreamIndex else { continue }
            #expect(Data(bytes: packet.pointee.data, count: Int(packet.pointee.size)) == Data(Self.silence))
            copied += 1
        }
        #expect(copied > 10)
    }

    @Test("Resampling bounds accumulated error through EOF and a restarted epoch",
          .timeLimit(.minutes(2)),
          arguments: [Timing.compressed, .expanded, .lateCompressed], [Int32(44_100), 48_000])
    func boundsDecodedTimeline(timing: Timing, rate: Int32) throws {
        try assertDecodedTimeline(timing: timing, rate: rate, shaping: AudioShaping())
    }

    @Test("AAC timeline correction and audio shaping retain their EOF tails across restarts",
          .timeLimit(.minutes(2)), arguments: [Timing.compressed, .expanded], [Int32(44_100), 48_000])
    func boundsShapedDecodedTimeline(timing: Timing, rate: Int32) throws {
        try assertDecodedTimeline(
            timing: timing, rate: rate, shaping: AudioShaping(dialogueGainDB: 6, compressor: .night))
    }

    private func assertDecodedTimeline(timing: Timing, rate: Int32, shaping: AudioShaping) throws {
        let data = try Self.fixture(timing: timing, rate: rate)
        let source = Demuxer()
        defer { source.close() }
        try source.open(reader: DataIOReader(data: data), formatHint: "mp4")
        let stream = try #require(source.stream(at: source.audioStreamIndex))
        let bridge = try AudioBridge(
            srcCodecpar: stream.pointee.codecpar, srcTimeBase: stream.pointee.time_base,
            correctSourceTimeline: true, shaping: shaping)
        defer { bridge.close() }

        for epoch in [0, 120] {
            if epoch > 0 { bridge.startSegment() }
            let reader = Demuxer()
            defer { reader.close() }
            try reader.open(reader: DataIOReader(data: data), formatHint: "mp4")
            var sourceEnd: Int64 = 0
            var outputEnd: Int64 = 0
            var outputStart: Int64?
            var count = 0
            func consume(_ packets: [UnsafeMutablePointer<AVPacket>]) {
                for packet in packets {
                    var owned: UnsafeMutablePointer<AVPacket>? = packet
                    defer { trackedPacketFree(&owned) }
                    if outputStart == nil { outputStart = packet.pointee.pts }
                    if count > 0 { #expect(packet.pointee.pts == outputEnd) }
                    outputEnd = packet.pointee.pts + packet.pointee.duration
                    count += 1
                }
            }
            while let packet = try reader.readPacket() {
                var owned: UnsafeMutablePointer<AVPacket>? = packet
                defer { trackedPacketFree(&owned) }
                guard packet.pointee.stream_index == reader.audioStreamIndex else { continue }
                packet.pointee.pts += Int64(epoch) * Int64(rate)
                packet.pointee.dts = packet.pointee.pts
                sourceEnd = packet.pointee.pts + packet.pointee.duration
                consume(try bridge.feed(packet: packet))
            }
            let enqueuedBeforeFlush = bridge.feedStats.samplesEnqueued
            consume(bridge.flush())
            #expect(bridge.feedStats.samplesEnqueued > enqueuedBeforeFlush,
                    "EOF must retain the compensation filter's delayed PCM tail")
            try #require(count > 100)
            let start = try #require(outputStart)
            #expect(abs(Double(start) / Double(rate) - Double(epoch)) < 0.025)
            let error = Double(outputEnd - sourceEnd) / Double(rate)
            #expect(abs(error) < 0.03, "decoded clock error \(error)s, epoch \(epoch)")
            #expect(bridge.feedStats.decodeErrors == 0)
            #expect(bridge.feedStats.encodeErrors == 0)
        }
    }

    @Test("Sparse, discontinuous and unsupported indexes cannot trigger correction")
    func rejectsUnprovenIndex() throws {
        let context = try #require(avformat_alloc_context())
        defer { avformat_free_context(context) }
        let stream = try #require(avformat_new_stream(context, nil))
        stream.pointee.time_base = AVRational(num: 1, den: 44_100)
        let cp = try #require(stream.pointee.codecpar)
        cp.pointee.codec_id = AV_CODEC_ID_AAC
        cp.pointee.profile = 1
        cp.pointee.sample_rate = 44_100
        cp.pointee.frame_size = 1024
        #expect(!AACSampleTimeline.requiresCorrection(stream: stream))
        for n in 0..<300 {
            #expect(av_add_index_entry(stream, Int64(n * 6), Int64(n * 1000), 6, 0, AVINDEX_KEYFRAME) >= 0)
        }
        #expect(AACSampleTimeline.requiresCorrection(stream: stream))
        cp.pointee.frame_size = 960
        #expect(!AACSampleTimeline.requiresCorrection(stream: stream))
        cp.pointee.frame_size = 1024
        cp.pointee.profile = 4
        #expect(!AACSampleTimeline.requiresCorrection(stream: stream))
        cp.pointee.profile = 1
        #expect(av_add_index_entry(stream, 1800, 400_000, 6, 0, AVINDEX_KEYFRAME) >= 0)
        #expect(!AACSampleTimeline.requiresCorrection(stream: stream))
    }

    @Test("Muxed HLS audio decodes on the corrected source timeline",
          .timeLimit(.minutes(2)), arguments: [0.0, 30.0])
    func validatesMuxedAudio(start: Double) throws {
        let rate: Int32 = 44_100
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aac-output-\(UUID()).mp4")
        try Self.fixture(timing: .compressed, rate: rate).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = HLSVideoEngine(url: url, dvModeAvailable: false)
        engine.initialStartSeconds = start
        _ = try engine.start()
        defer { engine.stop() }
        #expect(engine.audioDelivery == .bridged)
        let provider = try #require(engine.provider)
        var finalEnd = 0.0
        var decodedSamples = 0
        for index in engine.initialProducerBaseIndex..<provider.segmentCount {
            let segment = try #require(provider.mediaSegment(at: index))
            let header = try #require(provider.initSegment())
            let reader = Demuxer()
            defer { reader.close() }
            try reader.open(reader: DataIOReader(data: header + segment), formatHint: "mp4")
            let audio = try #require(reader.stream(at: reader.audioStreamIndex))
            #expect(audio.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_FLAC)
            let codec = try #require(avcodec_find_decoder(AV_CODEC_ID_FLAC))
            var decoder = avcodec_alloc_context3(codec)
            defer { avcodec_free_context(&decoder) }
            let decoderContext = try #require(decoder)
            try #require(avcodec_parameters_to_context(decoderContext, audio.pointee.codecpar) >= 0)
            try #require(avcodec_open2(decoderContext, codec, nil) >= 0)
            var frame = av_frame_alloc()
            defer { av_frame_free(&frame) }
            let decoded = try #require(frame)
            while let packet = try reader.readPacket() {
                var owned: UnsafeMutablePointer<AVPacket>? = packet
                defer { trackedPacketFree(&owned) }
                guard packet.pointee.stream_index == reader.audioStreamIndex else { continue }
                try #require(avcodec_send_packet(decoderContext, packet) >= 0)
                try #require(avcodec_receive_frame(decoderContext, decoded) >= 0)
                let sampleCount = decoded.pointee.nb_samples
                let duration = av_rescale_q(packet.pointee.duration, audio.pointee.time_base,
                                           AVRational(num: 1, den: rate))
                #expect(Int64(sampleCount) == duration)
                decodedSamples += Int(sampleCount)
                finalEnd = Double(packet.pointee.pts) * av_q2d(audio.pointee.time_base)
                    + Double(sampleCount) / Double(rate)
            }
        }
        #expect(decodedSamples > Int(rate) * Int(60 - start))
        let sourceEnd = Double(Timing.compressed.timestamp(65 * Int(rate) / 1024) + 1) / Double(rate)
        #expect(abs(finalEnd - sourceEnd) < 0.05,
                "native HLS decoded end \(finalEnd), source timestamp end \(sourceEnd)")
    }
}
