// A video sample carrying a length-prefixed NAL chain that overruns its own payload (AE#561).
//
// A damaged Blu-ray remux handed one HEVC packet whose sixth length field declared 384137139 bytes
// with 350873 left in the packet. libavcodec answers such a packet with "Invalid NAL unit size" and
// skips the frame, which is why the file plays in mpv; Apple's fMP4 parser answers the whole segment
// with CoreMediaErrorDomain -19602 and the session is over, with the reload dying on the same
// segment. The muxer therefore truncates the sample at the last complete NAL before it is written,
// which is byte for byte what MKVToolNix does to that packet and what makes the file play.
import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

@Suite("Length-prefixed NAL chain sanitizer (AE#561)")
struct NALUnitChainTests {

    /// `lengthPrefixSize` bytes of big-endian length followed by `payload` bytes of body.
    private static func nal(_ body: [UInt8], lengthPrefixSize: Int = 4) -> [UInt8] {
        var out: [UInt8] = []
        let n = body.count
        for shift in stride(from: (lengthPrefixSize - 1) * 8, through: 0, by: -8) {
            out.append(UInt8((n >> shift) & 0xFF))
        }
        return out + body
    }

    private static func run(_ bytes: [UInt8], lengthPrefixSize: Int = 4) -> Int? {
        bytes.withUnsafeBytes { NALUnitChain.completeRunLength($0, lengthPrefixSize: lengthPrefixSize) }
    }

    @Test("A chain that ends on a complete NAL is left alone")
    func healthyChainIsUntouched() {
        let bytes = Self.nal([0x26, 0x01, 0xAA, 0xBB]) + Self.nal([0x02, 0x01, 0xCC]) + Self.nal([0x02, 0x01])
        #expect(Self.run(bytes) == nil)
    }

    @Test("A declared length past the end truncates at the last complete NAL")
    func overrunTruncates() {
        let good = Self.nal([0x26, 0x01, 0xAA, 0xBB]) + Self.nal([0x02, 0x01, 0xCC, 0xDD, 0xEE])
        // The reporter's shape: a length field far larger than what is left in the packet.
        let broken: [UInt8] = [0x16, 0xE5, 0x77, 0xB3] + [UInt8](repeating: 0x5A, count: 64)
        #expect(Self.run(good + broken) == good.count)
    }

    @Test("A trailing stub shorter than one length field truncates too")
    func trailingStubTruncates() {
        let good = Self.nal([0x26, 0x01, 0xAA])
        #expect(Self.run(good + [0x00, 0x02]) == good.count)
    }

    @Test("A zero-length NAL ends the run")
    func zeroLengthEndsRun() {
        let good = Self.nal([0x26, 0x01, 0xAA])
        #expect(Self.run(good + Self.nal([])) == good.count)
    }

    @Test("A payload whose first NAL already overruns leaves nothing to write")
    func nothingCompleteYieldsZero() {
        #expect(Self.run([0x00, 0x10, 0x00, 0x00, 0x01, 0x02]) == 0)
    }

    /// An Annex B payload is not a length-prefixed chain, and reading its start code as a length
    /// would truncate every frame of a healthy stream to nothing.
    @Test("An Annex B payload is refused, in both start-code widths")
    func annexBIsRefused() {
        #expect(Self.run([0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0xAA, 0xBB]) == nil)
        #expect(Self.run([0x00, 0x00, 0x01, 0x26, 0x01, 0xAA, 0xBB, 0xCC]) == nil)
    }

