import XCTest
import AVFAudio
@testable import AetherEngine

/// #95: loop logic of the loopback reader, driven step-by-step with stubbed dependencies.
/// No media involved; decode is stubbed to return a segment's worth of chunks on its timeline.
final class LoopbackAudioReaderTests: XCTestCase {

    /// Mutable stub world shared with the closures. Single-threaded in these tests.
    final class World: @unchecked Sendable {
        var playhead: Double? = 0
        var shift: Double = 0
        var segments: Set<Int> = []          // resident segment indices
        var highestStored = -1
        var decoded: [Int] = []              // one entry per decode call
        var emitted: [AudioTapBuffer] = []
        var segmentSeconds: Double = 1.0
        var chunkSeconds: Double = 1.0
    }

    private func makeReader(_ w: World) -> LoopbackAudioReader {
        let deps = LoopbackAudioReader.Dependencies(
            playhead: { w.playhead },
            shiftSeconds: { w.shift },
            anchorIndex: { Int($0 / w.segmentSeconds) },
            initData: { _ in Data([0]) },
            segmentData: { w.segments.contains($0) ? Data(String($0).utf8) : nil },
            highestStoredIndex: { w.highestStored },
            decodeSegment: { _, segment in
                let idx = Int(String(decoding: segment, as: UTF8.self))!
                w.decoded.append(idx)
                // One segment as chunkSeconds-long chunks, like the real decoder's coalescing.
                let frames = AVAudioFrameCount(w.chunkSeconds * 48_000)
                let count = Int((w.segmentSeconds / w.chunkSeconds).rounded())
                return (0..<count).map { n in
                    let buf = AVAudioPCMBuffer(pcmFormat: AetherEngine.audioTapFormat,
                                               frameCapacity: frames)!
                    buf.frameLength = frames
                    return AudioTapChunk(buffer: buf, ptsSeconds: Double(idx) * w.segmentSeconds
                                         + Double(n) * w.chunkSeconds)
                }
            },
            emit: { w.emitted.append($0) }
        )
        return LoopbackAudioReader(deps: deps)
    }

    func testDecodesForwardWithinLeadThenSleeps() {
        let w = World()
        w.segments = Set(0...30); w.highestStored = 30
        let reader = makeReader(w)
        // Lead is 10 s and each segment is 1 s: expect 10 decode steps, then a sleep.
        for _ in 0..<10 { XCTAssertEqual(reader.runOnce(), .decoded) }
        XCTAssertEqual(reader.runOnce(), .slept)
        XCTAssertEqual(w.emitted.count, 10)
        // First buffer after install is a discontinuity, the rest abut.
        XCTAssertTrue(w.emitted[0].discontinuity)
        XCTAssertFalse(w.emitted[1].discontinuity)
    }

    func testSourceTimeFoldsShift() {
        let w = World()
        w.segments = Set(0...5); w.highestStored = 5
        w.shift = 42.0
        let reader = makeReader(w)
        XCTAssertEqual(reader.runOnce(), .decoded)
        XCTAssertEqual(w.emitted[0].sourceTime, 42.0, accuracy: 0.001)
    }

    func testNotYetProducedSleepsInsteadOfSkipping() {
        let w = World()
        w.segments = [0]; w.highestStored = 0
        let reader = makeReader(w)
        XCTAssertEqual(reader.runOnce(), .decoded)
        // Segment 1 not produced yet (beyond highestStored): wait, do not skip.
        XCTAssertEqual(reader.runOnce(), .slept)
    }

    func testEvictedSegmentSkipsForwardWithDiscontinuity() {
        let w = World()
        w.segments = Set(0...10).subtracting([1]); w.highestStored = 10
        let reader = makeReader(w)
        XCTAssertEqual(reader.runOnce(), .decoded)    // seg 0
        // Seg 1 missing but below highestStored: repeated misses then skip to seg 2.
        for _ in 0..<LoopbackAudioReader.maxMissStreak { XCTAssertEqual(reader.runOnce(), .slept) }
        XCTAssertEqual(reader.runOnce(), .decoded)    // seg 2 after skip
        XCTAssertTrue(w.emitted.last!.discontinuity)
    }

    func testPlayheadJumpReanchors() {
        let w = World()
        w.segments = Set(0...400); w.highestStored = 400
        let reader = makeReader(w)
        XCTAssertEqual(reader.runOnce(), .decoded)
        w.playhead = 300.0                             // far forward seek
        XCTAssertEqual(reader.runOnce(), .reanchored)
        XCTAssertEqual(reader.runOnce(), .decoded)
        XCTAssertTrue(w.emitted.last!.discontinuity)
    }

    /// #864 reporter's case: 15 s segments, playhead parked at 95.1. Decoding 105..120 runs the
    /// lead to 24.9 s, which used to read as a backward seek and re-decode 6 and 7 forever.
    func testLongSegmentsDoNotReanchorWithoutPlayheadMovement() {
        let w = World()
        w.segments = Set(0...100); w.highestStored = 100
        w.segmentSeconds = 15; w.chunkSeconds = 15
        w.playhead = 95.1
        let reader = makeReader(w)
        for _ in 0..<12 { _ = reader.runOnce() }
        XCTAssertEqual(w.decoded, [6, 7])
    }

