// Tests/AetherEngineTests/Issue684MixedLengthJoinTests.swift
// AE#684, the reporter's own channel: its upstream alternates 6 s and 4 s segments. The join counts
// seconds back from the newest segment, so its depth depended on which of the two was newest. With a
// 4 s one newest, `4 + 6 + 4` is under the 16 s coverage target and a fourth segment is taken: 20 s
// listed, 18 s cut, seal 6. With a 6 s one newest, `6 + 4 + 6` meets the target at three: 16 s listed,
// 14 s cut, seal 4, 7.25.1's value and its stalls. Measured on `--durs 6,4 --window 8`: `--prefill 8`
// sealed 6 with no -12888 and no stall, `--prefill 7` sealed 4 in both arms and stalled as before.
// About four tunes in ten land in that phase.
//
// The join is equalised over the phases of one listing: a tune never loads more than the deepest tune
// of the same channel already did. A first version of this took one segment more on ANY mixed-length
// join that could not pay its seal, which also deepened shapes with no phase asymmetry at all, on
// every tune: 10 s / 8 s from three to four segments (6.19 s to 8.12 s to first picture behind
// 8 Mbit/s) and 6 s / 6 s / 4 s likewise (3.81 s to 4.98 s). Those keep their join now.
import XCTest
@testable import AetherEngine

final class Issue684MixedLengthJoinTests: XCTestCase {

    /// The join a fresh tracker takes from a playlist listing these durations, oldest first.
    private func joined(_ durations: [Double]) -> [Double] {
        var tracker = HLSPlaylistTracker()
        let playlist = HLSMediaPlaylist(
            targetDuration: (durations.max() ?? 0).rounded(.up),
            mediaSequence: 100,
            segments: durations.enumerated().map {
                HLSMediaSegment(uri: "s\($0.offset)", duration: $0.element, discontinuityBefore: false)
            },
            hasEndList: false,
            isEncrypted: false,
            hasUnsupportedEncryption: false,
            hasMap: false
        )
        return tracker.newSegments(in: playlist).map(\.duration)
    }

