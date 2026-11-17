import Foundation
import AetherLibavutil

/// AE#464: where a host's audio-delay nudge lands, per video route.
///
/// Audio/video timing errors can come from the file or the viewer's equipment. The engine honours
/// the host's correction for the life of the session. AVFoundation offers no audio-delay
/// control on either surface a host can reach (`AVPlayerItem` has none, and an HLS-streamed asset
/// vends no `AVAssetTrack` to bind an `AVAudioMix` to), so the offset has to be applied where the
/// engine still holds the timestamps. That is a different place on each route, and on both of them
/// it is the LAST place rather than the obvious one:
///
/// - `.software`: the decoded sample's stamped PTS, downstream of `AudioClockAnchor`. Applying it to
///   the container PTS upstream instead would feed the gapless predictor an offset it treats as
///   ordinary rounding jitter, so any nudge below its 100 ms discontinuity threshold would vanish
///   without a trace, and the clock-arming decision (`SWClockAnchorPolicy`) would move with it.
/// - `.loopback`: the audio timestamps written into the fMP4 segments. Segments already cut carry
///   the old offset, and the two are not splicable: at the seam the audio track gains a gap or an
///   overlap of exactly the change, and a change that moves audio EARLIER walks into
///   `OutputTimestampSanitizer`'s strictly-increasing-DTS rule, which clamps it away entirely. A new
///   value is therefore a new muxer, which is a re-cut at the playhead.
///
/// In both cases the offset moves AUDIO and never the stream the session reports its position on, so
/// `currentTime`, seeking and the subtitle axis are untouched by a nudge.
enum AudioDelayPolicy {

    /// Largest offset the engine carries, either direction, in seconds.
    static let maxAbsSeconds: Double = 10.0

    /// Coverage around the currently audible source time used to advertise live PCM adjustment.
    /// Wider requested changes still have to pass the replay buffer's exact coverage check.
    static let liveAdjustmentRadiusSeconds: Double = 2.0

    /// Delayed audio must be retained from before the video seam, not discarded by its restart gate.
    static func prerollStartPts(_ videoStart: Int64, timeBase: AVRational, delaySeconds: Double) -> Int64 {
        let ticks = MP4SegmentMuxer.audioDelayTicks(
            seconds: max(0, clamp(delaySeconds)), audioTimeBase: timeBase)
        return SourceTimestampBounds.difference(videoStart, ticks)
    }

    /// Reserve compressed video headroom only when audio must be read ahead of video.
    /// Keep the ordinary queue limit, with an absolute packet cap for malformed frame-rate metadata.
    static func parkedVideoLimit(audioAdvance: Double, frameRate: Double?) -> Int {
        let advance = max(0, clamp(audioAdvance))
        let fps = frameRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 60
        return Int(min(4096, 256 + ceil(advance * max(60, fps))))
    }

    /// Bring a host value into range. A non-finite value (NaN from an unset stepper, an infinity out
    /// of a division) becomes 0 rather than propagating into a timestamp.
    static func clamp(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return min(max(seconds, -maxAbsSeconds), maxAbsSeconds)
    }

    /// True when `seconds` had to be brought in, i.e. the host asked for something the engine will
    /// not carry. Worth a log line: the delivered offset is not the one that was set.
    static func isOutOfRange(_ seconds: Double) -> Bool {
        !seconds.isFinite || abs(seconds) > maxAbsSeconds
    }

    /// Where the offset is applied on a given route.
    enum Application: Equatable {
        /// Stamped onto decoded audio samples as they are handed to the renderer. Takes effect as
        /// soon as the renderer's queue is flushed, with no re-cut and no rebuild.
        case sampleTimestamps
        /// Written into the fMP4 segments the local server feeds AVPlayer. A change is only clean
        /// across a re-cut at the playhead, so applying one costs a producer restart.
        case segmentTimestamps
        /// The engine does not hold this session's audio timestamps, so it cannot move them.
        case unavailable
    }

    static func application(for route: VideoRoute) -> Application {
        switch route {
        case .software: return .sampleTimestamps
        case .loopback: return .segmentTimestamps
        // AVPlayer owns the whole media selection; the engine never sees the timestamps (`.remoteBypass`),
        // or there is no video for audio to be early or late against (`.audio`, `.none`).
        case .remoteBypass, .audio, .none: return .unavailable
        }
    }

    /// Whether applying `new` in place of `current` needs anything done at all. Setting the value
    /// already in force is not a re-cut, which matters on `.loopback` where it would otherwise cost
    /// a visible rebuffer per redundant call.
    static func isChange(from current: Double, to new: Double) -> Bool {
        current != new
    }
}
