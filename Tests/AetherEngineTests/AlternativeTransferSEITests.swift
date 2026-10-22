import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#839: HLG named by an `alternative_transfer_characteristics` SEI (payloadType 147) over a
/// backward-compatible VUI transfer, the way UK broadcast HLG is authored.
@Suite("Alternative transfer SEI: parser and gate")
struct AlternativeTransferSEITests {

    /// SEI RBSP: payload_type 147, payload_size 1, preferred_transfer_characteristics 18, trailing bits.
    static let seiRBSPHLG: [UInt8] = [0x93, 0x01, 0x12, 0x80]

    private func preferred(_ bytes: [UInt8], codec: A53SEIParser.CodecKind = .hevc,
                           framing: A53SEIParser.NALFraming = .annexB) -> UInt8? {
        bytes.withUnsafeBufferPointer {
            AlternativeTransferSEI.preferredTransfer(
                in: $0.baseAddress!, size: $0.count, codec: codec, framing: framing)
        }
    }

    @Test("HEVC prefix SEI (type 39) in Annex B yields the preferred transfer")
    func hevcAnnexB() {
        let pkt: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x4E, 0x01] + Self.seiRBSPHLG
        #expect(preferred(pkt) == AlternativeTransferSEI.hlgTransfer)
    }

    @Test("Length-prefixed HEVC, SEI after a slice NAL, still yields it")
    func hevcLengthPrefixedAfterSlice() {
        let slice: [UInt8] = [0x26, 0x01, 0xAF, 0x00]                  // IDR_W_RADL
        let sei: [UInt8] = [0x4E, 0x01] + Self.seiRBSPHLG
        let pkt = [0, 0, 0, UInt8(slice.count)] + slice + [0, 0, 0, UInt8(sei.count)] + sei
        #expect(preferred(pkt, framing: .lengthPrefixed(size: 4)) == AlternativeTransferSEI.hlgTransfer)
    }

    @Test("H.264 SEI (type 6) yields it")
    func h264AnnexB() {
        let pkt: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x06] + Self.seiRBSPHLG
        #expect(preferred(pkt, codec: .h264) == AlternativeTransferSEI.hlgTransfer)
    }

    @Test("A different SEI ahead of it in the same NAL is skipped over")
    func skipsEarlierPayload() {
        // payload_type 5 (user_data_unregistered), size 2, then the alternative transfer message.
        let rbsp: [UInt8] = [0x05, 0x02, 0xAA, 0xBB, 0x93, 0x01, 0x12, 0x80]
        let pkt: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x4E, 0x01] + rbsp
        #expect(preferred(pkt) == AlternativeTransferSEI.hlgTransfer)
    }

    @Test("No alternative transfer SEI, or a truncated one, yields nil")
    func absentOrTruncated() {
        let other: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x4E, 0x01, 0x05, 0x01, 0xAA, 0x80]
        #expect(preferred(other) == nil)
        let truncated: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x4E, 0x01, 0x93, 0x04, 0x12]
        #expect(preferred(truncated) == nil)
        let sliceOnly: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0x93, 0x01, 0x12]
        #expect(preferred(sliceOnly) == nil)
    }

    @Test("The gate opens only for a BT.2020 HEVC or H.264 stream with a backward-compatible transfer")
    func gate() {
        func gate(_ transfer: AVColorTransferCharacteristic, codec: AVCodecID = AV_CODEC_ID_HEVC,
                  primaries: AVColorPrimaries = AVCOL_PRI_BT2020) -> Bool {
            AlternativeTransferSEI.declaredTransferMayHideHLG(
                codecID: codec, primaries: primaries, transfer: transfer)
        }
        for transfer in [AVCOL_TRC_BT709, AVCOL_TRC_BT2020_10, AVCOL_TRC_BT2020_12, AVCOL_TRC_UNSPECIFIED] {
            #expect(gate(transfer))
            #expect(gate(transfer, codec: AV_CODEC_ID_H264))
        }
        #expect(!gate(AVCOL_TRC_SMPTE2084))
        #expect(!gate(AVCOL_TRC_ARIB_STD_B67))
        #expect(!gate(AVCOL_TRC_BT709, primaries: AVCOL_PRI_BT709))
        #expect(!gate(AVCOL_TRC_BT2020_10, codec: AV_CODEC_ID_AV1))
    }
}

