import Foundation

/// Where the SW demux loop anchors the synchronizer clock when the first decoded
/// sample arrives (#107).
///
/// Normal files and resumes deliver their first sample at (or within head-of-stream
/// offset of) the load-time anchor, so the anchor is kept verbatim and intrinsic
/// A/V lead-in offsets survive untouched. A mid-stream-joined source (live tuner
/// MPEG-TS opened without `isLive`, live without a DVR ring, or a capture file cut
/// mid-broadcast) delivers first samples hours past the anchor; anchoring at the
/// sample PTS is the only way they ever present. `sessionZeroSeconds` is the offset
/// the host subtracts from the raw synchronizer clock so the published position
/// stays session-relative; the raw clock itself remains the source/subtitle axis.
///
/// Only a sample AHEAD of the anchor moves it (AE#724). A resume repositions to the keyframe at or
/// before its target, so its first audio arrives up to a whole GOP early (9.984 s for a 17.3 s
/// resume on a 10 s GOP); the video skip threshold and the synchronizer discard that preroll, and
/// a clock moved back onto it published the viewer seconds behind the resume point.
enum SWClockAnchorPolicy {
    /// Tolerance below which the first sample is considered aligned with the load
    /// anchor. Head-of-stream offsets are a few hundred ms; mid-stream joins are
    /// minutes to hours. Seconds.
    static let toleranceSeconds: Double = 2.0

    struct Resolution: Equatable {
        let anchorSeconds: Double
        let sessionZeroSeconds: Double
    }

    static func resolve(initialSeconds: Double,
                        firstSampleSeconds: Double,
                        toleranceSeconds: Double = SWClockAnchorPolicy.toleranceSeconds) -> Resolution {
        guard firstSampleSeconds.isFinite,
              firstSampleSeconds - initialSeconds > toleranceSeconds else {
            return Resolution(anchorSeconds: initialSeconds, sessionZeroSeconds: 0)
        }
        return Resolution(anchorSeconds: firstSampleSeconds,
                          sessionZeroSeconds: max(0, firstSampleSeconds - initialSeconds))
    }

    /// The session zero a resume establishes before any sample arrives (AE#724).
    ///
    /// `load(startPosition:)` is a session-axis position like any seek, but on a cold start the
    /// session zero only exists once `resolve` has seen the first sample. A resume has to cross
    /// the axes before that, or its target reaches the demuxer unconverted: on a source whose
    /// timestamps start at 600 s, 17.3 is a position before the first packet, the read lands on
    /// the head, and the clock publishes 17.3 over content from 0. The origin counts on the same
    /// terms as on a cold start, so a source starting within the tolerance stays zero-based.
    static func resumeSessionZero(sourceOriginSeconds: Double,
                                  toleranceSeconds: Double = SWClockAnchorPolicy.toleranceSeconds) -> Double {
        guard sourceOriginSeconds.isFinite, sourceOriginSeconds > toleranceSeconds else { return 0 }
        return sourceOriginSeconds
    }

    /// Converts a session-axis position into the source axis.
    ///
    /// The host publishes positions session-relative (`raw - sessionZero`), but the
    /// demuxer, the packet store, the decoder's skip threshold and the synchronizer
    /// clock all speak the source's own timestamps. A seek arrives on the session
    /// axis and has to be carried back over before it reaches any of them; for a
    /// zero-based source the two axes coincide and this is the identity.
    ///
    /// Without it, a mid-stream-joined source seeks to a timestamp that lies before
    /// its own first packet (which the demuxer clamps to the start of the file),
    /// and the packet store's reservoir, measured as `storedPacketSeconds - clock`,
    /// reads as the whole offset. On a capture whose first PTS is six hours in, the
    /// producer sees six hours of buffer, stops reading, and the consumer starves
    /// with nothing to report.
    static func sourceSeconds(forSession seconds: Double, sessionZeroSeconds: Double) -> Double {
        guard seconds.isFinite, sessionZeroSeconds.isFinite, sessionZeroSeconds > 0 else {
            return seconds
        }
        return seconds + sessionZeroSeconds
    }

    /// Whether a video packet parked on renderer back-pressure has to anchor the clock itself
    /// (#337).
    ///
    /// Both feed loops gate video on `renderer.isReadyForMoreMediaData`, and the renderer only
    /// drains while the synchronizer clock runs, so a park entered with an unarmed clock cannot
    /// end on its own: the combined demux loop is the single reader, and every packet that could
    /// arm the clock is behind the park; the live feeder has a second reader, but once its
    /// look-ahead pump has spent its pre-arm budget nothing else will deliver a first buffer
    /// either. The cycle closes whenever the selected audio stream's first packet lies past the
    /// renderer's fill point (a track grouped late in the mux, or one the host switched to at
    /// start-from-zero), and the session then publishes `.playing` at a frozen clock until a seek
    /// arms it by hand. Anchoring on the video the renderer is already holding is the only exit
    /// that needs nothing from the host.
    static func shouldArmFromParkedVideo(clockArmed: Bool,
                                         isPlaying: Bool,
                                         rendererReadyForMoreData: Bool,
                                         audioArmingStillPossible: Bool) -> Bool {
        guard !clockArmed, isPlaying, !rendererReadyForMoreData else { return false }
        return !audioArmingStillPossible
    }
}
