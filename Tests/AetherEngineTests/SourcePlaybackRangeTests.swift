import AVFoundation
import Testing
@testable import AetherEngine

@MainActor
struct SourcePlaybackRangeTests {
    @Test func unsupportedIntervalsHaveAStableFailureKind() throws {
        let engine = try AetherEngine()
        engine.publishLoadFailure(AetherEngineError.authoredPlaybackIntervalUnsupported)
        #expect(engine.errorInfo?.kind == .authoredPlaybackIntervalUnsupported)
    }

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

    @Test func sourceBoundsFollowPresentationEpochs() throws {
        let engine = try AetherEngine()
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

    @Test func rebasedBoundAtOrBeyondFiniteDurationUsesNaturalEOF() {
        let duration = CMTime(seconds: 8.004, preferredTimescale: 90_000)
        let before = NativeAVPlayerHost.authoredForwardEndTime(3.994..<7.994, duration: duration)
        #expect(before == CMTime(seconds: 7.994, preferredTimescale: 90_000))
        #expect(!NativeAVPlayerHost.authoredForwardEndTime(4.004..<8.004, duration: duration).isValid)
        #expect(!NativeAVPlayerHost.authoredForwardEndTime(4.021..<8.021, duration: duration).isValid)
        #expect(!NativeAVPlayerHost.authoredForwardEndTime(nil, duration: duration).isValid)
    }

    @Test func shortIntervalKeepsItsRendererBoundaryWithUnknownOrLongerDuration() {
        let expected = CMTime(value: 185_880, timescale: 90_000)
        for duration in [CMTime.invalid, .indefinite, .zero, CMTime(seconds: 8, preferredTimescale: 90_000)] {
            #expect(NativeAVPlayerHost.authoredForwardEndTime(
                2.0233333333333334..<2.0653333333333332, duration: duration) == expected)
        }
    }

    @Test func authoredTimesRoundToTheNearestDiscTickWithoutOverflow() {
        #expect(NativeAVPlayerHost.authoredTime(1.001) == CMTime(value: 90_090, timescale: 90_000))
        #expect(NativeAVPlayerHost.authoredTime(2.002) == CMTime(value: 180_180, timescale: 90_000))
        #expect(!NativeAVPlayerHost.authoredTime(.infinity).isValid)
        #expect(!NativeAVPlayerHost.authoredTime(.greatestFiniteMagnitude).isValid)
    }
}
