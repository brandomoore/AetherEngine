// Tests/AetherEngineTests/Issue684IngestSealCoversUpstreamSegmentTests.swift
// AE#684: a live HLS ingest under `.fastZap` whose upstream cuts 6 s segments sealed the served
// TARGETDURATION at 4 (`max EXTINF 2.000s, measured floor 6.000s needs 4s of patience`), because the
// engine re-cuts each upstream segment at its 2 s GOPs and the upstream's own segment duration entered
// only through the cadence floor, as `ceil(6 / 1.5)`. That division belongs to a MEASURED gap, a robust
// maximum that is a worst case already. An upstream segment duration is the opposite: the period the
// source delivers at when nothing is late, so `1.5 x TD` came out at exactly one period, 6.0 s, and every
// ordinary delivery (6.17 to 6.83 s in the field capture, 63 of 110 gaps above 6.0 s) was past the
// client's patience. The session drew -12888, AVPlayer then skipped a playlist reload (5.03 s between two
// polls instead of 2 s), and the 12 s holdback ran out 2.4 s after the content it was waiting for had
// been listed.
//
// The upstream delivers in whole segments however finely they are re-cut here, so the served playlist
// changes once per upstream segment and the seal asks for what a playlist of those segments promises:
// TARGETDURATION >= the longest upstream segment. These pin what is ASKED. What is sealed is that,
// as far as the join pays for it (`Issue684JoinBoundSealTests`), and the join is not deepened.
import XCTest
@testable import AetherEngine

private final class ScriptedIngest: @unchecked Sendable {
    var now: Double = 0
    var cadence: Double?
    var closedCadence: Double?
    var segmentDuration: Double?
}

final class Issue684IngestSealCoversUpstreamSegmentTests: XCTestCase {

    private let fastZapCut = HLSVideoEngine.liveCutTargetSeconds(for: .fastZap)
    private let standardCut = HLSVideoEngine.liveCutTargetSeconds(for: .standard)

    private func makePolicy(_ s: ScriptedIngest, advertised: Double?) -> LiveCadencePolicy {
        LiveCadencePolicy(
            observe: { s.cadence },
            cutTargetSeconds: 0.5,
            observeSealEvidence: {
                LiveCadenceEvidence(closedCadenceSeconds: s.closedCadence,
                                    servedSegmentDurationSeconds: s.segmentDuration)
            },
            selfReportedTargetDurationSeconds: advertised,
            clock: { s.now }
        )
    }

    // MARK: - The reported seal

