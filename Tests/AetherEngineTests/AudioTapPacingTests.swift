import XCTest
@testable import AetherEngine

/// #95: pure pacing core for the loopback audio tap reader. The reader decodes the engine's own
/// fMP4 segments near the playhead; this decision function is the only piece that decides whether
/// to decode the next segment, idle, or re-anchor after the playhead moved away.
final class AudioTapPacingTests: XCTestCase {

    private func decide(_ last: Double?, _ playhead: Double,
                        previous: Double? = nil) -> AudioTapPacing.Decision {
        AudioTapPacing.decide(lastDecodedEndPTS: last, playhead: playhead, previousPlayhead: previous,
                              leadSeconds: 10, toleranceSeconds: 2)
    }

    func testFreshInstallDecodesImmediately() {
        XCTAssertEqual(decide(nil, 0), .decodeNext)
        XCTAssertEqual(decide(nil, 3512.4), .decodeNext)
    }

    func testWithinLeadKeepsDecoding() {
        XCTAssertEqual(decide(105.0, 100.0), .decodeNext)   // 5 s ahead, lead is 10
        XCTAssertEqual(decide(100.5, 100.0), .decodeNext)
    }

    func testAtLeadBoundarySleeps() {
        XCTAssertEqual(decide(110.0, 100.0), .sleep)
        XCTAssertEqual(decide(111.5, 100.0), .sleep)        // inside lead + tolerance
    }

    func testFellBehindReanchors() {
        // Forward seek: playhead jumped past everything we decoded.
        XCTAssertEqual(decide(100.0, 300.0), .reanchor)
        // Just past tolerance counts.
        XCTAssertEqual(decide(97.9, 100.0), .reanchor)
    }

    func testBehindWithinToleranceStillDecodes() {
        XCTAssertEqual(decide(98.5, 100.0), .decodeNext)
    }

    func testPlayheadJumpedBackReanchors() {
        // Backward seek: the playhead itself moved back past the tolerance.
        XCTAssertEqual(decide(300.0, 100.0, previous: 290.0), .reanchor)
        XCTAssertEqual(decide(112.5, 100.0, previous: 102.5), .reanchor)
    }

    func testPlayheadBackWithinToleranceDoesNotReanchor() {
        XCTAssertEqual(decide(105.0, 100.0, previous: 101.5), .decodeNext)
    }

    func testWholeSegmentOvershootSleepsInsteadOfReanchoring() {
        // #864: a 15 s segment decoded at an unchanged playhead runs 24.9 s ahead. That is a
        // normal overshoot, not a seek.
        XCTAssertEqual(decide(120.0, 95.1, previous: 95.1), .sleep)
        XCTAssertEqual(decide(300.0, 100.0, previous: 99.75), .sleep)
    }
}
