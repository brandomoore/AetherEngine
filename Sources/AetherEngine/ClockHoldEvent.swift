import Foundation

/// The software path's clock hold (#800): after a start, a seek, an in-place switch or a resume, the
/// clock stands at rate 0 on its new position until the decoder has frames from there on in the layer,
/// and only then starts. A host that judges playback from the clock reads that hold as a stall unless it
/// knows about it; this is how it knows, per engine instance, without reading `EngineLog`.
///
/// Contract:
///
/// - Every `.began` is followed by exactly one `.released`. A hold that is still waiting when a newer
///   seek, a pause, a rate change or the end of the session takes over is released as `.cancelled`
///   first, so `.began` never nests.
/// - `.ready` and `.timedOut` carry how long the clock stood. The clock starts `0.25` s after either,
///   at the position it was held on.
/// - Only the software host holds. The AVPlayer paths, the audio-only host and live streams off the
///   Dolby Vision FEL route never emit; neither does a start whose frames are already in the layer.
///
/// Events are published on the main actor, in emission order. `AetherEngine.isClockHeld` is the level.
public enum ClockHoldEvent: Sendable, Equatable {
    case began
    case released(ClockHoldRelease)
}

/// How a clock hold ended (`ClockHoldEvent.released`).
public enum ClockHoldRelease: Sendable, Equatable {
    /// The frames from the held position on are in the layer.
    case ready(waitedSeconds: Double)
    /// The decoder produced nothing for 2 s, or kept producing without reaching the position for 6 s.
    /// The clock starts anyway, so the first frames after it can arrive late.
    case timedOut(waitedSeconds: Double)
    /// A seek, pause, rate change or the end of the session took over before the hold ended.
    case cancelled
}
