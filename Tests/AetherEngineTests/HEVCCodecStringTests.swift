import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#187 part 2: the plain-HEVC CODECS string. The `.none` / `.profile82` branch hardcoded
/// `hvc1.2.4.L<level>` (Main10, profile_idc=2) for every non-DV HEVC stream, mis-declaring 8-bit Main
/// as Main10. Once HEVC is routed through a master (so tvOS gets codec signaling) that Main10 claim is
/// checked against the Main hvcC in the init and rejected on device. These cover the pure builder that
/// derives the RFC 6381 string from the hvcC profile_tier_level, matching GPAC / ffmpeg output.
///
/// The compatibility-flags element is the reversed 32-bit general_profile_compatibility_flags, so
/// fixtures must carry the value a real encoder STORES (Main10 stores 0x20000000 and prints "4"),
/// never the already-reversed one. 0x60000000 is reversal-invariant and cannot catch a regression
/// here on its own.
@Suite("HEVC RFC 6381 codecs string")
struct HEVCCodecStringTests {

    /// Assemble an hvcC header from the profile_tier_level fields the builder reads (bytes 1..12).
    /// `constraints` is the 6-byte general_constraint_indicator_flags; the rest is plausible filler.
    static func hvcCHeader(
        profileSpace: UInt8 = 0, tierFlag: UInt8 = 0, profileIDC: UInt8,
        compat: UInt32, constraints: [UInt8], level: UInt8
    ) -> [UInt8] {
        precondition(constraints.count == 6)
        var h = [UInt8](repeating: 0, count: 23)
        h[0] = 1
        h[1] = (profileSpace << 6) | (tierFlag << 5) | (profileIDC & 0x1F)
        h[2] = UInt8((compat >> 24) & 0xFF)
        h[3] = UInt8((compat >> 16) & 0xFF)
        h[4] = UInt8((compat >> 8) & 0xFF)
        h[5] = UInt8(compat & 0xFF)
        for i in 0..<6 { h[6 + i] = constraints[i] }
        h[12] = level
        h[21] = 0xFF
        h[22] = 0   // numOfArrays; not read by the codecs-string builder
        return h
    }

    @Test("Reporter asset: 8-bit Main L3.1 -> hvc1.1.6.L93.90 (matches MP4Box)")
    func reporterMain8bit() {
        // Exact source hvcC header from AE#187 comment 5042505204: 0101600000009000000000005df0...
        let hvcC: [UInt8] = [0x01, 0x01, 0x60, 0x00, 0x00, 0x00, 0x90,
                             0x00, 0x00, 0x00, 0x00, 0x00, 0x5d]
        #expect(HLSVideoEngine.hevcCodecsString(fromConfigRecord: hvcC) == "hvc1.1.6.L93.90")
    }

    /// Dolby's official P8.1 asset (dolby-vision-contents, SolLevante 1080p24): the exact 13-byte
    /// hvcC header a real Main10 encoder writes. MP4Box reports `hev1.2.4.L153.B0` for it and Dolby's
    /// own reference manifest declares `hvc1.2.4.L150.b0` for the same content family, so the stored
    /// 0x20000000 must print as compatibility flags "4".
    @Test("Real Dolby P8.1 Main10 hvcC -> hvc1.2.4.L153.b0 (matches MP4Box)")
    func dolbyMain10Asset() {
        let hvcC: [UInt8] = [0x01, 0x02, 0x20, 0x00, 0x00, 0x00, 0xb0,
                             0x00, 0x00, 0x00, 0x00, 0x00, 0x99]
        #expect(HLSVideoEngine.hevcCodecsString(fromConfigRecord: hvcC) == "hvc1.2.4.L153.b0")
    }

    @Test("10-bit Main10, no constraint flags -> hvc1.2.4.L120")
    func main10NoConstraints() {
        let hvcC = Self.hvcCHeader(
            profileIDC: 2, compat: 0x20000000, constraints: [0, 0, 0, 0, 0, 0], level: 120)
        #expect(HLSVideoEngine.hevcCodecsString(fromConfigRecord: hvcC) == "hvc1.2.4.L120")
    }

    @Test("High tier -> H in the tier/level element")
    func highTier() {
        let hvcC = Self.hvcCHeader(
            tierFlag: 1, profileIDC: 1, compat: 0x60000000,
            constraints: [0x90, 0, 0, 0, 0, 0], level: 93)
        #expect(HLSVideoEngine.hevcCodecsString(fromConfigRecord: hvcC) == "hvc1.1.6.H93.90")
    }

    @Test("profile_space 1/2/3 -> A/B/C prefix")
    func profileSpacePrefix() {
        let a = Self.hvcCHeader(
            profileSpace: 1, profileIDC: 1, compat: 0x60000000,
            constraints: [0x90, 0, 0, 0, 0, 0], level: 93)
        #expect(HLSVideoEngine.hevcCodecsString(fromConfigRecord: a) == "hvc1.A1.6.L93.90")
    }

