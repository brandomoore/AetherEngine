// Tests/AetherEngineTests/Issue670FastZapGOPHeadroomTests.swift
// AE#670: live 1080p50 H.264 TS under `.fastZap` froze at irregular intervals, with AVPlayer reporting
// -12888 (playlist unchanged for longer than 1.5 x target duration) and #524 firing on 1.5 to 2 s of
// runway. The fastZap cut target (0.5 s) sits below any real GOP, so every segment the engine cuts is one
// whole source GOP. The TARGETDURATION is sealed from the first window, which on the reported source held
// three 1.000 s GOPs: TD 1, holdback 3 s, and no headroom at all over the GOP it had seen. The source's
// GOPs are not regular (1.0 to 2.4 s), so every longer one broke `EXTINF <= TD` and left the playlist
// unchanged past 1.5 x TD. `.standard` never had the problem because its `1.5 x cut target` floor is that
// headroom; under fastZap it collapses to 1 s.
//
// Measured with `aetherctl live --fast-zap --realtime --preroll 0` on a seed with that GOP pattern, two
// passes per arm: sealed at 1 s, one stall, the playlist refused as a parse error (-12642, macOS AVPlayer
// is stricter than the reporter's tvOS one) and a fall to the software path on both passes; sealed at 2 s,
// none of the three on either.
import XCTest
@testable import AetherEngine

final class Issue670FastZapGOPHeadroomTests: XCTestCase {

    private let fastZapCut = HLSVideoEngine.liveCutTargetSeconds(for: .fastZap)
    private let standardCut = HLSVideoEngine.liveCutTargetSeconds(for: .standard)

