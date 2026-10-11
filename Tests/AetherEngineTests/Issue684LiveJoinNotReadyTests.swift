// Tests/AetherEngineTests/Issue684LiveJoinNotReadyTests.swift
// AE#684: the AE#440 forced start was taken on a rejoin item that could not play yet. The capture:
//
//     14:51:15.650  #454 placing the fresh item at 31871.11s in its own playlist: segment 26 + 1.91s
//     14:51:15.716  #7 AE#440 live join: leaving the stall-avoidance wait alone (buffer ahead 0.00s,
//                   empty=true ...) (playhead 48.00s), and the item's own status has not left unknown
//     14:51:15.731  #7 AE#440 live join: cutting the stall-avoidance wait short at rate 1.0
//                   (buffer ahead 4.00s)
//     14:51:15.767  #7 item.status=readyToPlay
//     14:51:15.778  #454 the playlist already placed this item at its own 53.91s
//
// The item was placed at 53.908 s by `EXT-X-START`, AVPlayer fetched from 48.00 s first (its own
// lookback), and the guard measured its cushion from `currentTime()`, which before readiness is that
// 48.00 s: two fetched segments, 4.00 s, all of it behind the point playback was about to start at.
// It is the only one of the five item starts in that capture the engine forced, and the one the
// viewer reported out of sync. AE#440 round 7 had named the shape before any capture showed it.
import AVFoundation
import Testing
@testable import AetherEngine

@Suite("AE#684: the AE#440 start is not forced on an item that cannot play yet")
struct Issue684LiveJoinNotReadyTests {

    @Test("the captured reading is refused: 4.00 s ahead of a playhead the item has not taken yet")
    func refusesTheCapturedReading() {
        #expect(!NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false, bufferedAheadSeconds: 4.0,
            itemIsReadyToPlay: false))
    }

    @Test("the same hold on a ready item is still the case AE#440 exists for")
    func firesOnceTheItemCanPlay() {
        #expect(NativeAVPlayerHost.shouldStartLiveJoinImmediately(
            armed: true, alreadySpent: false, hostWantsToPlay: true,
            isWaitingToMinimizeStalls: true, playbackBufferEmpty: false, bufferedAheadSeconds: 4.0,
            itemIsReadyToPlay: true))
    }

    /// The reading is asynchronous and the readiness sink's question is dropped while one is in
    /// flight, so a refusal taken on a stale `unknown` has to notice the item is ready now.
    @Test("a not-ready refusal asks once more when the item turned ready under it")
    func asksAgainOnceWhenTheItemTurnedReady() {
        #expect(NativeAVPlayerHost.liveJoinAsksAgainAfterNotReadyRefusal(
            readingWasNotReady: true, itemIsReadyNow: true, alreadyAskedAgain: false))
        #expect(!NativeAVPlayerHost.liveJoinAsksAgainAfterNotReadyRefusal(
            readingWasNotReady: true, itemIsReadyNow: false, alreadyAskedAgain: false))
        #expect(!NativeAVPlayerHost.liveJoinAsksAgainAfterNotReadyRefusal(
            readingWasNotReady: true, itemIsReadyNow: true, alreadyAskedAgain: true))
    }

    /// A reading that is both thin and not ready is no less stale than a deep one: the item it was
    /// taken on could not say where it starts. It keeps the thin-buffer line and still asks again.
    @Test("a thin reading on a not-ready item asks again too, and a refusal on a ready item does not")
    func thinAndNotReadyStillAsksAgain() {
        let thin = NativeAVPlayerHost.LiveJoinBufferReading(
            bufferEmpty: true, aheadSeconds: 0, playheadSeconds: 48.0,
            loadedRangeCount: 0, nearestRangeOffsetSeconds: nil, itemStatus: .unknown)
        #expect(NativeAVPlayerHost.liveJoinNotReadyRefusal(reading: thin) == nil)
        #expect(NativeAVPlayerHost.liveJoinAsksAgainAfterNotReadyRefusal(
            readingWasNotReady: thin.itemStatus != .readyToPlay, itemIsReadyNow: true,
            alreadyAskedAgain: false))
        #expect(!NativeAVPlayerHost.liveJoinAsksAgainAfterNotReadyRefusal(
            readingWasNotReady: false, itemIsReadyNow: true, alreadyAskedAgain: false))
    }

    @Test("the refusal names the playhead the cushion was read from")
    func refusalNamesThePlayhead() throws {
        let reading = NativeAVPlayerHost.LiveJoinBufferReading(
            bufferEmpty: false, aheadSeconds: 4.0, playheadSeconds: 48.0,
            loadedRangeCount: 1, nearestRangeOffsetSeconds: nil, itemStatus: .unknown)
        let line = try #require(NativeAVPlayerHost.liveJoinNotReadyRefusal(reading: reading))
        #expect(line.contains("buffer ahead 4.00s of playhead 48.00s"))
        #expect(line.contains("cannot play yet"))
        #expect(line.contains("asked again at readiness"))
    }

    /// The thin-buffer line already accounts for these; a second line would say the same refusal twice.
    @Test("no extra line for a refusal the depth explains, or for a ready item")
    func refusalIsOnlyForTheDepthThatWouldHaveFired() {
        let thin = NativeAVPlayerHost.LiveJoinBufferReading(
            bufferEmpty: true, aheadSeconds: 0, playheadSeconds: 48.0,
            loadedRangeCount: 0, nearestRangeOffsetSeconds: nil, itemStatus: .unknown)
        #expect(NativeAVPlayerHost.liveJoinNotReadyRefusal(reading: thin) == nil)
        let ready = NativeAVPlayerHost.LiveJoinBufferReading(
            bufferEmpty: false, aheadSeconds: 4.0, playheadSeconds: 53.908,
            loadedRangeCount: 1, nearestRangeOffsetSeconds: nil, itemStatus: .readyToPlay)
        #expect(NativeAVPlayerHost.liveJoinNotReadyRefusal(reading: ready) == nil)
    }
}
