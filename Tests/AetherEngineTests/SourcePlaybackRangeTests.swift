import AVFoundation
import Testing
@testable import AetherEngine

@MainActor
struct SourcePlaybackRangeTests {
    @Test func mountingRecordsIntentWithoutStartingUnboundedPlayback() {
        let host = NativeAVPlayerHost()
        host.authoredMountPending = true
        host.play()
        #expect(host.transportIntentIsPlaying)
        #expect(host.avPlayer.rate == 0)
        host.setRate(2)
        #expect(host.transportIntentIsPlaying)
        #expect(host.avPlayer.rate == 0)
        host.pause()
        #expect(!host.transportIntentIsPlaying)
    }

    @Test func boundsUseTheRendererTimebaseAndClearForOrdinaryPlayback() {
        let host = NativeAVPlayerHost()
        let item = AVPlayerItem(asset: AVMutableComposition())
        host.authoredPlaybackRange = 0.959..<1.001
        host.applyAuthoredPlaybackRange(to: item)
        #expect(item.reversePlaybackEndTime == CMTime(value: 86_310, timescale: 90_000))
        #expect(item.forwardPlaybackEndTime == CMTime(value: 90_090, timescale: 90_000))
        host.authoredPlaybackRange = nil
        host.applyAuthoredPlaybackRange(to: item)
        #expect(!item.reversePlaybackEndTime.isValid)
        #expect(!item.forwardPlaybackEndTime.isValid)
    }

    @Test func sourceBoundsFollowPresentationEpochs() {
        let engine = AetherEngine()
        let host = NativeAVPlayerHost()
        engine.nativeHost = host
        var options = LoadOptions()
        options.nativeSourcePlaybackRange = 600.959..<601.001
        engine.setLoadedOptionsForTesting(options)
        engine.setPresentationAxis(.anchored(shiftSeconds: 600))
        #expect(abs((host.authoredPlaybackRange?.lowerBound ?? -1) - 0.959) < 0.000001)
        #expect(abs((host.authoredPlaybackRange?.upperBound ?? -1) - 1.001) < 0.000001)
        engine.setPresentationAxis(.anchored(shiftSeconds: 599))
        #expect(abs((host.authoredPlaybackRange?.lowerBound ?? -1) - 1.959) < 0.000001)
        #expect(abs((host.authoredPlaybackRange?.upperBound ?? -1) - 2.001) < 0.000001)
    }
}