    /// The reported seal: three 1.000 s GOPs in the first window.
    func testSelfCutFastZapSealsHeadroomOverTheFirstGOPs() {
        let td = LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 1.0,
                                                      cutTargetSeconds: fastZapCut,
                                                      cadenceFloorSeconds: nil,
                                                      segmentsAreCutHere: true)
        XCTAssertEqual(td, 2)
        XCTAssertEqual(LiveEdgePolicy.holdBackSeconds(targetDuration: td), 6.0, accuracy: 1e-9)
    }

    /// What the seal has to survive afterwards: the 2.4 s GOP the reporter's log shows. It must round
    /// under TD (RFC 8216 4.3.3.1), and the playlist must not stay unchanged past AVPlayer's patience
    /// while the cutter waits for the keyframe that ends it.
    func testLaterLongGOPStaysInsideTheSealedValue() {
        let td = LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 1.0,
                                                      cutTargetSeconds: fastZapCut,
                                                      cadenceFloorSeconds: nil,
                                                      segmentsAreCutHere: true)
        let laterGOP = 2.4
        XCTAssertLessThanOrEqual(Int(laterGOP.rounded()), td)
        XCTAssertGreaterThan(Double(td) * LiveEdgePolicy.unchangedPlaylistPatienceMultiplier, laterGOP)
    }

    func testHeadroomScalesWithTheObservedGOP() {
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 0.96,
                                                            cutTargetSeconds: fastZapCut,
                                                            cadenceFloorSeconds: nil,
                                                            segmentsAreCutHere: true), 2)
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 1.92,
                                                            cutTargetSeconds: fastZapCut,
                                                            cadenceFloorSeconds: nil,
                                                            segmentsAreCutHere: true), 3)
    }

    /// AE#447: ingested segments are the upstream's own, bounded by its advertised target duration, so
    /// the field-measured TD 2 on 2.000 s segments stays.
    func testIngestedSegmentsKeepTheirTargetDuration() {
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 2.0,
                                                            cutTargetSeconds: fastZapCut,
                                                            cadenceFloorSeconds: 2.0,
                                                            segmentsAreCutHere: false), 2)
    }

    /// `.standard`'s cut target bounds its segments, and its `1.5 x cut target` floor is already the
    /// headroom: the common 1.92 s GOP shape cuts 5.76 s segments and must keep TD 6, not rise to 9.
    func testStandardProfileIsUnchanged() {
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 5.76,
                                                            cutTargetSeconds: standardCut,
                                                            cadenceFloorSeconds: nil,
                                                            segmentsAreCutHere: true), 6)
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 4.0,
                                                            cutTargetSeconds: standardCut,
                                                            cadenceFloorSeconds: nil,
                                                            segmentsAreCutHere: true), 6)
    }

    /// Round 2, reported on a 59.94 fps source with 1.001 s GOPs: 79 frames sealed 2 and 80 frames
    /// sealed 3, one millisecond of `1.5 x` apart (1.977 against 2.002), and the 9 s holdback cost a
    /// 6.6 s rebuild backlog its immediate start.
    func testOneMoreFrameDoesNotBuyAWholeSecond() {
        let frame = 1001.0 / 60000.0
        for frames in [79, 80, 89] {
            XCTAssertEqual(fastZapSeal(Double(frames) * frame), 2, "\(frames) frames")
        }
    }

    /// The reporter's TD 2 sessions later met segments up to 1.485 s and ran without a stall or -12888.
    func testFieldMaximumUnderTheSealStaysAtTwo() {
        XCTAssertEqual(fastZapSeal(1.485), 2)
    }

    /// The boundary is where a GOP 1.5 x the longest seen would no longer list under TD 2: 2.499 s
    /// rounds to 2, 2.5 s to 3.
    func testHeadroomBoundaryFollowsTheListingRule() {
        XCTAssertEqual(fastZapSeal(1.666), 2)
        XCTAssertEqual(fastZapSeal(1.667), 3)
    }

    /// Every value of the round-2 term satisfies what the first version promised for its 2.4 s GOP:
    /// a GOP 1.5 x the longest seen lists under TD and is finalized inside AVPlayer's patience with the
    /// delivery margin to spare. And it is never above `ceil(1.5 x max EXTINF)`.
    func testHeadroomTermKeepsItsPromiseAndNeverRaisesTheSeal() {
        var gop = 0.3
        while gop < 12 {
            let td = LiveEdgePolicy.targetDurationForGOPHeadroom(gop)
            let longer = LiveEdgePolicy.servedSeconds(gop * 1.5)
            XCTAssertLessThanOrEqual(Int(longer.rounded(.toNearestOrAwayFromZero)), td, "\(gop)")
            XCTAssertLessThanOrEqual(longer + LiveEdgePolicy.gopHeadroomDeliveryMarginSeconds,
                                     Double(td) * LiveEdgePolicy.unchangedPlaylistPatienceMultiplier, "\(gop)")
            XCTAssertLessThanOrEqual(td, LiveEdgePolicy.wholeSecondsCovering(gop * 1.5), "\(gop)")
            gop += 0.001
        }
    }

    func testHeadroomTermIsTotal() {
        XCTAssertEqual(LiveEdgePolicy.targetDurationForGOPHeadroom(.nan), 0)
        XCTAssertEqual(LiveEdgePolicy.targetDurationForGOPHeadroom(-1), 0)
        XCTAssertEqual(LiveEdgePolicy.targetDurationForGOPHeadroom(.infinity), LiveEdgePolicy.maxCoveredWholeSeconds)
        XCTAssertEqual(LiveEdgePolicy.targetDurationForGOPHeadroom(.greatestFiniteMagnitude),
                       LiveEdgePolicy.maxCoveredWholeSeconds)
    }

    func testSealAccountNamesWhatTheHeadroomTermNeeds() {
        let derivation = LiveTargetDurationDerivation(
            value: 2, maxSegmentDuration: 80 * 1001.0 / 60000.0, cutTargetFloor: fastZapCut,
            gopHeadroomApplies: true, cadenceFloor: .unmeasurable, selfReported: nil)
        XCTAssertTrue(derivation.account.contains("1.5 x max EXTINF 2.002s needs 2s"), derivation.account)
    }

    private func fastZapSeal(_ maxSegment: Double) -> Int {
        LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: maxSegment,
                                             cutTargetSeconds: fastZapCut,
                                             cadenceFloorSeconds: nil,
                                             segmentsAreCutHere: true)
    }

    func testSealAccountNamesTheHeadroomTerm() {
        let derivation = LiveTargetDurationDerivation(
            value: 2, maxSegmentDuration: 1.0, cutTargetFloor: fastZapCut,
            gopHeadroomApplies: true, cadenceFloor: .unmeasurable, selfReported: nil)
        XCTAssertTrue(derivation.account.contains("1.5 x max EXTINF 1.500s"), derivation.account)
    }
}