    /// Audit BIT-1: a first NAL of 256 to 511 bytes has the 4-byte length `00 00 01 xx`, which the
    /// head test alone reads as a start code, so the overlong length behind it reached the parser.
    @Test("A 256-511 byte first NAL no longer hides an overrun once the track walked exactly")
    func threeByteHeadIsALengthOnceConfirmed() {
        let first = Self.nal([0x4E, 0x01] + [UInt8](repeating: 0x5A, count: 318))
        #expect(Array(first.prefix(3)) == [0x00, 0x00, 0x01])
        let broken: [UInt8] = [0x16, 0xE5, 0x7A, 0xB3] + [UInt8](repeating: 0x5A, count: 96)
        let sample = first + broken

        #expect(Self.run(sample) == nil, "unconfirmed, the head still reads as Annex B")
        let confirmed = sample.withUnsafeBytes {
            NALUnitChain.completeRunLength($0, lengthPrefixSize: 4, framingConfirmed: true)
        }
        #expect(confirmed == first.count)

        // The healthy sample of the same shape is what confirms the framing in the first place.
        #expect(first.withUnsafeBytes { NALUnitChain.walksExactly($0, lengthPrefixSize: 4) })
        // Annex B never confirms it, and a 4-byte start code stays refused even once confirmed.
        let annexB: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0xAA, 0xBB, 0x00, 0x00, 0x01, 0x02, 0x01]
        #expect(!annexB.withUnsafeBytes { NALUnitChain.walksExactly($0, lengthPrefixSize: 4) })
        #expect(annexB.withUnsafeBytes {
            NALUnitChain.completeRunLength($0, lengthPrefixSize: 4, framingConfirmed: true)
        } == nil)
    }

    @Test("The prefix width is honoured, not assumed to be four")
    func widthIsHonoured() {
        let two = Self.nal([0x26, 0x01, 0xAA], lengthPrefixSize: 2)
            + Self.nal([0x02, 0x01], lengthPrefixSize: 2)
        #expect(Self.run(two, lengthPrefixSize: 2) == nil)
        #expect(Self.run(two + [0xFF, 0xF0, 0x01], lengthPrefixSize: 2) == two.count)
    }

    // MARK: - The width comes out of the configuration record

    @Test("hvcC declares its width in byte 21, avcC in byte 4")
    func widthFromConfigurationRecord() {
        var hvcC = [UInt8](repeating: 0, count: 23)
        hvcC[0] = 1
        hvcC[21] = 0xFC | 0x03           // naluLengthSizeMinusOne = 3
        #expect(Self.prefixSize(.hevc, hvcC) == 4)
        hvcC[21] = 0xFC | 0x01
        #expect(Self.prefixSize(.hevc, hvcC) == 2)

        var avcC: [UInt8] = [1, 0x64, 0x00, 0x28, 0xFF, 0xE1]
        #expect(Self.prefixSize(.h264, avcC) == 4)
        avcC[4] = 0xFC | 0x00
        #expect(Self.prefixSize(.h264, avcC) == 1)
    }

    @Test("Annex B extradata, a truncated record and a foreign codec declare no width")
    func widthAbsent() {
        #expect(Self.prefixSize(.hevc, [0x00, 0x00, 0x00, 0x01, 0x40, 0x01]) == nil)
        #expect(Self.prefixSize(.hevc, [UInt8](repeating: 1, count: 22)) == nil)
        #expect(Self.prefixSize(.h264, [1, 0x64, 0x00]) == nil)
        #expect(Self.prefixSize(.av1, [UInt8](repeating: 1, count: 40)) == nil)
        #expect(Self.prefixSize(.hevc, []) == nil)
    }

    private static func prefixSize(_ codec: Codec, _ extradata: [UInt8]) -> Int? {
        let id: AVCodecID
        switch codec {
        case .hevc: id = AV_CODEC_ID_HEVC
        case .h264: id = AV_CODEC_ID_H264
        case .av1: id = AV_CODEC_ID_AV1
        }
        return extradata.withUnsafeBufferPointer {
            NALUnitChain.lengthPrefixSize(codecID: id, extradata: $0.baseAddress, extradataSize: $0.count)
        }
    }

    private enum Codec { case hevc, h264, av1 }

    // MARK: - The verdict outlives the muxer (audit BIT-104)

    /// Audit BIT-104: every seek, restart and reload builds a fresh muxer, and the sample a restart
    /// lands on is that muxer's first. With the BIT-1 verdict held per muxer, exactly that sample was
    /// judged by the head test alone, so a damaged IRAP with a 256-511 byte first NAL reached movenc
    /// uncut on every retry of the restart.
    @Test("A muxer rebuilt mid-session inherits the track's confirmed framing")
    func rebuiltMuxerInheritsConfirmedFraming() throws {
        let data = try #require(Data(base64Encoded: AtmosDetectionProbeIntegrationTests.videoOnlyBase64,
                                     options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mp4")
        defer { demuxer.close() }
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        let sessionDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bit104-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionDir) }

        func makeMuxer(_ index: Int, latch: NALFramingLatch?) throws -> MP4SegmentMuxer {
            try MP4SegmentMuxer(
                initialSegmentIndex: index, sessionDir: sessionDir,
                video: .init(codecpar: UnsafePointer(stream.pointee.codecpar),
                             timeBase: stream.pointee.time_base, codecTagOverride: nil,
                             nalFramingLatch: latch),
                audio: nil, onInitCaptured: { _ in })
        }
        func write(_ bytes: [UInt8], to muxer: MP4SegmentMuxer) throws {
            var packet: UnsafeMutablePointer<AVPacket>? = trackedPacketAlloc()
            defer { trackedPacketFree(&packet) }
            let pkt = packet!
            #expect(av_new_packet(pkt, Int32(bytes.count)) >= 0)
            bytes.withUnsafeBytes { _ = memcpy(pkt.pointee.data, $0.baseAddress, bytes.count) }
            pkt.pointee.pts = 0
            pkt.pointee.dts = 0
            pkt.pointee.duration = 512
            pkt.pointee.flags |= AV_PKT_FLAG_KEY
            pkt.pointee.stream_index = muxer.videoOutputStreamIndex
            _ = muxer.writePacket(pkt)
        }

        // What the restart lands on: a first NAL whose 4-byte length reads `00 00 01 40`, then a
        // length far past the end of the sample.
        let first = Self.nal([0x65, 0x88] + [UInt8](repeating: 0x5A, count: 318))
        #expect(Array(first.prefix(4)) == [0x00, 0x00, 0x01, 0x40])
        let damaged = first + [0x16, 0xE5, 0x7A, 0xB3] + [UInt8](repeating: 0x5A, count: 96)

        let session = NALFramingLatch()
        let earlier = try makeMuxer(0, latch: session)
        try write(Self.nal([0x65, 0x88, 0x84, 0x00]), to: earlier)   // walks exactly
        #expect(session.isConfirmed)

        let rebuilt = try makeMuxer(7, latch: session)
        try write(damaged, to: rebuilt)
        #expect(rebuilt.truncatedVideoSamples == 1, "the rebuilt muxer passed the overrun through uncut")

        // A track nobody has confirmed keeps the Annex B head guard.
        let unconfirmed = try makeMuxer(7, latch: nil)
        try write(damaged, to: unconfirmed)
        #expect(unconfirmed.truncatedVideoSamples == 0)
    }
}
