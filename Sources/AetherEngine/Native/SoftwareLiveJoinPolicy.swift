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
    /// burst is still landing, then the decision, once. `leadSeconds` is the source's join lead,
    /// `SoftwareLiveHoldback.joinLeadSeconds` (AE#813). `minimumSpanSeconds` is a host's
    /// `liveEdgeCushionSeconds`: a settled ring shallower than that keeps waiting, at 1x on a realtime
    /// source, for at most `maximumSettleSeconds` plus the cushion, and then starts on what it holds.
    mutating func observe(firstPts: Double, newestPts: Double, at now: TimeInterval,
                          leadSeconds: Double = Self.leadSeconds,
                          minimumSpanSeconds: Double? = nil) -> Decision? {
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
        if let minimum = minimumSpanSeconds, !(span >= minimum),
           elapsed < Self.maximumSettleSeconds + minimum {
            return nil
        }
        guard span.isFinite, span >= leadSeconds + Self.minimumSkipSeconds else { return .fromStart }
        return .place(targetPts: newestPts - leadSeconds)
    }
}

/// AE#813: how far behind the newest media a software live session holds, from the unit its source
/// delivers in.
///
/// `SoftwareLiveJoinPolicy.leadSeconds` suits a continuous TS panel that hands over about a second at
/// a time. A live HLS ingest hands over a whole segment at a time, so on 10 s segments a 4 s lead ran
/// dry before the next segment landed: measured on an iPhone, `live source underrun` once per segment,
/// the audio lead falling 4 -> 3 -> 2 -> 1 -> 0 between them. The rebuffer then resumed at
/// `AudioLookaheadPolicy.rebufferResumeLeadSeconds` of audio, which the late segment supplies the
/// moment it lands, so the playhead never gained a cushion and the stall repeated on every segment.
///
/// So where the unit is known, the session holds one and a half units plus a second behind the newest
/// media (the ingest joins with the same `1.5 x` cover for the same reason), a rebuffer resumes only
/// once more than a unit stands ahead of the clock, a landing near the frontier is held back as far as
/// a join, and the live-edge verdict counts that distance plus one unit as the edge. A continuous source has no unit
/// and keeps every value it had before.
struct SoftwareLiveHoldback: Equatable, Sendable {
    /// Seconds of media the source delivers at once, nil for a continuous source.
    let deliveryUnitSeconds: Double?
    /// `LoadOptions.liveEdgeCushionSeconds`, validated: a floor under the join lead, the landing
    /// holdback and the rebuffer resume cushion, on a continuous source as on a segmented one.
    let edgeCushionSeconds: Double?

    static let continuous = SoftwareLiveHoldback(deliveryUnitSeconds: nil)

    /// Upper bound on the join lead, whatever the unit.
    static let maximumLeadSeconds: Double = 45
    /// Margin over one unit before a rebuffer resumes.
    static let resumeSlackSeconds: Double = 2

    init(deliveryUnitSeconds: Double?, edgeCushionSeconds: Double? = nil) {
        if let unit = deliveryUnitSeconds, unit.isFinite, unit > 0 {
            self.deliveryUnitSeconds = unit
        } else {
            self.deliveryUnitSeconds = nil
        }
        self.edgeCushionSeconds = LiveEdgePolicy.edgeCushion(edgeCushionSeconds)
    }

    /// Where a join starts behind the newest media: 4 s for a continuous source, 4 s on 2 s segments,
    /// 10 s on 6 s segments, 16 s on 10 s segments.
    var joinLeadSeconds: Double {
        let own = deliveryUnitSeconds.map {
            Swift.min(Swift.max(SoftwareLiveJoinPolicy.leadSeconds, 1.5 * $0 + 1), Self.maximumLeadSeconds)
        } ?? SoftwareLiveJoinPolicy.leadSeconds
        return Swift.max(own, edgeCushionSeconds ?? 0)
    }

    /// How far behind the frontier a seek is held at least (Sodalite#104 round 3).
    var landingHoldbackSeconds: Double {
        deliveryUnitSeconds == nil && edgeCushionSeconds == nil
            ? AudioLookaheadPolicy.rebufferResumeLeadSeconds : joinLeadSeconds
    }

    /// Media that has to stand ahead of the clock before a rebuffer resumes, nil when the audio lead
    /// alone decides (a continuous source).
    var resumeCushionSeconds: Double? {
        let own = deliveryUnitSeconds.map { Swift.min($0 + Self.resumeSlackSeconds, joinLeadSeconds) }
        return [own, edgeCushionSeconds].compactMap { $0 }.max()
    }

    /// The distance behind the frontier the live-edge verdict counts as the edge, nil for a
    /// continuous source. One unit more than the lead: the lead is measured from the newest media at
    /// the moment of placement, and the next segment can land right after it, so a session holding
    /// the lead sits anywhere up to `lead + unit` behind (measured: 25.5 s after a landing at 17 s on
    /// 10 s segments).
    var edgeHoldbackSeconds: Double? {
        if let unit = deliveryUnitSeconds { return joinLeadSeconds + unit }
        return edgeCushionSeconds == nil ? nil : joinLeadSeconds
    }

    /// The unit a live ingest delivers in: the longest segment it served or the longest gap it has
    /// closed between arrivals, whichever is larger. nil until either is known.
    static func deliveryUnit(segmentDuration: Double?, closedCadence: Double?) -> Double? {
        let known = [segmentDuration, closedCadence].compactMap { $0 }.filter { $0.isFinite && $0 > 0 }
        return known.max()
    }
}