    /// What the gate seals from a spent join of these segments at 2 s GOPs under `.fastZap`.
    private func seal(_ join: [Double]) -> Int {
        let longest = join.max() ?? 0
        let cut = join.reduce(0, +) - 2.0
        let full = LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 2.0, cutTargetSeconds: 0.5,
                                                        cadenceFloorSeconds: longest,
                                                        upstreamSegmentSeconds: longest)
        let base = LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 2.0, cutTargetSeconds: 0.5,
                                                        cadenceFloorSeconds: longest)
        return LiveEdgePolicy.targetDurationTheJoinCanPay(full: full, withoutUpstreamSegment: base,
                                                          finalizedSeconds: cut)
    }

    // MARK: - Both phases of the reported channel

    func testSixFourAlternationJoinsFourSegmentsInBothPhases() {
        let newestIsFour = joined([6, 4, 6, 4, 6, 4, 6, 4])
        XCTAssertEqual(newestIsFour, [6, 4, 6, 4], "under the coverage target at three, as before")
        let newestIsSix = joined([4, 6, 4, 6, 4, 6, 4, 6])
        XCTAssertEqual(newestIsSix, [4, 6, 4, 6], "three met the target; the fourth is this rule's")
        XCTAssertEqual(seal(newestIsFour), 6)
        XCTAssertEqual(seal(newestIsSix), 6)
    }

    /// The phase is where the tune lands, not how the playlist began.
    func testFourSixOrderIsTheSameChannel() {
        XCTAssertEqual(joined([4, 6, 4, 6, 4, 6, 4]).reduce(0, +), 20)
        XCTAssertEqual(joined([6, 4, 6, 4, 6, 4, 6]).reduce(0, +), 20)
        XCTAssertEqual(joined([4, 6, 4, 6, 4, 6, 4]).count, 4)
        XCTAssertEqual(joined([6, 4, 6, 4, 6, 4, 6]).count, 4)
    }

    // MARK: - Shapes with no deeper phase keep their join

    /// Three segments are 16 s in every phase, so no tune of this channel ever loaded a fourth, and
    /// none does now. Its seal is what three pay: 14 s cut, 4.
    func testSixSixFourPatternKeepsThreeSegmentsInEveryPhase() {
        let phases: [[Double]] = [
            [6, 6, 4, 6, 6, 4, 6, 6, 4],
            [6, 4, 6, 6, 4, 6, 6, 4, 6],
            [4, 6, 6, 4, 6, 6, 4, 6, 6],
        ]
        for phase in phases {
            let join = joined(phase)
            XCTAssertEqual(join.count, 3, "\(phase)")
            XCTAssertEqual(join.reduce(0, +), 16, "\(phase)")
            XCTAssertEqual(seal(join), 4, "\(phase)")
        }
    }

    /// 28 s and 26 s both meet the 25 s target at three. Seal 8 in both phases (26 s and 24 s cut).
    func testTenEightAlternationKeepsThreeSegmentsInBothPhases() {
        let newestIsTen = joined([8, 10, 8, 10, 8, 10, 8, 10])
        let newestIsEight = joined([10, 8, 10, 8, 10, 8, 10, 8])
        XCTAssertEqual(newestIsTen, [10, 8, 10])
        XCTAssertEqual(newestIsEight, [8, 10, 8])
        XCTAssertEqual(seal(newestIsTen), 8)
        XCTAssertEqual(seal(newestIsEight), 8)
    }

    /// Equalising phases is about depth, not about the seal: 6 s / 5 s joins three either way
    /// (17 s and 16 s), and its seal still follows the phase, 5 and 4.
    func testAShapeWhosePhasesJoinAlikeKeepsItsPhaseDependentSeal() {
        let newestIsSix = joined([5, 6, 5, 6, 5, 6, 5, 6])
        let newestIsFive = joined([6, 5, 6, 5, 6, 5, 6, 5])
        XCTAssertEqual(newestIsSix.count, 3)
        XCTAssertEqual(newestIsFive.count, 3)
        XCTAssertEqual(seal(newestIsSix), 5)
        XCTAssertEqual(seal(newestIsFive), 4)
    }

    // MARK: - Uniform upstreams keep the 7.24.0 join

    func testUniformSixAndTenSecondJoinsAreUnchanged() {
        XCTAssertEqual(joined(Array(repeating: 6, count: 8)), [6, 6, 6])
        XCTAssertEqual(joined(Array(repeating: 10, count: 8)), [10, 10, 10])
        XCTAssertEqual(joined(Array(repeating: 2, count: 8)), [2, 2, 2, 2])
        XCTAssertEqual(seal([6, 6, 6]), 5)
        XCTAssertEqual(seal([10, 10, 10]), 9)
    }

    /// EXTINF that wanders by frames around its nominal value is a uniform upstream.
    func testFrameJitterInExtinfIsNotAPhase() {
        XCTAssertEqual(joined([6.0, 5.96, 5.92, 6.0, 5.96, 5.92, 6.0, 5.96]).count, 3)
        XCTAssertEqual(joined([5.96, 5.92, 6.0, 5.96, 5.92, 6.0, 5.96, 6.0]).count, 3)
    }

    // MARK: - The rule's edges

    /// The depth is the deepest the coverage rule takes over the phases of the listing, and never
    /// more than one above the tune's own.
    func testDepthIsTheDeepestPhaseBoundedAtOneAboveTheTunesOwn() {
        func depth(_ durations: [Double], coverage: Double) -> Int {
            HLSPlaylistTracker.phaseEqualisedJoinDepth(durations: durations, coverage: coverage, limit: 8)
        }
        XCTAssertEqual(depth([4, 6, 4, 6, 4, 6, 4, 6], coverage: 16), 4)
        XCTAssertEqual(depth([6, 4, 6, 4, 6, 4, 6, 4], coverage: 16), 4)
        XCTAssertEqual(depth([6, 6, 6, 6, 6, 6, 6, 6], coverage: 16), 3)
        // A run of short segments behind two long ones: the earlier phases need six and more, the
        // tune's own two. Bounded at three.
        XCTAssertEqual(depth([2, 2, 2, 2, 2, 2, 10, 10], coverage: 16), 3)
        // The old rule alone, and a listing too short to decide a tune.
        XCTAssertEqual(HLSPlaylistTracker.coverageJoinDepth(durations: [4, 6, 4, 6][...], coverage: 16, limit: 8), 3)
        XCTAssertNil(HLSPlaylistTracker.coverageJoinDepth(durations: [4, 6][...], coverage: 16, limit: 8))
    }

    /// A lone short segment on a uniform upstream. While it is among the newest three the join is
    /// four, as it always was (15 s is under the target). For the two tunes after that the join
    /// still contains the newest segment of a tune that took four, so it stays four. After that it
    /// is three again, although the short segment is still listed.
    func testALoneShortSegmentOnAUniformUpstream() {
        XCTAssertEqual(joined([6, 6, 6, 6, 6, 6, 6, 3]), [6, 6, 6, 3], "as before")
        XCTAssertEqual(joined([6, 6, 6, 6, 6, 6, 3, 6]), [6, 6, 3, 6], "as before")
        XCTAssertEqual(joined([6, 6, 6, 6, 6, 3, 6, 6]), [6, 3, 6, 6], "as before")
        XCTAssertEqual(joined([6, 6, 6, 6, 3, 6, 6, 6]), [3, 6, 6, 6], "one tune after: lifted to four")
        XCTAssertEqual(joined([6, 6, 6, 3, 6, 6, 6, 6]), [6, 6, 6, 6], "two tunes after: lifted to four")
        XCTAssertEqual(joined([6, 6, 3, 6, 6, 6, 6, 6]), [6, 6, 6], "three after: its own depth again")
        XCTAssertEqual(joined([6, 6, 6, 6, 6, 6, 6, 6]).count, 3)
    }

    /// One more, once, and never past what the playlist offers or the eviction margin allows.
    func testTheExtraSegmentRespectsTheWindow() {
        XCTAssertEqual(joined([4, 6, 4, 6]), [6, 4, 6], "four listed: the oldest stays where it is")
        XCTAssertEqual(joined([6, 4, 6]), [6, 4, 6], "three listed: all of them, nothing more to take")
        XCTAssertEqual(joined([6, 4, 6, 4, 6]).count, 4)
    }

}
