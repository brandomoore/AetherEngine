import Foundation
import AetherLibavcodec
import Testing
@testable import AetherEngine

@Suite("Packet timing admission uses codec sample geometry")
struct SoftwarePacketTimingPolicyTests {
    @Test func fixedAudioAndConservativeUnknowns() throws {
        let p = try #require(avcodec_parameters_alloc())
        var allocated: UnsafeMutablePointer<AVCodecParameters>? = p
        defer { avcodec_parameters_free(&allocated) }
        p.pointee.sample_rate = 44100
        for (codec, count) in [(AV_CODEC_ID_AC3, 1536), (AV_CODEC_ID_MP1, 384),
                               (AV_CODEC_ID_MP2, 1152), (AV_CODEC_ID_MP3, 1152)] {
            p.pointee.codec_id = codec
            #expect(SoftwarePlaybackHost.audioPacketTiming(p)?.samples(byteCount: 371) == Int64(count))
        }
        p.pointee.codec_id = AV_CODEC_ID_AAC
        #expect(SoftwarePlaybackHost.audioPacketTiming(p) == nil)
        p.pointee.frame_size = 1024
        #expect(SoftwarePlaybackHost.audioPacketTiming(p)?.samples(byteCount: 371) == 1024)
        // Even a populated frame_size is not proof for arbitrary variable-frame codecs.
        for codec in [AV_CODEC_ID_FLAC, AV_CODEC_ID_OPUS, AV_CODEC_ID_DTS, AV_CODEC_ID_TRUEHD,
                      AV_CODEC_ID_WMAPRO, AV_CODEC_ID_WMALOSSLESS] {
            p.pointee.codec_id = codec
            #expect(SoftwarePlaybackHost.audioPacketTiming(p) == nil)
        }
    }

    @Test func wmaRequiresNonReservoirPacketLayout() throws {
        let p = try #require(avcodec_parameters_alloc())
        var allocated: UnsafeMutablePointer<AVCodecParameters>? = p
        defer { avcodec_parameters_free(&allocated) }
        // Borrowed bytes are detached before avcodec_parameters_free takes ownership.
        var extra: [UInt8] = [0, 0, 0, 0, 1, 0]
        extra.withUnsafeMutableBufferPointer { bytes in
            p.pointee.extradata = bytes.baseAddress
            p.pointee.extradata_size = 6
            defer { p.pointee.extradata = nil; p.pointee.extradata_size = 0 }
            p.pointee.codec_id = AV_CODEC_ID_WMAV2
            p.pointee.sample_rate = 44100
            p.pointee.ch_layout.nb_channels = 2
            p.pointee.block_align = 371
            p.pointee.bit_rate = 64000 // must never turn 2048 real samples into 2045 estimated ones
            #expect(SoftwarePlaybackHost.audioPacketTiming(p)?.samples(byteCount: 371) == 2048)
            #expect(SoftwarePlaybackHost.audioPacketTiming(p)?.samples(byteCount: 742) == nil)
            bytes[4] = 3
            #expect(SoftwarePlaybackHost.audioPacketTiming(p) == nil)
            bytes[4] = 1
            p.pointee.extradata_size = 0
            #expect(SoftwarePlaybackHost.audioPacketTiming(p) == nil)
        }
    }
}

extension SoftwarePacketTimingPolicyTests {
    @Test func pcmAndLowerRateMPEGGeometry() throws {
        var allocated = avcodec_parameters_alloc()
        let p = try #require(allocated)
        defer { avcodec_parameters_free(&allocated) }
        p.pointee.codec_id = AV_CODEC_ID_MP3
        p.pointee.sample_rate = 22050
        #expect(SoftwarePlaybackHost.audioPacketTiming(p)?.samples(byteCount: 100) == 576)
        p.pointee.codec_id = AV_CODEC_ID_PCM_S24LE
        p.pointee.sample_rate = 48000
        p.pointee.ch_layout.nb_channels = 6
        #expect(SoftwarePlaybackHost.audioPacketTiming(p)?.samples(byteCount: 1800) == 100)
        #expect(SoftwarePlaybackHost.audioPacketTiming(p)?.samples(byteCount: 1801) == nil)
        p.pointee.ch_layout.nb_channels = 0
        #expect(SoftwarePlaybackHost.audioPacketTiming(p) == nil)
        p.pointee.codec_id = AV_CODEC_ID_EAC3
        p.pointee.frame_size = 0
        #expect(SoftwarePlaybackHost.audioPacketTiming(p) == nil)
        p.pointee.frame_size = 1536
        #expect(SoftwarePlaybackHost.audioPacketTiming(p)?.samples(byteCount: 100) == 1536)
        p.pointee.sample_rate = 0
        #expect(SoftwarePlaybackHost.audioPacketTiming(p) == nil)
    }
}
