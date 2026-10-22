import Testing
import Foundation
@testable import AetherEngine

/// `LoadOptions.liveEdgeCushionSeconds`: a host asks a live session to play further behind the edge,
/// the buffer a viewer on a slow or unsteady link has against the channel.
@Suite("A host's live edge cushion moves every live path further back, never closer")
struct LiveEdgeCushionTests {

    // MARK: - Validation

    @Test("only a finite positive cushion counts, clamped to the ceiling",
          arguments: [(nil, nil), (0, nil), (-3, nil), (.nan, nil), (.infinity, nil),
                      (30, 30), (90, 45)] as [(Double?, Double?)])
    func validation(requested: Double?, used: Double?) {
        #expect(LiveEdgePolicy.edgeCushion(requested) == used)
    }

    // MARK: - Loopback

    @Test("the served holdback is the deeper of the RFC floor and the cushion")
    func holdbackFloor() {
        #expect(LiveEdgePolicy.holdBackSeconds(targetDuration: 2, edgeCushionSeconds: nil) == 6)
        #expect(LiveEdgePolicy.holdBackSeconds(targetDuration: 2, edgeCushionSeconds: 30) == 30)
        // A shallow cushion cannot buy back the stall-danger zone AE#189 closed.
        #expect(LiveEdgePolicy.holdBackSeconds(targetDuration: 6, edgeCushionSeconds: 10) == 18)
    }

    @Test("the first serve waits for the cushion, unless the window is full")
    func firstServeGate() {
        func satisfied(_ summed: Double, count: Int = 10, window: Int = 100) -> Bool {
            LiveEdgePolicy.startupCushionSatisfied(segmentCount: count, summedDurationSeconds: summed,
                                                   targetDuration: 2, windowSegmentCount: window,
                                                   edgeCushionSeconds: 30)
        }
        #expect(!satisfied(20))
        #expect(satisfied(30))
        #expect(satisfied(20, count: 10, window: 10))
    }

