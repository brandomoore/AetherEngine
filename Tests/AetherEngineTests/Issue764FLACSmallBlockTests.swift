import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#764: CoreMedia's floor for a FLAC `STREAMINFO` `min_blocksize` is 192, not the spec's 16. An MKV whose
/// FLAC used fixed 144-sample blocks failed the native path with `-11829` / `-12848`, and the AE#221 clamp
/// had nothing to copy from because `max_blocksize` was 144 too. Measured on macOS 26: a field of 191 drops
/// the track even over real 4608-sample frames, and a field of 192 over real 144-sample frames hangs the
/// decoder, so such a stream is decoded by libavcodec instead of being copied.
@Suite("AE#764: FLAC blocks under CoreMedia's floor")
struct Issue764FLACSmallBlockTests {

    /// A FLAC codecpar whose extradata is a 34-byte STREAMINFO with the given block sizes.
    private static func withFLAC(
        min: UInt16, max: UInt16, length: Int = 34, codec: AVCodecID = AV_CODEC_ID_FLAC,
        _ body: (UnsafePointer<AVCodecParameters>) -> Void
    ) {
        guard let codecpar = avcodec_parameters_alloc() else {
            Issue.record("avcodec_parameters_alloc failed")
            return
        }
        defer {
            var p: UnsafeMutablePointer<AVCodecParameters>? = codecpar
            avcodec_parameters_free(&p)
        }
        var bytes = [UInt8](repeating: 0, count: length)
        if length >= 4 {
            bytes[0] = UInt8(min >> 8); bytes[1] = UInt8(min & 0xFF)
            bytes[2] = UInt8(max >> 8); bytes[3] = UInt8(max & 0xFF)
        }
        guard let buf = av_mallocz(length + Int(AV_INPUT_BUFFER_PADDING_SIZE))?
            .assumingMemoryBound(to: UInt8.self) else {
            Issue.record("av_mallocz failed")
            return
        }
        bytes.withUnsafeBufferPointer { if let base = $0.baseAddress { memcpy(buf, base, length) } }
        codecpar.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        codecpar.pointee.codec_id = codec
        codecpar.pointee.extradata = buf
        codecpar.pointee.extradata_size = Int32(length)
        body(UnsafePointer(codecpar))
    }

    @Test("the reporter's shape, min = max = 144, cannot be stream-copied")
    func reporterShapeBridges() {
        Self.withFLAC(min: 144, max: 144) { codecpar in
            #expect(FLACStreamInfo.coreMediaRejectsStreamCopy(codecpar))
            #expect(FLACStreamInfo.coreMediaRejectsSource(codecpar))
            #expect(MP4SegmentMuxer.sanitizedFLACExtradata(codecpar) == nil,
                    "a legal field is not the AE#221 clamp's to touch")
        }
    }

    @Test("191 is refused and 192 passes", arguments: [
        (UInt16(16), true), (UInt16(160), true), (UInt16(191), true),
        (UInt16(192), false), (UInt16(4608), false),
    ])
    func floorIs192(size: UInt16, rejected: Bool) {
        Self.withFLAC(min: size, max: size) { codecpar in
            #expect(FLACStreamInfo.coreMediaRejectsStreamCopy(codecpar) == rejected)
            #expect(FLACStreamInfo.coreMediaRejectsSource(codecpar) == rejected)
        }
    }

    @Test("a legal min under 192 bridges even when max is large: its small frames would hang the decoder")
    func variableBlocksizeWithSmallMinBridges() {
        Self.withFLAC(min: 144, max: 4608) { codecpar in
            #expect(FLACStreamInfo.coreMediaRejectsStreamCopy(codecpar))
        }
    }

    @Test("a zeroed min over a legal max keeps the AE#221 clamp and stays a stream copy")
    func zeroedMinStillClamps() {
        Self.withFLAC(min: 0, max: 4608) { codecpar in
            #expect(!FLACStreamInfo.coreMediaRejectsStreamCopy(codecpar))
            #expect(FLACStreamInfo.coreMediaRejectsSource(codecpar),
                    "audio-only hands AVPlayer the unrepaired source")
            #expect(MP4SegmentMuxer.sanitizedFLACExtradata(codecpar).flatMap { FLACStreamInfo.blockSizes($0) }?.min == 4608)
        }
    }

    @Test("a zeroed min over a max under 192 bridges", arguments: [UInt16(0), UInt16(144)])
    func clampTargetBelowFloorBridges(max: UInt16) {
        Self.withFLAC(min: 0, max: max) { codecpar in
            #expect(FLACStreamInfo.coreMediaRejectsStreamCopy(codecpar))
        }
    }

    @Test("no STREAMINFO to read keeps the route")
    func unreadableHeaderKeepsRoute() {
        Self.withFLAC(min: 144, max: 144, length: 33) { codecpar in
            #expect(!FLACStreamInfo.coreMediaRejectsStreamCopy(codecpar))
            #expect(!FLACStreamInfo.coreMediaRejectsSource(codecpar))
        }
        Self.withFLAC(min: 144, max: 144, codec: AV_CODEC_ID_ALAC) { codecpar in
            #expect(!FLACStreamInfo.coreMediaRejectsStreamCopy(codecpar))
        }
    }

    @Test("the fallback packet duration takes a fixed block size from STREAMINFO")
    func fixedBlockSize() {
        Self.withFLAC(min: 4608, max: 4608) { #expect(FLACStreamInfo.fixedBlockSize($0) == 4608) }
        Self.withFLAC(min: 192, max: 192) { #expect(FLACStreamInfo.fixedBlockSize($0) == 192) }
        Self.withFLAC(min: 0, max: 4608) { #expect(FLACStreamInfo.fixedBlockSize($0) == nil) }
        Self.withFLAC(min: 192, max: 4608) { #expect(FLACStreamInfo.fixedBlockSize($0) == nil) }
    }
}