    @Test("Multi-byte constraint flags dot-join, trailing zero bytes dropped")
    func multiByteConstraints() {
        let hvcC = Self.hvcCHeader(
            profileIDC: 1, compat: 0x60000000,
            constraints: [0x90, 0x40, 0x00, 0x00, 0x00, 0x00], level: 93)
        #expect(HLSVideoEngine.hevcCodecsString(fromConfigRecord: hvcC) == "hvc1.1.6.L93.90.40")
    }

    /// general_profile_compatibility_flag[31] set: after the reversal it becomes the most
    /// significant bit, so the stored 0x60000001 prints as 0x80000006.
    @Test("Low-order stored flag reverses into the high-order hex digit")
    func compatReversalKeepsAllBits() {
        let hvcC = Self.hvcCHeader(
            profileIDC: 1, compat: 0x60000001,
            constraints: [0, 0, 0, 0, 0, 0], level: 93)
        #expect(HLSVideoEngine.hevcCodecsString(fromConfigRecord: hvcC) == "hvc1.1.80000006.L93")
    }

    @Test("Custom sample entry (dvh1) is honored")
    func customSampleEntry() {
        let hvcC: [UInt8] = [0x01, 0x01, 0x60, 0x00, 0x00, 0x00, 0x90,
                             0x00, 0x00, 0x00, 0x00, 0x00, 0x5d]
        #expect(HLSVideoEngine.hevcCodecsString(fromConfigRecord: hvcC, sampleEntry: "dvh1")
            == "dvh1.1.6.L93.90")
    }

    @Test("Non-hvcC (configurationVersion != 1) returns nil")
    func nonHvcCReturnsNil() {
        let annexB: [UInt8] = [0x00, 0x00, 0x00, 0x01] + Array(repeating: 0x42, count: 40)
        #expect(HLSVideoEngine.hevcCodecsString(fromConfigRecord: annexB) == nil)
    }

    @Test("Too-short buffer returns nil")
    func tooShortReturnsNil() {
        #expect(HLSVideoEngine.hevcCodecsString(fromConfigRecord: [1, 1, 0x60, 0, 0, 0]) == nil)
    }

    /// Audit HLS-3: 8-bit Main L3.1 as MPEG-TS carries it, a VPS and an SPS behind start codes with
    /// the emulation-prevention bytes a real encoder writes into the zero runs of the PTL.
    static let annexBMain8bit: [UInt8] = [
        0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00,
        0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x5d, 0x95, 0x94, 0x09,
        0x00, 0x00, 0x00, 0x01, 0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x03, 0x00, 0x5d, 0xa0, 0x02, 0x80, 0x80, 0x2d, 0x16, 0x59, 0x59, 0xa4, 0x93,
        0x2b, 0x80,
    ]

    @Test("Annex-B 8-bit Main SPS -> hvc1.1.6.L93.90, not the Main10 fallback")
    func annexBMain8bitFromSPS() {
        #expect(HLSVideoEngine.hevcCodecsString(fromAnnexBExtradata: Self.annexBMain8bit)
            == "hvc1.1.6.L93.90")
    }

    @Test("Annex-B Main10 SPS keeps its own profile and level")
    func annexBMain10FromSPS() {
        let annexB: [UInt8] = [
            0x00, 0x00, 0x01, 0x42, 0x01, 0x01, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00,
            0x03, 0x00, 0x00, 0x03, 0x00, 0x78, 0xa0, 0x03, 0xc0, 0x80, 0x11, 0x07, 0xca,
        ]
        #expect(HLSVideoEngine.hevcCodecsString(fromAnnexBExtradata: annexB) == "hvc1.2.4.L120.90")
    }

    @Test("Annex-B extradata without an SPS returns nil")
    func annexBWithoutSPS() {
        #expect(HLSVideoEngine.hevcCodecsString(
            fromAnnexBExtradata: [0x00, 0x00, 0x01, 0x40, 0x01, 0x0c, 0x01, 0xff]) == nil)
    }

    @Test("the plain HEVC route declares the Annex-B source's own profile in the master")
    func plainRouteUsesAnnexBSPS() throws {
        var codecpar: UnsafeMutablePointer<AVCodecParameters>? = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&codecpar) }
        let cp = codecpar!
        cp.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        cp.pointee.codec_id = AV_CODEC_ID_HEVC
        cp.pointee.level = 93
        let bytes = Self.annexBMain8bit
        let ed = try #require(av_mallocz(bytes.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)))
            .assumingMemoryBound(to: UInt8.self)
        bytes.withUnsafeBufferPointer { ed.update(from: $0.baseAddress!, count: bytes.count) }
        cp.pointee.extradata = ed
        cp.pointee.extradata_size = Int32(bytes.count)

        let engine = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/main8.ts"),
                                    dvModeAvailable: false)
        let route = try engine.resolveCodecRoute(codecpar: UnsafePointer(cp))
        #expect(route.primaryCodecs == "hvc1.1.6.L93.90")
    }
}
