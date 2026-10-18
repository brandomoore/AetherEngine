import Foundation

/// Where a live session on the software host starts playing, once what the source sends at connect
/// has landed.
///
/// A continuous live stream over HTTP (an IPTV panel's MPEG-TS form of a channel) opens with a burst:
/// the panel sends what it holds of the channel, 8 to 18 s of media measured on one panel, at link
/// speed, and real time after that. The feeder used to arm the clock on the first packet of that
/// burst, and since nothing on the software path ever catches up, the picture then ran the whole
/// burst behind the broadcast for as long as the channel played: 17 s on a channel whose native-path
/// session, which AVPlayer places a holdback behind the newest segment, ran 6 s behind. For live
/// sport that is the difference other players are judged by.
///
/// So a live join on the software host waits for the burst to land, then starts `leadSeconds` behind
/// the newest media, on the keyframe at or before that moment. The burst is landed when the ring has
/// grown no faster than real time over `calmWindowSeconds` (a source that delivers in real time is
/// calm from its first packets and starts after `minimumSettleSeconds`), or after
/// `maximumSettleSeconds` on a link that is still catching up, where the start takes what has
/// arrived. A ring holding less than `leadSeconds + minimumSkipSeconds` is played from its start:
/// there is nothing worth skipping. The media behind the start stays in the rewind ring.
///
/// Pure, so the rule is testable without a session; `SoftwarePlaybackHost` feeds it the ring's
/// first and newest PTS from the feeder thread until it decides.
struct SoftwareLiveJoinPolicy: Equatable {
    /// How far behind the newest media the picture starts. The audio pump keeps this much decoded
    /// audio ahead of the clock (`AudioLookaheadPolicy.targetLeadSeconds`), and a panel that hands
    /// over about a second of media at a time leaves the lead swinging within it.
    static let leadSeconds: Double = 4
    /// The burst is given at least this long to begin landing before the ring's growth is judged.
    static let minimumSettleSeconds: TimeInterval = 0.3
    /// After this long the start takes what has arrived, calm or not.
    static let maximumSettleSeconds: TimeInterval = 1.5
    /// Growth is judged over windows this long.
    static let calmWindowSeconds: TimeInterval = 0.25
    /// A ring that grew by more than this multiple of the wall clock over a window is still landing
    /// the burst.
    static let calmGrowthRatio: Double = 1.5
    /// A start is moved only when it skips at least this much; less is not worth a later keyframe.
    static let minimumSkipSeconds: Double = 2

    enum Decision: Equatable {
        /// Play from the ring's first packet.
        case fromStart
        /// Start on the keyframe at or before this source PTS.
        case place(targetPts: Double)
    }

    private var firstObservedAt: TimeInterval?
    private var windowStartPts: Double?
    private var windowStartAt: TimeInterval?

    /// Notes the ring's first and newest PTS at `now` (seconds on any monotonic clock); nil while the
    /// burst is still landing, then the decision, once.
    mutating func observe(firstPts: Double, newestPts: Double, at now: TimeInterval) -> Decision? {
        guard let firstObservedAt, let windowStartPts, let windowStartAt else {
            self.firstObservedAt = now
            self.windowStartPts = newestPts
            self.windowStartAt = now
            return nil
        }
        let elapsed = now - firstObservedAt
        var settled = elapsed >= Self.maximumSettleSeconds
        if !settled, elapsed >= Self.minimumSettleSeconds, now - windowStartAt >= Self.calmWindowSeconds {
            let grew = newestPts - windowStartPts
            let wall = now - windowStartAt
            if grew <= wall * Self.calmGrowthRatio {
                settled = true
            } else {
                self.windowStartPts = newestPts
                self.windowStartAt = now
            }
        }
        guard settled else { return nil }
        let span = newestPts - firstPts
        guard span.isFinite, span >= Self.leadSeconds + Self.minimumSkipSeconds else { return .fromStart }
        return .place(targetPts: newestPts - Self.leadSeconds)
    }
}