/// The same against real files: 64x64 HEVC Main 10, BT.2020 / `bt2020-10` VUI, 2 frames, from x265.
/// The positive one is encoded with `--atc-sei 18`, and `ffprobe -show_frames` reports its frames as
/// `arib-std-b67` (FFmpeg's decoder applying the SEI), the negative one as `bt2020-10`:
///
///     ffmpeg -f lavfi -i color=c=gray:s=64x64:r=25:d=0.08 -pix_fmt yuv420p10le -c:v libx265 \
///       -x265-params atc-sei=18:colorprim=bt2020:transfer=bt2020-10:colormatrix=bt2020nc:keyint=1:info=0 \
///       -tag:v hvc1 -frames:v 2 -an -map_metadata -1 -fflags +bitexact sei.mp4
@Suite("Alternative transfer SEI: the demuxer promotes broadcast HLG")
struct AlternativeTransferSEIDemuxerTests {

    static let seiBase64 = """
    AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAAhmcmVlAAAAPm1kYXQAAAAGTgGTARKAAAAA
    DCgBr3jrrvv+dVfLTwAAAAZOAZMBEoAAAAAOKAGvF4Dnfo3/esB5wDgAAANFbW9vdgAAAGxtdmhk
    AAAAAAAAAAAAAAAAAAAD6AAAAFAAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAA
    AAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAApR0cmFrAAAAXHRr
    aGQAAAADAAAAAAAAAAAAAAABAAAAAAAAAFAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAA
    AAABAAAAAAAAAAAAAAAAAABAAAAAAEAAAABAAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAABQ
    AAAAAAABAAAAAAIMbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAyAAAABABVxAAAAAAALWhkbHIA
    AAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABt21pbmYAAAAUdm1oZAAAAAEA
    AAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAXdzdGJsAAABC3N0
    c2QAAAAAAAAAAQAAAPtodmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAEAAQABIAAAASAAAAAAA
    AAABDExhdmMgbGlieDI2NQAAAAAAAAAAAAAAAAAAAAAAAAAAGP//AAAAd2h2Y0MBBAgAAACdqAAA
    AAAe8AD8/fr6AAAPA6AAAQAXQAEMAf//BAgAAAMAnagAAAMAAB66AkChAAEAK0IBAQQIAAADAJ2o
    AAADAAAeoCCBBNlupJMrwFqEhwSCAAADAAIAAAMAMhCiAAEAB0QBwXKwIkAAAAAKZmllbAEAAAAA
    EHBhc3AAAAABAAAAAQAAABRidHJ0AAAAAAAAFRgAAAAAAAAAGHN0dHMAAAAAAAAAAQAAAAIAAAIA
    AAAAHHN0c2MAAAAAAAAAAQAAAAEAAAACAAAAAQAAABxzdHN6AAAAAAAAAAAAAAACAAAAGgAAABwA
    AAAUc3RjbwAAAAAAAAABAAAALAAAAD11ZHRhAAAANW1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1k
    aXJhcHBsAAAAAAAAAAAAAAAACGlsc3Q=
    """

