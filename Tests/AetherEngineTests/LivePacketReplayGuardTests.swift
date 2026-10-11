import Foundation
import XCTest
@testable import AetherEngine

final class LivePacketReplayGuardTests: XCTestCase {
    private func packet(_ stream: LivePacketReplayGuard.Stream, _ tick: Int64,
                        payload: UInt8? = nil) -> LivePacketReplayGuard.Signature {
        .init(stream: stream, dts: tick, pts: tick,
              payload: Data([payload ?? UInt8(truncatingIfNeeded: tick), 0xA5]))
    }

    func testExactVideoAndAudioReplayResumesAtFirstNewPackets() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<40 {
            guard_.record(packet(.video, Int64(tick)), sourceSeconds: Double(tick))
            guard_.record(packet(.audio, Int64(tick)), sourceSeconds: Double(tick))
        }

        for tick in 20..<40 {
            let video = guard_.inspect(packet(.video, Int64(tick)), sourceSeconds: Double(tick),
                                       timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
            XCTAssertTrue(video.drop)
            if tick == 20 { XCTAssertEqual(video.event, .began) }
            let audio = guard_.inspect(packet(.audio, Int64(tick)), sourceSeconds: Double(tick),
                                       timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
            XCTAssertTrue(audio.drop)
        }

        let newVideo = guard_.inspect(packet(.video, 40), sourceSeconds: 40,
                                      timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
        XCTAssertFalse(newVideo.drop)
        XCTAssertNil(newVideo.event)
        let newAudio = guard_.inspect(packet(.audio, 40), sourceSeconds: 40,
                                      timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
        XCTAssertFalse(newAudio.drop)
        XCTAssertEqual(newAudio.event, .finished(videoPackets: 20, audioPackets: 20,
                                                 videoSeconds: 19))
        XCTAssertFalse(guard_.isDroppingReplay)
    }

    func testClockResetWithNewContentNeverDropsAFrame() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<40 {
            guard_.record(packet(.video, Int64(tick)), sourceSeconds: Double(tick))
        }
        let result = guard_.inspect(packet(.video, 20, payload: 0xFF), sourceSeconds: 20,
                                    timeBaseSeconds: 1, videoFrontier: 39,
                                    audioFrontier: Int64.min)
        XCTAssertFalse(result.drop)
        XCTAssertNil(result.event)
    }

    func testAudioCanReachTheOverlapBeforeVideo() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<40 {
            guard_.record(packet(.video, Int64(tick)), sourceSeconds: Double(tick))
            guard_.record(packet(.audio, Int64(tick)), sourceSeconds: Double(tick))
        }
        let firstAudio = guard_.inspect(packet(.audio, 20), sourceSeconds: 20,
                                        timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
        XCTAssertTrue(firstAudio.drop)
        XCTAssertEqual(firstAudio.event, .began)
        XCTAssertTrue(guard_.inspect(packet(.video, 20), sourceSeconds: 20,
                                     timeBaseSeconds: 1, videoFrontier: 39,
                                     audioFrontier: 39).drop)
    }

    func testFirstDifferentPacketInsideReplayIsForwarded() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<40 {
            guard_.record(packet(.video, Int64(tick)), sourceSeconds: Double(tick))
        }
        XCTAssertTrue(guard_.inspect(packet(.video, 20), sourceSeconds: 20,
                                     timeBaseSeconds: 1, videoFrontier: 39,
                                     audioFrontier: Int64.min).drop)
        let different = guard_.inspect(packet(.video, 21, payload: 0xFF), sourceSeconds: 21,
                                       timeBaseSeconds: 1, videoFrontier: 39,
                                       audioFrontier: Int64.min)
        XCTAssertFalse(different.drop)
        XCTAssertEqual(different.event, .mismatch(videoPackets: 1, audioPackets: 0))
    }

    func testOldHistoryCannotSuppressNewContent() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<100 {
            guard_.record(packet(.video, Int64(tick)), sourceSeconds: Double(tick))
        }
        let old = guard_.inspect(packet(.video, 20), sourceSeconds: 20,
                                 timeBaseSeconds: 1, videoFrontier: 99,
                                 audioFrontier: Int64.min)
        XCTAssertFalse(old.drop)
    }
}
