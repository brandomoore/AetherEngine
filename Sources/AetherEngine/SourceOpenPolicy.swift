import Foundation

/// HTTP VOD startup policy. These budgets bound the initial data wait and the entire fallback
/// recovery respectively, not decoding, seeking, or the lifetime of playback. An unanswered
/// data request retries once within `sizeProbeTimeout`, retaining the recovered body. If neither
/// request answers, opening fails instead of classifying the source as forward-only. Size-only
/// discovery remains available for responses that actually arrive without a usable length.
public struct SourceOpenPolicy: Sendable, Equatable {
    public let firstByteTimeout: TimeInterval
    public let sizeProbeTimeout: TimeInterval

    /// Shorter budgets reach an alternate request shape sooner, but can abandon a slow healthy
    /// request. Nonfinite/nonpositive values use the defaults; values above 120 seconds are capped.
    public init(firstByteTimeout: TimeInterval = 15, sizeProbeTimeout: TimeInterval = 25) {
        self.firstByteTimeout = Self.normalized(firstByteTimeout, fallback: 15)
        self.sizeProbeTimeout = Self.normalized(sizeProbeTimeout, fallback: 25)
    }

    private static func normalized(_ value: TimeInterval, fallback: TimeInterval) -> TimeInterval {
        value.isFinite && value > 0 ? min(120, value) : fallback
    }
}
