import Testing
import Foundation
@testable import AetherEngine

/// AE#844: a software live join that keeps its cursor starts on the first keyframe past it, so the
/// clock does not run the audio of a partial GOP over a black screen.
@Suite("AE#844 live join keyframe alignment")
struct Issue844LiveJoinKeyframeAlignmentTests {
    typealias Policy = SoftwareLiveJoinPolicy

    @Test("a cursor on a keyframe stays")
    func keyframeCursorStays() {
        #expect(Policy.alignment(cursorSeq: 4, keyframe: (4, 10), wantedLead: 2.0, newestPts: 13.6,
                                 waited: 0, sourceEnded: false) == .stay)
    }

    @Test("a mid-GOP cursor moves to the keyframe once the lead holds")
    func midGOPSnapsWithLead() {
        // The HDMI join from the report: arm at 10.0, keyframe at 12.14, 3.6 s in the ring.
        #expect(Policy.alignment(cursorSeq: 0, keyframe: (130, 12.14), wantedLead: 2.0, newestPts: 14.2,
                                 waited: 0, sourceEnded: false) == .snap)
    }

    @Test("a move that would leave less than the resume lead waits for it")
    func shortLeadWaits() {
        #expect(Policy.alignment(cursorSeq: 0, keyframe: (170, 12.9), wantedLead: 2.0, newestPts: 13.6,
                                 waited: 0.5, sourceEnded: false) == .wait)
        #expect(Policy.alignment(cursorSeq: 0, keyframe: (170, 12.9), wantedLead: 2.0, newestPts: 15.0,
                                 waited: 1.3, sourceEnded: false) == .snap)
    }

    @Test("the lead asked for is never more than the unmoved start had")
    func shallowRingAsksOnlyForItsOwnLead() {
        // A real-time tuner decided at 0.3 s: the unmoved start had 0.5 s, so 0.5 s past the keyframe do.
        #expect(Policy.alignment(cursorSeq: 0, keyframe: (60, 51.25), wantedLead: 0.5, newestPts: 51.5,
                                 waited: 1.2, sourceEnded: false) == .wait)
        #expect(Policy.alignment(cursorSeq: 0, keyframe: (70, 51.25), wantedLead: 0.5, newestPts: 51.75,
                                 waited: 1.6, sourceEnded: false) == .snap)
    }

    @Test("the lead a move keeps is the unmoved start's, capped at the resume lead")
    func alignmentLeadIsTheUnmovedStarts() {
        #expect(Policy.alignmentLead(cursorPts: 10, newestPts: 13.6) == AudioLookaheadPolicy.rebufferResumeLeadSeconds)
        #expect(Policy.alignmentLead(cursorPts: 50, newestPts: 50.25) == 0.25)
        #expect(Policy.alignmentLead(cursorPts: nil, newestPts: 50) == nil)
        #expect(Policy.alignmentLead(cursorPts: 50, newestPts: .nan) == nil)
    }

    @Test("no keyframe yet waits, then starts where it stood")
    func noKeyframeWaitsThenStays() {
        #expect(Policy.alignment(cursorSeq: 0, keyframe: nil, wantedLead: 0.5, newestPts: 51,
                                 waited: 1, sourceEnded: false) == .wait)
        #expect(Policy.alignment(cursorSeq: 0, keyframe: nil, wantedLead: 0.5, newestPts: 53,
                                 waited: Policy.maximumAlignmentWaitSeconds, sourceEnded: false) == .stay)
        #expect(Policy.alignment(cursorSeq: 0, keyframe: nil, wantedLead: 0.5, newestPts: 51,
                                 waited: 0.1, sourceEnded: true) == .stay)
    }

    @Test("the deadline or the source's end moves to a keyframe without its lead")
    func deadlineSnapsWithoutLead() {
        #expect(Policy.alignment(cursorSeq: 0, keyframe: (170, 12.9), wantedLead: 2.0, newestPts: 13,
                                 waited: Policy.maximumAlignmentWaitSeconds, sourceEnded: false) == .snap)
        #expect(Policy.alignment(cursorSeq: 0, keyframe: (170, 12.9), wantedLead: 2.0, newestPts: 13,
                                 waited: 0.1, sourceEnded: true) == .snap)
    }

    @Test("without a ring, audio before the first keyframe is dropped until the wait or the span runs out")
    func ringlessJoinDropsAudioWithinBounds() {
        #expect(Policy.dropsAudioBeforeFirstKeyframe(waited: 0, droppedSpanSeconds: 0))
        #expect(Policy.dropsAudioBeforeFirstKeyframe(waited: 0.1, droppedSpanSeconds: 2.9))
        #expect(!Policy.dropsAudioBeforeFirstKeyframe(waited: Policy.maximumAlignmentWaitSeconds,
                                                      droppedSpanSeconds: 3))
        // A burst covers the media long before the wait: a stream that flags no keyframe keeps its lead.
        #expect(!Policy.dropsAudioBeforeFirstKeyframe(waited: 0.2,
                                                      droppedSpanSeconds: Policy.maximumAlignmentSkipSeconds))
        // An unknown timestamp does not end the drop on its own.
        #expect(Policy.dropsAudioBeforeFirstKeyframe(waited: 0.2, droppedSpanSeconds: .nan))
    }

    @Test("the ring finds the first keyframe at or after a sequence from its index")
    func ringKeyframeAtOrAfter() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ae844-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ring = try PacketRingBuffer(windowSeconds: 60, scratch: dir)
        defer { ring.close() }
        // A join mid-GOP: audio and P frames first, keyframes at 2.0 and 4.0.
        for i in 0..<12 {
            let pts = Double(i) * 0.5
            try ring.append(pts: pts, isKeyframe: false, isVideo: false, bytes: Data([0]))
            try ring.append(pts: pts, isKeyframe: pts == 2 || pts == 4, isVideo: true, bytes: Data([1]))
        }
        let first = ring.seqBounds.first
        let k1 = try #require(ring.keyframe(atOrAfterSeq: first))
        #expect(k1.pts == 2)
        #expect(ring.pts(atSeq: k1.seq) == 2)
        #expect(ring.keyframe(atOrAfterSeq: k1.seq)?.seq == k1.seq)
        #expect(ring.keyframe(atOrAfterSeq: k1.seq + 1)?.pts == 4)
        #expect(ring.keyframe(atOrAfterSeq: ring.seqBounds.end) == nil)
        #expect(ring.pts(atSeq: ring.seqBounds.end) == nil)
    }
}
