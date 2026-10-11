import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#674: a DV Profile 8.1 MKV whose hvcC states level 5.2 (156) on a 1080p24 picture. The level went
/// into the master's CODECS verbatim, and an Apple TV 4K refused the DV master and the reduced HDR master
/// with -11848 / CoreMedia -15517, ending on the media playlist with Dolby Vision dropped. Declared as
/// 5.1 the same master is accepted and the panel engages DV (reporter, Sony X90L). The DV branches also
/// hardcoded `hvc1.2.4.L<level>` and dropped the hvcC's constraint bytes, the disagreement AE#187 fixed
/// for plain HEVC.
@Suite("AE#674 declared HEVC level cap")
struct Issue674HEVCLevelCapTests {

    /// The reporter's hvcC header: profile_idc 2, compat 0x20000000, constraints 90 00.., level_idc 156.
    static let duneHvcC: [UInt8] = [0x01, 0x02, 0x20, 0x00, 0x00, 0x00, 0x90,
                                    0x00, 0x00, 0x00, 0x00, 0x00, 0x9c,
                                    0xf0, 0x00, 0xfc, 0xfd, 0xfa, 0xfa, 0x00, 0x00, 0x0f, 0x00]

    @Test("a stated level 5.2 is declared as 5.1")
    func builderCapsLevel52() {
        #expect(HLSVideoEngine.hevcCodecsString(fromConfigRecord: Self.duneHvcC) == "hvc1.2.4.L153.90")
    }

    @Test("levels up to 5.1 are declared as stated", arguments: [UInt8(93), 120, 150, 153])
    func builderKeepsLowerLevels(level: UInt8) {
        var hvcC = Self.duneHvcC
        hvcC[12] = level
        #expect(HLSVideoEngine.hevcCodecsString(fromConfigRecord: hvcC) == "hvc1.2.4.L\(level).90")
    }

    @Test("the DV Profile 8.1 route declares the capped level with the hvcC's constraint bytes")
    func profile81RouteFromHvcC() throws {
        let par = try Profile81Codecpar(level: 156, extradata: Self.duneHvcC)
        let r = try Self.route(par)
        #expect(r.primaryCodecs == "hvc1.2.4.L153.90")
        #expect(r.supplementalCodecs == "dvh1.08.03/db1p")
        #expect(r.dvVariant == .profile81)
    }

    @Test("without a parseable hvcC the fallback declaration is capped too")
    func profile81RouteFallback() throws {
        let par = try Profile81Codecpar(level: 156, extradata: nil)
        #expect(try Self.route(par).primaryCodecs == "hvc1.2.4.L153")
    }

    // MARK: - Harness

    private static func route(_ par: Profile81Codecpar) throws -> HLSVideoEngine.CodecRoute {
        let engine = HLSVideoEngine(url: URL(fileURLWithPath: "/dev/null"), dvModeAvailable: true)
        return try engine.resolveCodecRoute(codecpar: UnsafePointer(par.ptr))
    }

    /// 1920x802 HEVC with a DV Profile 8.1 (compat 1, dv_level 3) record, freed with the test.
    private final class Profile81Codecpar {
        let ptr: UnsafeMutablePointer<AVCodecParameters>

        init(level: Int32, extradata: [UInt8]?) throws {
            ptr = try #require(avcodec_parameters_alloc())
            ptr.pointee.codec_type = AVMEDIA_TYPE_VIDEO
            ptr.pointee.codec_id = AV_CODEC_ID_HEVC
            ptr.pointee.width = 1920
            ptr.pointee.height = 802
            ptr.pointee.level = level
            ptr.pointee.color_primaries = AVCOL_PRI_BT2020
            ptr.pointee.color_trc = AVCOL_TRC_SMPTE2084
            ptr.pointee.color_space = AVCOL_SPC_BT2020_NCL
            if let bytes = extradata {
                let ed = try #require(av_mallocz(bytes.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)))
                    .assumingMemoryBound(to: UInt8.self)
                bytes.withUnsafeBufferPointer { ed.update(from: $0.baseAddress!, count: bytes.count) }
                ptr.pointee.extradata = ed
                ptr.pointee.extradata_size = Int32(bytes.count)
            }
            let size = MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
            let sd = try #require(av_packet_side_data_new(
                &ptr.pointee.coded_side_data, &ptr.pointee.nb_coded_side_data,
                AV_PKT_DATA_DOVI_CONF, size, 0))
            memset(sd.pointee.data, 0, size)
            sd.pointee.data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { rec in
                rec.pointee.dv_version_major = 1
                rec.pointee.dv_profile = 8
                rec.pointee.dv_level = 3
                rec.pointee.rpu_present_flag = 1
                rec.pointee.bl_present_flag = 1
                rec.pointee.dv_bl_signal_compatibility_id = 1
            }
        }

        deinit {
            var p: UnsafeMutablePointer<AVCodecParameters>? = ptr
            avcodec_parameters_free(&p)
        }
    }
}
