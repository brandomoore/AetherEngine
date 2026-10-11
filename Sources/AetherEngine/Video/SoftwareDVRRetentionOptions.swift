import Foundation

/// Opt-in storage bounds for a software live session, selected before its spool opens.
/// Runtime capacity leases may authorize more history. When a lease expires, the
/// spool falls back to the caller's small playback cushion without reopening the source.
public struct SoftwareDVRRetentionOptions: Equatable, Sendable {
    public let startupMaximumBytes: Int
    public let playbackCushionBytes: Int
    public let playbackCushionSeconds: Double

    public init(startupMaximumBytes: Int, playbackCushionBytes: Int, playbackCushionSeconds: Double) {
        self.startupMaximumBytes = max(1, startupMaximumBytes)
        self.playbackCushionBytes = max(1, playbackCushionBytes)
        self.playbackCushionSeconds = playbackCushionSeconds.isFinite
            ? max(0, playbackCushionSeconds) : 0
    }
}
