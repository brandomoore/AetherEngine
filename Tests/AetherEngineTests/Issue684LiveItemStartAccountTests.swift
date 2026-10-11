// Tests/AetherEngineTests/Issue684LiveItemStartAccountTests.swift
// AE#684, second half: a viewer saw sound and picture slightly apart after an item rebuild placed
// mid-segment (`segment 26 + 1.91s`) and together again after the next one (`segment 129 + 0.03s`).
// The served media measures aligned and macOS cannot observe AVPlayer's audio renderer, so the session
// states what each native live item started on: the segment, the offset into it, and where that
// segment's sound begins against its picture. These pin the line and the lookup it reads.
import XCTest
@testable import AetherEngine

final class Issue684LiveItemStartAccountTests: XCTestCase {

    func testAccountNamesThePlacementAndTheSoundAgainstThePicture() {
        let line = AetherEngine.liveItemStartAccount(
            item: 7, itemSeconds: 53.908,
            heads: (index: 26, secondsIntoSegment: 1.908, pictureStart: 52.0, sound: (first: 51.921, last: 53.905)))
        XCTAssertTrue(line.contains("#684 item #7 starts at its own 53.908s"), line)
        XCTAssertTrue(line.contains("segment 26 + 1.908s"), line)
        XCTAssertTrue(line.contains("picture opens at 52.000s"), line)
        XCTAssertTrue(line.contains("sound runs 51.921..53.905s"), line)
        XCTAssertTrue(line.contains("opens 79 ms before the picture"), line)
    }

    func testAccountSaysWhenTheSoundOpensAfterThePicture() {
        let line = AetherEngine.liveItemStartAccount(
            item: 1, itemSeconds: 6.0,
            heads: (index: 3, secondsIntoSegment: 0, pictureStart: 6.0, sound: (first: 6.013, last: 7.997)))
        XCTAssertTrue(line.contains("opens 13 ms after the picture"), line)
    }

    /// An absence is stated, not printed as a zero that would read as "aligned".
    func testAccountDoesNotInventWhatWasNotRecorded() {
        let unrecorded = AetherEngine.liveItemStartAccount(
            item: 2, itemSeconds: 4.0,
            heads: (index: 2, secondsIntoSegment: 0, pictureStart: 4.0, sound: nil))
        XCTAssertTrue(unrecorded.contains("sound was not recorded"), unrecorded)
        XCTAssertFalse(unrecorded.contains(" ms "), unrecorded)
        let unlisted = AetherEngine.liveItemStartAccount(item: 2, itemSeconds: 400.0, heads: nil)
        XCTAssertTrue(unlisted.contains("in no segment the producer lists yet"), unlisted)
    }

    func testProviderResolvesAPositionToItsSegmentAndItsSound() throws {
        let provider = VideoSegmentProvider(
            cache: SegmentCache(forwardWindow: 10, backwardWindow: 10),
            segments: [],
            codecsString: "avc1.4D001E,mp4a.40.2",
            supplementalCodecs: nil,
            resolution: (720, 576),
            videoRange: .sdr,
            frameRate: 25,
            hdcpLevel: nil,
            sourceBitrate: 1_500_000,
            isLive: true,
            liveWindowSizing: LiveWindowSizing(targetSegmentDurationSeconds: 0.5, dvrWindowSeconds: nil),
            liveCadencePolicy: nil
        )
        for index in 0..<4 {
            provider.appendLiveSegment(index: index, startSeconds: Double(index) * 2, durationSeconds: 2)
            provider.noteLiveSegmentSound(index: index,
                                          firstSeconds: Double(index) * 2 - 0.079,
                                          lastSeconds: Double(index) * 2 + 1.899)
        }
        let heads = try XCTUnwrap(provider.liveSegmentHeads(atOutputSeconds: 5.908))
        XCTAssertEqual(heads.index, 2)
        XCTAssertEqual(heads.secondsIntoSegment, 1.908, accuracy: 1e-9)
        XCTAssertEqual(heads.pictureStart, 4.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(heads.sound).first, 3.921, accuracy: 1e-9)
        XCTAssertNil(provider.liveSegmentHeads(atOutputSeconds: 8.5), "past the last listed segment")
    }
}
