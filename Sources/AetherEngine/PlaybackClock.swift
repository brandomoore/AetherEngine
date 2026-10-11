import Foundation
import Combine

/// High-frequency playback clock split out of `AetherEngine`'s `ObservableObject` surface (AetherEngine#29). Before the split, every ~10 Hz tick fired `engine.objectWillChange`, causing ALL observing SwiftUI views to re-render -- on tvOS that rebuilt native `Menu` dropdowns and flickered the focus highlight.
///
/// Host usage: time-driven UI (transport bar, labels) observes `engine.clock` directly and applies `.throttle` / `.removeDuplicates`; everything else (menus, pickers) observes the engine and stays quiet.
@MainActor
public final class PlaybackClock: ObservableObject {

    /// ~10 Hz. On native HLS: unified source-PTS clock (AVPlayer time folded with `playlistShiftSeconds`).
    @Published public internal(set) var currentTime: Double = 0

    /// Source PTS of the currently displayed frame. On native: rides AVPlayer's rendered position -- equals `currentTime` in steady play, but holds the on-screen frame during a seek or rebuffer, not the scrub target (issue #49). SW/audio: always equals `currentTime`.
    ///
    /// `nativeRemoteHLS` (AE#616): item time, less the lead over the picture the engine measured on its
    /// own injected subtitle renditions (#316). The lead exists where an origin restarts a transcode at the
    /// keyframe before a segment's slot, and is re-measured on every presented line, so it differs from
    /// `currentTime` by that lead. With no injected rendition selected there is nothing to measure it
    /// against, and this is item time, which can run ahead of the frame after a seek on such an origin.
    @Published public internal(set) var sourceTime: Double = 0

    /// Whether `sourceTime` is known to follow the displayed frame. True on every route but
    /// `nativeRemoteHLS`. There (AE#616) it turns true when a presented line of an injected rendition
    /// measured the lead, and false again at every time jump (seek, item change): until the next line,
    /// `sourceTime` carries the previous lead, which is off by however far the new anchor moved. False
    /// for the whole session without an injected rendition selected. A host timing its own overlay off
    /// `sourceTime` can hold it while this is false instead of detecting seeks itself.
    @Published public internal(set) var sourceTimeFollowsPicture: Bool = true

    @Published public internal(set) var progress: Float = 0

    /// Largest session-relative time reached on a live source. 0 when not live.
    @Published public internal(set) var liveEdgeTime: Double = 0

    /// DVR-seekable span on the session timeline. nil when DVR is disabled or not live.
    @Published public internal(set) var seekableLiveRange: ClosedRange<Double>? = nil

    @Published public internal(set) var isAtLiveEdge: Bool = false

    /// Seconds behind the live edge. 0 at the edge.
    @Published public internal(set) var behindLiveSeconds: Double = 0

    /// Source-axis buffer frontier (AetherEngine#54): the end of the contiguous *safe* range ahead of the
    /// playhead, i.e. what is guaranteed available without another fetch. Same axis as `sourceTime`; draw
    /// as `bufferedPosition / duration`. Clamped to never trail the rendered frame.
    ///
    /// - Native: what AVPlayer already holds, plus the contiguous disk SegmentCache band above it (#105,
    ///   #207 follow-up). Grows with the Network Buffer setting, unlike AVPlayer's `loadedTimeRanges`
    ///   alone, which stays pinned by `preferredForwardBufferDuration`.
    /// - Software: newest demuxed source PTS.
    /// - Audio: mirrors `currentTime` (no buffer-ahead surface).
    @Published public internal(set) var bufferedPosition: Double = 0
}