    /// #864: a long segment is not yielded in one burst. With 100 ms chunks the consumer never
    /// has more than tolerance + lead in flight, and the rest follows the playhead.
    func testLongSegmentIsReleasedAlongTheLead() {
        let w = World()
        w.segments = Set(0...100); w.highestStored = 100
        w.segmentSeconds = 15; w.chunkSeconds = 0.1
        w.playhead = 95.1
        let reader = makeReader(w)
        for _ in 0..<12 { _ = reader.runOnce() }
        XCTAssertEqual(w.decoded, [6, 7])
        // Anchor head before 93.1 is dropped; released through 105.1.
        let first = w.emitted.first!, last = w.emitted.last!
        XCTAssertTrue(first.discontinuity)
        XCTAssertEqual(first.sourceTime, 93.0, accuracy: 0.001)
        XCTAssertEqual(last.sourceTime, 105.0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(w.emitted.count, 121)
        XCTAssertLessThan(w.emitted.count, AudioTapController.streamCapacity)

        w.playhead = 100.0
        for _ in 0..<4 { _ = reader.runOnce() }
        XCTAssertEqual(w.decoded, [6, 7])
        XCTAssertEqual(w.emitted.last!.sourceTime, 109.9, accuracy: 0.001)
        // Gap-free and non-repeating past the anchor.
        for (a, b) in zip(w.emitted, w.emitted.dropFirst()) {
            XCTAssertEqual(b.sourceTime - a.sourceTime, 0.1, accuracy: 0.0001)
            XCTAssertFalse(b.discontinuity)
        }
    }

    /// #863 (jpsts): 10 s segments played forward for 60 s. Each segment is decoded once, in
    /// order, without a reanchor, and the released audio is gap-free behind a lead that holds.
    func testLongSegmentsAreDecodedOnceEachAsThePlayheadMovesOn() {
        let w = World()
        w.segments = Set(0...30); w.highestStored = 30
        w.segmentSeconds = 10; w.chunkSeconds = 1
        let reader = makeReader(w)
        var steps: [LoopbackAudioReader.StepResult] = []
        var playhead = 0.0
        while playhead < 60 {
            w.playhead = playhead
            steps.append(reader.runOnce())
            playhead += 0.25
        }
        XCTAssertFalse(steps.contains(.reanchored))
        XCTAssertEqual(w.decoded, Array(0..<w.decoded.count))
        XCTAssertGreaterThanOrEqual(w.decoded.count, 7)
        XCTAssertEqual(w.emitted.filter(\.discontinuity).count, 1)
        for (a, b) in zip(w.emitted, w.emitted.dropFirst()) {
            XCTAssertEqual(b.sourceTime - a.sourceTime, 1, accuracy: 0.0001)
        }
        let last = w.emitted.last!.sourceTime
        XCTAssertGreaterThanOrEqual(last, 59.75)
        XCTAssertLessThanOrEqual(last, 59.75 + AudioTapDefaults.leadSeconds)
    }

    func testBackwardSeekReanchors() {
        let w = World()
        w.segments = Set(0...100); w.highestStored = 100
        w.segmentSeconds = 15; w.chunkSeconds = 15
        w.playhead = 95.1
        let reader = makeReader(w)
        for _ in 0..<4 { _ = reader.runOnce() }
        XCTAssertEqual(w.decoded, [6, 7])
        w.playhead = 31.0
        XCTAssertEqual(reader.runOnce(), .reanchored)
        XCTAssertEqual(reader.runOnce(), .decoded)
        XCTAssertEqual(w.decoded.last, 2)
        XCTAssertTrue(w.emitted.last!.discontinuity)
    }

    /// Review of #864: a forward seek between the reanchor and the anchor decode drops that whole
    /// segment. Its end still counts, so the next step reanchors instead of walking stale segments.
    func testForwardSeekBeforeAnchorDecodeReanchors() {
        let w = World()
        w.segments = Set(0...100); w.highestStored = 100
        w.segmentSeconds = 15; w.chunkSeconds = 0.1
        w.playhead = 95.1
        let reader = makeReader(w)
        for _ in 0..<4 { _ = reader.runOnce() }
        w.playhead = 400.0
        XCTAssertEqual(reader.runOnce(), .reanchored)    // nextIndex = 26
        w.playhead = 1000.0                              // seek again before 26 decodes
        _ = reader.runOnce()                             // decodes 26, all of it behind
        XCTAssertEqual(reader.runOnce(), .reanchored)
        XCTAssertEqual(reader.runOnce(), .decoded)
        XCTAssertEqual(w.decoded.last, 66)
        XCTAssertTrue(w.emitted.last.map { $0.sourceTime >= 998 } ?? false)
    }
}
