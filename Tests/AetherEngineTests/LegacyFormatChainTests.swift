import Testing
import AetherLibavcodec
import AetherLibavformat
@testable import AetherEngine

/// RealMedia, feature-phone 3GP, Theora and VobSub, which become whole with FFmpegBuild 3.8.0.
///
/// Same rule as the WMA and Flash chains: a container is whole or it is nothing. `.rmvb` is RV40 with
/// Cook, a 3GP is H.263 with AMR, an `.ogv` is Theora with Vorbis, and every audio codec the container
/// can carry is named here rather than the one a typical file has, because a missing audio decoder
/// plays the file silently instead of failing it.
@Suite("Legacy format chains (RealMedia, 3GP, Theora, VobSub)")
struct LegacyFormatChainTests {

    /// RealAudio routes as one family, AMR as another; DVD LPCM is a raw PCM shape like Blu-ray's.
    private static let audio: [(String, AVCodecID, HLSVideoEngine.AudioCodecCompat)] = [
        ("cook", AV_CODEC_ID_COOK, .realAudio),
        ("atrac3", AV_CODEC_ID_ATRAC3, .realAudio),
        ("sipr", AV_CODEC_ID_SIPR, .realAudio),
        ("ralf", AV_CODEC_ID_RALF, .realAudio),
        ("ra_144", AV_CODEC_ID_RA_144, .realAudio),
        ("ra_288", AV_CODEC_ID_RA_288, .realAudio),
        ("amr_nb", AV_CODEC_ID_AMR_NB, .amr),
        ("amr_wb", AV_CODEC_ID_AMR_WB, .amr),
        ("pcm_dvd", AV_CODEC_ID_PCM_DVD, .pcm),
    ]

    /// None of these is on the native allowlist, so all of them reach `SoftwareVideoDecoder`.
    private static let video: [(String, AVCodecID)] = [
        ("rv10", AV_CODEC_ID_RV10),
        ("rv20", AV_CODEC_ID_RV20),
        ("rv30", AV_CODEC_ID_RV30),
        ("rv40", AV_CODEC_ID_RV40),
        ("h263", AV_CODEC_ID_H263),
        ("theora", AV_CODEC_ID_THEORA),
    ]

    @Test("every audio codec of these containers bridges instead of dropping to video-only")
    func everyAudioCodecBridges() {
        for (name, id, expected) in Self.audio {
            let compat = HLSVideoEngine.AudioCodecCompat.from(id)
            #expect(compat == expected, "\(name) routes as \(compat), not \(expected)")
            #expect(compat.requiresBridge, "\(name) would try to stream-copy into fMP4")
            #expect(compat.hlsCodecsString.isEmpty,
                    "\(name) is bridged, so the master playlist takes its CODECS from the encoder")
        }
    }

    @Test("the linked libavcodec carries every audio decoder the table routes")
    func everyAudioDecoderIsLinked() {
        for (name, id, _) in Self.audio {
            #expect(avcodec_find_decoder(id) != nil,
                    "\(name) is routed but absent from the linked FFmpeg build: those files play silently")
        }
    }

    @Test("the linked libavcodec carries the video decoders")
    func everyVideoDecoderIsLinked() {
        for (name, id) in Self.video {
            #expect(avcodec_find_decoder(id) != nil, "\(name) missing: the software path fails the load")
        }
    }

    @Test("the rm and vobsub demuxers open the containers the decoders serve")
    func theContainersOpen() {
        #expect(av_find_input_format("rm") != nil, "rm demuxer missing: no .rm / .rmvb opens at all")
        #expect(av_find_input_format("vobsub") != nil, "vobsub demuxer missing: no .idx + .sub sidecar opens")
        #expect(avcodec_find_decoder(AV_CODEC_ID_DVD_SUBTITLE) != nil, "dvdsub missing: VobSub cues cannot decode")
    }
}