    @Test("the window holds the cushion plus its margin")
    func windowRoom() {
        let plain = LiveWindowSizing(targetSegmentDurationSeconds: 1, dvrWindowSeconds: 10)
        var cushioned = plain
        cushioned.edgeCushionSeconds = 30
        #expect(plain.requestedSegmentCount(observedSegmentDurationSeconds: 1) == 10)
        #expect(cushioned.requestedSegmentCount(observedSegmentDurationSeconds: 1)
                == Int(30 + LiveWindowSizing.edgeCushionWindowMarginSeconds))
        // A deeper DVR window is left alone.
        var deep = LiveWindowSizing(targetSegmentDurationSeconds: 1, dvrWindowSeconds: 600)
        deep.edgeCushionSeconds = 30
        #expect(deep.requestedSegmentCount(observedSegmentDurationSeconds: 1) == 600)
    }

    @Test("the first-serve deadline outlasts the cushion it waits for")
    func firstServeDeadline() {
        #expect(LiveEdgePolicy.firstServeTimeoutSeconds(edgeCushionSeconds: nil) == 30)
        #expect(LiveEdgePolicy.firstServeTimeoutSeconds(edgeCushionSeconds: 10) == 30)
        #expect(LiveEdgePolicy.firstServeTimeoutSeconds(edgeCushionSeconds: 45) == 60)
    }

    // MARK: - Live HLS ingest

    private func listing(count: Int, duration: Double) -> HLSMediaPlaylist {
        HLSMediaPlaylist(
            targetDuration: duration,
            mediaSequence: 1000,
            segments: (0..<count).map { HLSMediaSegment(uri: "s\($0)", duration: duration, discontinuityBefore: false) },
            hasEndList: false,
            isEncrypted: false,
            hasUnsupportedEncryption: false,
            hasMap: false
        )
    }

    @Test("the ingest joins deep enough to fill the cushion from the listed backlog")
    func ingestJoinDepth() {
        let backlog = listing(count: 30, duration: 2)
        var plain = HLSPlaylistTracker.joining(cushion: nil)
        var cushioned = HLSPlaylistTracker.joining(cushion: 30)
        var stock = HLSPlaylistTracker()
        let plainJoin = plain.newSegments(in: backlog)
        let cushionedJoin = cushioned.newSegments(in: backlog)
        #expect(plainJoin.count == stock.newSegments(in: backlog).count)
        #expect(cushionedJoin.map(\.duration).reduce(0, +) >= 30 + HLSPlaylistTracker.openGOPMarginSeconds)
        #expect(cushionedJoin.last?.uri == "s29")
    }

    // MARK: - Software path

    @Test("an unset cushion leaves the software holdback as it was")
    func softwareUnset() {
        #expect(SoftwareLiveHoldback(deliveryUnitSeconds: nil, edgeCushionSeconds: nil) == .continuous)
        let segmented = SoftwareLiveHoldback(deliveryUnitSeconds: 10, edgeCushionSeconds: 5)
        #expect(segmented.joinLeadSeconds == 16)
        #expect(segmented.resumeCushionSeconds == 12)
        #expect(segmented.edgeHoldbackSeconds == 26)
    }

    @Test("a continuous source joins, lands, resumes and counts the edge at the cushion")
    func softwareContinuous() {
        let h = SoftwareLiveHoldback(deliveryUnitSeconds: nil, edgeCushionSeconds: 20)
        #expect(h.joinLeadSeconds == 20)
        #expect(h.landingHoldbackSeconds == 20)
        #expect(h.resumeCushionSeconds == 20)
        #expect(h.edgeHoldbackSeconds == 20)
    }

    @Test("a segmented source takes the deeper of its own lead and the cushion")
    func softwareSegmented() {
        let h = SoftwareLiveHoldback(deliveryUnitSeconds: 10, edgeCushionSeconds: 30)
        #expect(h.joinLeadSeconds == 30)
        #expect(h.resumeCushionSeconds == 30)
        #expect(h.edgeHoldbackSeconds == 40)
    }

    @Test("a realtime join waits until the cushion stands behind the newest media")
    func softwareJoinWaits() {
        var policy = SoftwareLiveJoinPolicy()
        var decision: SoftwareLiveJoinPolicy.Decision?
        var now = 0.0
        // An 8 s connect burst, then real time.
        while decision == nil, now < 60 {
            decision = policy.observe(firstPts: 0, newestPts: 8 + now, at: now,
                                      leadSeconds: 20, minimumSpanSeconds: 20)
            now += 0.05
        }
        #expect(decision == .fromStart)
        #expect(now >= 11.9)
    }

    @Test("a join whose source never fills the cushion starts on what it holds")
    func softwareJoinDeadline() {
        var policy = SoftwareLiveJoinPolicy()
        var decision: SoftwareLiveJoinPolicy.Decision?
        var now = 0.0
        while decision == nil, now < 60 {
            decision = policy.observe(firstPts: 0, newestPts: 8, at: now,
                                      leadSeconds: 20, minimumSpanSeconds: 20)
            now += 0.05
        }
        #expect(decision == .fromStart)
        #expect(now >= SoftwareLiveJoinPolicy.maximumSettleSeconds + 20)
        #expect(now < SoftwareLiveJoinPolicy.maximumSettleSeconds + 21)
    }
}

@Suite("A remote-HLS cushion never plays closer than the origin's own offset")
struct RemoteLiveEdgeOffsetTests {
    @Test("the deeper of the cushion and the origin's recommended offset",
          arguments: [(5.0, 18.0, 18.0), (30.0, 18.0, 30.0), (20.0, 0.0, 20.0), (20.0, .nan, 20.0)])
    func offset(cushion: Double, recommended: Double, expected: Double) {
        #expect(NativeAVPlayerHost.liveEdgeOffset(cushionSeconds: cushion, recommendedSeconds: recommended) == expected)
    }
}