    /// The same encode without `atc-sei`.
    static let plainBase64 = """
    AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAAhmcmVlAAAAKm1kYXQAAAAMKAGveOuu+/51
    V8tPAAAADigBrxeA536N/3rAecA4AAADRW1vb3YAAABsbXZoZAAAAAAAAAAAAAAAAAAAA+gAAABQ
    AAEAAAEAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAA
    AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAKUdHJhawAAAFx0a2hkAAAAAwAAAAAAAAAAAAAAAQAA
    AAAAAABQAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAA
    AABAAAAAQAAAAAAAJGVkdHMAAAAcZWxzdAAAAAAAAAABAAAAUAAAAAAAAQAAAAACDG1kaWEAAAAg
    bWRoZAAAAAAAAAAAAAAAAAAAMgAAAAQAVcQAAAAAAC1oZGxyAAAAAAAAAAB2aWRlAAAAAAAAAAAA
    AAAAVmlkZW9IYW5kbGVyAAAAAbdtaW5mAAAAFHZtaGQAAAABAAAAAAAAAAAAAAAkZGluZgAAABxk
    cmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAAF3c3RibAAAAQtzdHNkAAAAAAAAAAEAAAD7aHZjMQAA
    AAAAAAABAAAAAAAAAAAAAAAAAAAAAABAAEAASAAAAEgAAAAAAAAAAQxMYXZjIGxpYngyNjUAAAAA
    AAAAAAAAAAAAAAAAAAAAABj//wAAAHdodmNDAQQIAAAAnagAAAAAHvAA/P36+gAADwOgAAEAF0AB
    DAH//wQIAAADAJ2oAAADAAAeugJAoQABACtCAQEECAAAAwCdqAAAAwAAHqAggQTZbqSTK8BahIcE
    ggAAAwACAAADADIQogABAAdEAcFysCJAAAAACmZpZWwBAAAAABBwYXNwAAAAAQAAAAEAAAAUYnRy
    dAAAAAAAAA1IAAAAAAAAABhzdHRzAAAAAAAAAAEAAAACAAACAAAAABxzdHNjAAAAAAAAAAEAAAAB
    AAAAAgAAAAEAAAAcc3RzegAAAAAAAAAAAAAAAgAAABAAAAASAAAAFHN0Y28AAAAAAAAAAQAAACwA
    AAA9dWR0YQAAADVtZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAAAhp
    bHN0
    """

    private static func writeFixture(_ base64: String, name: String) throws -> URL {
        let cleaned = base64.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: "")
        guard let data = Data(base64Encoded: cleaned) else { throw CocoaError(.fileReadCorruptFile) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aether-ae839-\(name)-\(UUID().uuidString).mp4")
        try data.write(to: url)
        return url
    }

    private static func openedTransfer(_ demuxer: Demuxer) -> AVColorTransferCharacteristic? {
        demuxer.withStream(at: demuxer.videoStreamIndex) { $0.pointee.codecpar.pointee.color_trc }
    }

    @Test("The SEI source opens as HLG and still delivers every packet the scan looked at")
    func seiSourceIsHLG() throws {
        let url = try Self.writeFixture(Self.seiBase64, name: "sei")
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = Demuxer()
        try demuxer.open(url: url)
        defer { demuxer.close() }

        #expect(Self.openedTransfer(demuxer) == AVCOL_TRC_ARIB_STD_B67)
        let format = demuxer.withStream(at: demuxer.videoStreamIndex) { AetherEngine.detectVideoFormat(stream: $0) }
        #expect(format == .hlg)

        var packets = 0
        while let read = try demuxer.readPacket() {
            packets += 1
            var packet: UnsafeMutablePointer<AVPacket>? = read
            trackedPacketFree(&packet)
        }
        #expect(packets == 2)
    }

    @Test("The static probe reports the SEI source as HLG")
    func staticProbeIsHLG() throws {
        let url = try Self.writeFixture(Self.seiBase64, name: "sei")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try AetherEngine.probe(url: url).videoFormat == .hlg)
    }

    @Test("The same encode without the SEI keeps its declared transfer")
    func plainSourceStaysSDR() throws {
        let url = try Self.writeFixture(Self.plainBase64, name: "plain")
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = Demuxer()
        try demuxer.open(url: url)
        defer { demuxer.close() }
        #expect(Self.openedTransfer(demuxer) == AVCOL_TRC_BT2020_10)
        #expect(try AetherEngine.probe(url: url).videoFormat == .sdr)
    }
}
