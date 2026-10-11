import Testing
@testable import AetherEngine

@Suite("SWClockAnchorPolicy (#107 mid-stream-joined sources on the SW demux loop)")
struct SWClockAnchorPolicyTests {

    @Test("fresh load of a zero-based file keeps the load anchor (head-of-stream offset preserved)")
    func freshLoadZeroBased() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 0, firstSampleSeconds: 0.256)
        #expect(r.anchorSeconds == 0)
        #expect(r.sessionZeroSeconds == 0)
    }

    @Test("resume keeps the load anchor when the first sample lands at the resume position")
    func resumeAligned() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 1000, firstSampleSeconds: 1000.4)
        #expect(r.anchorSeconds == 1000)
        #expect(r.sessionZeroSeconds == 0)
    }

    @Test("mid-stream join anchors at the first sample PTS and exposes it as session zero")
    func midStreamJoin() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 0, firstSampleSeconds: 64000.5)
        #expect(r.anchorSeconds == 64000.5)
        #expect(r.sessionZeroSeconds == 64000.5)
    }

    @Test("deviating resume re-anchors and maps position relative to the requested start")
    func midStreamJoinWithResume() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 30, firstSampleSeconds: 53126)
        #expect(r.anchorSeconds == 53126)
        #expect(r.sessionZeroSeconds == 53096)
    }

    @Test("non-finite first sample PTS keeps the load anchor")
    func nonFiniteFirstSample() {
        for pts in [Double.nan, .infinity, -.infinity] {
            let r = SWClockAnchorPolicy.resolve(initialSeconds: 0, firstSampleSeconds: pts)
            #expect(r.anchorSeconds == 0)
            #expect(r.sessionZeroSeconds == 0)
        }
    }

    @Test("small negative first PTS stays on the load anchor")
    func smallNegativeFirstPts() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 0, firstSampleSeconds: -0.3)
        #expect(r.anchorSeconds == 0)
        #expect(r.sessionZeroSeconds == 0)
    }

    @Test("deviation exactly at the tolerance keeps the load anchor")
    func deviationAtTolerance() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 0, firstSampleSeconds: 2.0)
        #expect(r.anchorSeconds == 0)
        #expect(r.sessionZeroSeconds == 0)
    }

    @Test("deviation just past the tolerance re-anchors")
    func deviationPastTolerance() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 0, firstSampleSeconds: 2.01)
        #expect(r.anchorSeconds == 2.01)
        #expect(r.sessionZeroSeconds == 2.01)
    }

    @Test("session zero never goes negative when the stream starts before the anchor")
    func firstSampleBehindAnchor() {
        // A first sample far BEHIND the requested anchor (broken seek) still re-anchors
        // so samples present, but session zero clamps at 0 to keep positions monotonic.
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 64000, firstSampleSeconds: 10)
        #expect(r.anchorSeconds == 10)
        #expect(r.sessionZeroSeconds == 0)
    }

    // MARK: - Carrying a seek target back to the source axis

    @Test("a zero-based source seeks on the axis it already uses")
    func sourceSecondsIsIdentityWithoutAnOffset() {
        #expect(SWClockAnchorPolicy.sourceSeconds(forSession: 35.29, sessionZeroSeconds: 0) == 35.29)
        #expect(SWClockAnchorPolicy.sourceSeconds(forSession: 0, sessionZeroSeconds: 0) == 0)
    }

    @Test("a mid-stream-joined source seeks past its own first packet, not before it")
    func sourceSecondsCarriesTheOffset() {
        // The capture that found this: first PTS 24549.835 s, a 64 s file, and a
        // seek to 35.29 s of session time. Without the carry the demuxer is asked
        // for a timestamp six hours before the file begins and clamps to its start,
        // and the packet store's reservoir reads as the whole offset.
        let target = SWClockAnchorPolicy.sourceSeconds(
            forSession: 35.29,
            sessionZeroSeconds: 24_549.835
        )
        #expect(target == 24_585.125)
    }

    @Test("the carry is the inverse of the position the host publishes")
    func sourceSecondsRoundTripsThePublishedPosition() {
        let zero = 24_549.835
        for session in [0.0, 1.0, 35.29, 64.564] {
            let raw = SWClockAnchorPolicy.sourceSeconds(forSession: session, sessionZeroSeconds: zero)
            // `SoftwarePlaybackHost` publishes `max(0, raw - zero)`.
            #expect(abs(max(0, raw - zero) - session) < 1e-9)
        }
    }

    @Test("a target that cannot be expressed is passed through rather than made worse")
    func sourceSecondsRefusesNonsense() {
        #expect(SWClockAnchorPolicy.sourceSeconds(forSession: 10, sessionZeroSeconds: -5) == 10)
        #expect(SWClockAnchorPolicy.sourceSeconds(forSession: 10, sessionZeroSeconds: .nan) == 10)
        #expect(SWClockAnchorPolicy.sourceSeconds(forSession: .infinity, sessionZeroSeconds: 100).isInfinite)
    }
}