    /// 6 s upstream segments, re-cut at 2.000 s GOPs, sealed inside the join burst.
    func testSixSecondUpstreamRecutAtTwoSecondGOPsSealsAtSix() {
        let td = LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 2.0,
                                                      cutTargetSeconds: fastZapCut,
                                                      cadenceFloorSeconds: 6.0,
                                                      upstreamSegmentSeconds: 6.0)
        XCTAssertEqual(td, 6)
        XCTAssertEqual(LiveEdgePolicy.holdBackSeconds(targetDuration: td), 18.0, accuracy: 1e-9)
    }

    /// The deliveries the field capture shows for one upstream segment, and the later candidate the
    /// session itself logged (`measured floor 8.492s needs 6s of patience`).
    func testPatienceCoversTheFieldDeliveries() {
        let td = LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 2.0,
                                                      cutTargetSeconds: fastZapCut,
                                                      cadenceFloorSeconds: 6.0,
                                                      upstreamSegmentSeconds: 6.0)
        let patience = Double(td) * LiveEdgePolicy.unchangedPlaylistPatienceMultiplier
        for gap in [6.17, 6.54, 6.83, 7.36, 8.32, 8.492] {
            XCTAssertGreaterThan(patience, gap)
        }
        XCTAssertGreaterThanOrEqual(td, LiveEdgePolicy.targetDurationForCadence(8.492),
                                    "the seal must not be under what the session measured afterwards")
    }

    /// A period is not a worst case: the patience has to clear it by the same half the RFC gives a
    /// playlist of those segments, for every segment length and not only where `ceil` happens to help.
    func testPatienceIsOneAndAHalfUpstreamSegmentsAtEveryLength() {
        for upstream in [1.0, 1.92, 2.0, 3.0, 4.0, 4.5, 6.0, 9.0, 10.0] {
            let td = LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: min(upstream, 2.0),
                                                          cutTargetSeconds: fastZapCut,
                                                          cadenceFloorSeconds: upstream,
                                                          upstreamSegmentSeconds: upstream)
            XCTAssertGreaterThanOrEqual(Double(td) * LiveEdgePolicy.unchangedPlaylistPatienceMultiplier,
                                        upstream * 1.5, "upstream \(upstream)s sealed at \(td)s")
        }
    }

    // MARK: - What stays

    /// AE#447: 2.000 s and 1.920 s ingests keep TARGETDURATION 2 and a 6 s holdback.
    func testTwoSecondIngestKeepsTargetDurationTwo() {
        for upstream in [2.0, 1.92] {
            let td = LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: upstream,
                                                          cutTargetSeconds: fastZapCut,
                                                          cadenceFloorSeconds: 2.142,
                                                          upstreamSegmentSeconds: upstream)
            XCTAssertEqual(td, 2, "upstream \(upstream)s")
        }
    }

    /// A measured gap is a robust maximum and still enters as the patience it needs.
    func testClosedCadenceStillEntersAsThePatienceItNeeds() {
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 2.0,
                                                            cutTargetSeconds: fastZapCut,
                                                            cadenceFloorSeconds: 20.0,
                                                            upstreamSegmentSeconds: 2.0), 14)
    }

    /// No upstream playlist, no term: AE#670's self-cut seal and the raw-TS seal are what they were.
    func testSelfCutSessionsAreUnchanged() {
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 1.0,
                                                            cutTargetSeconds: fastZapCut,
                                                            cadenceFloorSeconds: nil,
                                                            segmentsAreCutHere: true,
                                                            upstreamSegmentSeconds: nil), 2)
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 5.76,
                                                            cutTargetSeconds: standardCut,
                                                            cadenceFloorSeconds: nil,
                                                            segmentsAreCutHere: true,
                                                            upstreamSegmentSeconds: nil), 6)
    }

    /// `.standard` on the same 6 s upstream already sat at 6 through its `1.5 x cut target` floor.
    func testStandardProfileOnSixSecondUpstreamIsUnchanged() {
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 6.0,
                                                            cutTargetSeconds: standardCut,
                                                            cadenceFloorSeconds: 6.0,
                                                            upstreamSegmentSeconds: 6.0), 6)
    }

    /// Taken at the served resolution like every other term (AE#447 round 2).
    func testUpstreamSegmentIsTakenAtTheServedResolution() {
        XCTAssertEqual(LiveEdgePolicy.targetDurationForUpstreamSegment(6.0000000000000009), 6)
        XCTAssertEqual(LiveEdgePolicy.targetDurationForUpstreamSegment(6.006), 7)
        XCTAssertEqual(LiveEdgePolicy.targetDurationForUpstreamSegment(.infinity),
                       Int(LiveEdgePolicy.upstreamSegmentSealCeilingSeconds))
        XCTAssertEqual(LiveEdgePolicy.targetDurationForUpstreamSegment(.nan), 0)
    }

    // MARK: - `.standard`, which the term reaches above 6 s

    /// `.standard` re-cuts too (4 s cut target), so a provider above its `1.5 x cut target` floor is
    /// delivered in units longer than anything the floor covers. This is what the terms ASK for; the
    /// three-segment join then pays 9 of the 10 (`Issue684JoinBoundSealTests`). Measured on a 10 s
    /// origin with jittered deliveries, three 60 s runs per arm and window depth: at TD 7 the item
    /// was rebuilt in 6 of 6 runs, at TD 9 in none.
    func testStandardProfileSealsLongUpstreamSegmentsWhole() {
        func seal(_ upstream: Double) -> Int {
            LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 4.0,
                                                 cutTargetSeconds: standardCut,
                                                 cadenceFloorSeconds: upstream,
                                                 upstreamSegmentSeconds: upstream)
        }
        XCTAssertEqual(seal(4.0), 6, "under the floor: unchanged")
        XCTAssertEqual(seal(6.0), 6, "at the floor: unchanged")
        XCTAssertEqual(seal(8.0), 8, "was 6")
        XCTAssertEqual(seal(10.0), 10, "was 7")
        XCTAssertEqual(LiveEdgePolicy.holdBackSeconds(targetDuration: seal(10.0)), 30.0, accuracy: 1e-9)
    }

    // MARK: - The ceiling

    /// A degenerate upstream: a 20 s segment taken whole would be a 60 s holdback, the whole
    /// live-only window. Above the ceiling the term stops growing and the seal is what it was.
    func testVeryLongUpstreamSegmentsAreNotTakenWhole() {
        let ceiling = Int(LiveEdgePolicy.upstreamSegmentSealCeilingSeconds)
        for upstream in [12.0, 15.0, 20.0, 28.0] {
            let td = LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 2.0,
                                                          cutTargetSeconds: fastZapCut,
                                                          cadenceFloorSeconds: upstream,
                                                          upstreamSegmentSeconds: upstream)
            XCTAssertEqual(td, max(ceiling, LiveEdgePolicy.targetDurationForCadence(upstream)),
                           "upstream \(upstream)s")
            XCTAssertLessThan(LiveEdgePolicy.holdBackSeconds(targetDuration: td),
                              LiveWindowSizing.liveOnlyFloorSeconds, "upstream \(upstream)s")
        }
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 2.0,
                                                            cutTargetSeconds: fastZapCut,
                                                            cadenceFloorSeconds: 20.0,
                                                            upstreamSegmentSeconds: 20.0), 14,
                       "a 20 s segment seals what it sealed before the term existed")
    }

    /// The term on its own never asks for more than half the live-only window of holdback.
    func testTheTermAloneStaysWellInsideTheLiveWindow() {
        let most = LiveEdgePolicy.targetDurationForUpstreamSegment(.greatestFiniteMagnitude)
        XCTAssertLessThanOrEqual(LiveEdgePolicy.holdBackSeconds(targetDuration: most),
                                 LiveWindowSizing.liveOnlyFloorSeconds / 2)
    }

    /// A fractional segment costs a whole second, like every other term (AE#447 round 2).
    func testFractionalSegmentCost() {
        let td = LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 2.0,
                                                      cutTargetSeconds: fastZapCut,
                                                      cadenceFloorSeconds: 6.006,
                                                      upstreamSegmentSeconds: 6.006)
        XCTAssertEqual(td, 7)
        XCTAssertEqual(LiveEdgePolicy.holdBackSeconds(targetDuration: td), 21.0, accuracy: 1e-9)
        let coverage = HLSPlaylistTracker.loopbackCushionCoverageSeconds(segments: (0..<8).map { _ in
            HLSMediaSegment(uri: "s", duration: 6.006, discontinuityBefore: false)
        })
        XCTAssertEqual(coverage, 19.0, accuracy: 1e-9,
                       "the join is not sized from the seal: ceil(6.006 / 1.5) = 5, 15 s and a 4 s GOP")
    }

    // MARK: - As far as the join can pay

    func testAnExhaustedJoinSealsWhatItsWindowCovers() {
        // Three 6 s segments: 18 s joined, 16 s cut, one 2 s GOP open.
        XCTAssertEqual(LiveEdgePolicy.targetDurationTheJoinCanPay(
            full: 6, withoutUpstreamSegment: 4, finalizedSeconds: 16.0), 5)
        // Three 10 s segments: 28 s cut.
        XCTAssertEqual(LiveEdgePolicy.targetDurationTheJoinCanPay(
            full: 10, withoutUpstreamSegment: 7, finalizedSeconds: 28.0), 9)
        // A join deep enough pays in full.
        XCTAssertEqual(LiveEdgePolicy.targetDurationTheJoinCanPay(
            full: 6, withoutUpstreamSegment: 4, finalizedSeconds: 22.0), 6)
        // Never under what the seal was without the term, however little was joined.
        XCTAssertEqual(LiveEdgePolicy.targetDurationTheJoinCanPay(
            full: 6, withoutUpstreamSegment: 4, finalizedSeconds: 10.0), 4)
        // Total.
        XCTAssertEqual(LiveEdgePolicy.targetDurationTheJoinCanPay(
            full: 6, withoutUpstreamSegment: 4, finalizedSeconds: .nan), 4)
        XCTAssertEqual(LiveEdgePolicy.targetDurationTheJoinCanPay(
            full: 6, withoutUpstreamSegment: 4, finalizedSeconds: .infinity), 4)
    }

    // MARK: - Where the term comes from

    /// Measured, not advertised: the longest segment the upstream actually served.
    func testPolicyReportsTheLongestServedUpstreamSegment() {
        let s = ScriptedIngest()
        let policy = makePolicy(s, advertised: 9)
        XCTAssertNil(policy.upstreamSegmentDurationSeconds, "an advert alone is not a served segment")
        s.now = 1; s.cadence = 0.2; s.segmentDuration = 4.0
        XCTAssertEqual(try XCTUnwrap(policy.upstreamSegmentDurationSeconds), 4.0, accuracy: 1e-9)
        s.now = 2; s.segmentDuration = 6.0
        XCTAssertEqual(try XCTUnwrap(policy.upstreamSegmentDurationSeconds), 6.0, accuracy: 1e-9)
        s.now = 3; s.segmentDuration = nil
        XCTAssertEqual(try XCTUnwrap(policy.upstreamSegmentDurationSeconds), 6.0, accuracy: 1e-9,
                       "monotonic, like the floor it sits beside")
    }

    // MARK: - The join keeps its depth

    /// Owner's rule: the join is never extended for the upstream-segment term. One more upstream
    /// segment is one more download before the first picture on every zap (AE#678 declined it), so
    /// the coverage is what 7.24.0 sized it to and the seal rises only as far as that pays.
    func testJoinIsNotExtendedForTheUpstreamSegmentTerm() {
        func coverage(_ durations: [Double]) -> Double {
            HLSPlaylistTracker.loopbackCushionCoverageSeconds(segments: durations.map {
                HLSMediaSegment(uri: "s", duration: $0, discontinuityBefore: false)
            })
        }
        XCTAssertEqual(coverage([6, 6, 6]), 16)     // ceil(6 / 1.5) = 4, 12 s and a 4 s GOP: three segments
        XCTAssertEqual(coverage([10, 10, 10]), 25)  // 7, 21 s + 4 s: three segments
        XCTAssertEqual(coverage([2, 2, 2]), 8)
        XCTAssertEqual(coverage([20, 20, 20]), 46)
        var tracker = HLSPlaylistTracker()
        let uris = ["a", "b", "c", "d", "e", "f", "g", "h"]
        let joined = tracker.newSegments(in: HLSMediaPlaylist(
            targetDuration: 6,
            mediaSequence: 0,
            segments: uris.map { HLSMediaSegment(uri: $0, duration: 6, discontinuityBefore: false) },
            hasEndList: false,
            isEncrypted: false,
            hasUnsupportedEncryption: false,
            hasMap: false))
        XCTAssertEqual(joined.map(\.uri), ["f", "g", "h"], "three 6 s segments, as before this issue")
    }

    // MARK: - The seal says why

    func testSealAccountNamesTheUpstreamSegmentTerm() {
        let derivation = LiveTargetDurationDerivation(
            value: 6, maxSegmentDuration: 2.0, cutTargetFloor: fastZapCut,
            cadenceFloor: .measured(6.0), upstreamSegment: 6.0, selfReported: 6.0)
        let account = derivation.account
        XCTAssertTrue(account.contains("sealed at 6s"), account)
        XCTAssertTrue(account.contains("holdback 18.000s"), account)
        XCTAssertTrue(account.contains("upstream segment 6.000s"), account)
        XCTAssertTrue(account.contains("upstream advertises 6.000s (reported, not used)"), account)
    }

    /// AE#447 round 2's property, with the new term in the sum: the line adds up to its own number.
    func testSealAccountStillRecomputesTheValueItReports() throws {
        func number(after label: String, in text: String) -> Double? {
            guard let r = text.range(of: label + "[0-9]+\\.?[0-9]*", options: .regularExpression) else {
                return nil
            }
            return Double(text[r].dropFirst(label.count))
        }
        for upstream in [2.0, 4.0, 6.0, 6.006, 10.0] {
            for floor in [upstream, 8.492, 20.0] {
                let value = LiveEdgePolicy.targetDurationSeconds(
                    maxSegmentDuration: 2.0, cutTargetSeconds: fastZapCut,
                    cadenceFloorSeconds: floor, upstreamSegmentSeconds: upstream)
                let account = LiveTargetDurationDerivation(
                    value: value, maxSegmentDuration: 2.0, cutTargetFloor: fastZapCut,
                    cadenceFloor: .measured(floor), upstreamSegment: upstream, selfReported: 6.0).account
                var recomputed = Int(ceil(try XCTUnwrap(number(after: "max EXTINF ", in: account))))
                recomputed = max(recomputed,
                                 Int(ceil(try XCTUnwrap(number(after: "1.5 x cut target ", in: account)))))
                recomputed = max(recomputed,
                                 Int(ceil(try XCTUnwrap(number(after: "upstream segment ", in: account)))))
                recomputed = max(recomputed, Int(try XCTUnwrap(number(after: "needs ", in: account))))
                XCTAssertEqual(Int(try XCTUnwrap(number(after: "sealed at ", in: account))), recomputed,
                               account)
            }
        }
    }
}
