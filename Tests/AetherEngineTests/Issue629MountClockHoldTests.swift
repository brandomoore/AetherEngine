import Foundation
import Testing
@testable import AetherEngine

/// AE#629 round 5 (cmcpherson274, 2026-10-01): the #646 clock hold covered only an in-place swap. A VOD
/// item a host `load()` mounted at 15.90 s published AVPlayer's pre-landing reading, the start of the
/// segment it decodes up from (12.00 s), and once that load had returned nothing parked the 15.90 s any
/// more. AVPlayer refused the item before the mount seek landed, the software rebuild resumed at 12.00 s
/// and the film replayed 3.9 s after the rescue.
@Suite("A mount holds the clock until its mount seek lands")
struct Issue629MountClockHoldTests {

    @Test("Every seeking swap holds, a fresh mount only on VOD past the head")
    func whichMountsHold() {
        #expect(NativeAVPlayerHost.mountHoldsClock(inPlaceSwap: true, skipInitialSeek: false,
                                                    startPosition: 15.9, isLive: false))
        #expect(NativeAVPlayerHost.mountHoldsClock(inPlaceSwap: true, skipInitialSeek: false,
                                                    startPosition: nil, isLive: true))
        #expect(NativeAVPlayerHost.mountHoldsClock(inPlaceSwap: false, skipInitialSeek: false,
                                                    startPosition: 15.9, isLive: false))
        #expect(!NativeAVPlayerHost.mountHoldsClock(inPlaceSwap: false, skipInitialSeek: false,
                                                     startPosition: 0, isLive: false))
        #expect(!NativeAVPlayerHost.mountHoldsClock(inPlaceSwap: false, skipInitialSeek: false,
                                                     startPosition: nil, isLive: false))
        #expect(!NativeAVPlayerHost.mountHoldsClock(inPlaceSwap: false, skipInitialSeek: false,
                                                     startPosition: 15.9, isLive: true))
        #expect(!NativeAVPlayerHost.mountHoldsClock(inPlaceSwap: true, skipInitialSeek: true,
                                                     startPosition: nil, isLive: true))
    }

    @Test("A fresh VOD mount past the head reads its mount position before the item answers")
    @MainActor
    func freshMountStatesItsPosition() {
        let host = NativeAVPlayerHost()
        host.load(url: URL(string: "http://127.0.0.1:1/vod/media.m3u8")!, startPosition: 15.9,
                  contract: .init())
        #expect(host.currentTime == 15.9)
        #expect(host.renderedTime == 15.9)
        // What the escalation rung resumes at once the host's load has returned.
        #expect(AetherEngine.rebuildPosition(state: .playing, clock: host.currentTime,
                                             underReconstruction: 15.9) == 15.9)
    }

    @Test("A mount at the head and a live mount publish nothing ahead of the item")
    @MainActor
    func otherMountsWaitForTheItem() {
        let host = NativeAVPlayerHost()
        host.load(url: URL(string: "http://127.0.0.1:1/vod/media.m3u8")!, startPosition: 0,
                  contract: .init())
        #expect(host.currentTime == 0)
        host.load(url: URL(string: "http://127.0.0.1:1/live/media.m3u8")!, startPosition: 30,
                  contract: .init(isLive: true))
        #expect(host.currentTime == 0)
    }
}

/// AE#881 (martijnklomp, 7.47.0): a VOD mounted at 6 s and played read 6.000, then 0.000 for one
/// sample, then 6.000 again. AVPlayer finished the mount seek in the millisecond it was issued, long
/// before the item was ready, so that completion released the AE#629 hold and the periodic observer
/// published the keyframe the start position falls behind.
@Suite("A mount seek finished before the item is ready does not release the clock")
struct Issue881EarlyMountSeekCompletionTests {

    @Test("Only a completion on a ready item is a landing")
    func completionBeforeReadinessHolds() {
        #expect(!NativeAVPlayerHost.mountSeekCompletionLands(itemIsReadyToPlay: false))
        #expect(NativeAVPlayerHost.mountSeekCompletionLands(itemIsReadyToPlay: true))
    }
}
