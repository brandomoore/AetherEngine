import Foundation
import AetherLibavcodec
import AetherLibavutil

/// What the segment producer and the engine need from an audio bridge: source packets in,
/// fMP4-legal packets out, plus the restart/EOF/diagnostic surface the producer lifecycle drives.
///
/// Two implementations. `AudioBridge` is libavcodec end to end (decode, resample, E-AC-3 or FLAC).
/// `SpatialAudioBridge` renders TrueHD Atmos objects into a speaker bed and encodes it as APAC,
/// which libavcodec cannot encode or mux, so it also supplies the sample entry the muxer writes.
protocol AudioTranscodingBridge: AnyObject, Sendable {
    /// Parameters of the stream the muxer's audio track is built from. For a bridge that sets
    /// `soundSampleEntryOverride`, these describe a stand-in movenc can write, not the real codec.
    var encoderCodecpar: UnsafeMutablePointer<AVCodecParameters>? { get }
    var encoderTimeBase: AVRational { get }

    /// A complete sample entry box that replaces the one movenc writes for the audio track, or nil
    /// to keep movenc's.
    var soundSampleEntryOverride: Data? { get }

    /// Channels the delivered track really carries, for the master's `CHANNELS`, when the muxer's
    /// codec parameters describe a stand-in instead (the APAC bed behind a 2-channel ALAC stand-in).
    /// Nil reads the count off `encoderCodecpar`.
    var servedChannelCount: Int? { get }

    /// Decode, transcode and return 0+ packets in `encoderTimeBase`. The caller owns them and frees
    /// them with `trackedPacketFree` after muxing.
    func feed(packet: UnsafePointer<AVPacket>) throws -> [UnsafeMutablePointer<AVPacket>]
    /// Packets for audio already fed that the bridge is still encoding, waited for. The producer
    /// calls it before cutting a segment, so a cut splits the audio where a synchronous encode would.
    func settle() -> [UnsafeMutablePointer<AVPacket>]
    /// Drain at source EOF. The bridge is unusable afterwards until `startSegment`.
    func flush() -> [UnsafeMutablePointer<AVPacket>]
    /// A producer restart boundary: drop buffered audio and rebase timestamps off the next packet.
    func startSegment()
    /// Live splice gap correction, in seconds.
    func noteTimelineJump(deltaSeconds: Double)
    func close()

    var feedStats: AudioBridge.FeedStats { get }
    var liveBytes: AudioBridge.LiveBytes { get }
    var fifoSampleCount: Int { get }
    var outputBytesLifetime: Int64 { get }
}

extension AudioBridge: AudioTranscodingBridge {
    var soundSampleEntryOverride: Data? { nil }
    var servedChannelCount: Int? { nil }
    func settle() -> [UnsafeMutablePointer<AVPacket>] { [] }
}
