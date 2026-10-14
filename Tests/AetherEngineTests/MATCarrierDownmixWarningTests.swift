import Testing
@testable import AetherEngine

/// PR #740 device round: the surround-downmix warning read the route's current channel count, which
/// after an APAC session is the 2-channel MAT carrier tvOS keeps, and told a viewer hearing intact
/// 5.1 that it was downmixed. The sink's advertised maximum is what decides.
@Suite("The surround-downmix warning reads the sink's advertised maximum")
struct MATCarrierDownmixWarningTests {

    @Test("5.1 into a sink stuck advertising stereo is a downmix")
    func stereoSinkWarns() {
        #expect(NativeAVPlayerHost.surroundDownmixSuspected(
            trackChannels: 6, routeChannels: 2, maximumRouteChannels: 2))
    }

    @Test("5.1 inside a MAT carrier on a 32-channel sink is not")
    func matCarrierStaysQuiet() {
        #expect(!NativeAVPlayerHost.surroundDownmixSuspected(
            trackChannels: 6, routeChannels: 2, maximumRouteChannels: 32))
    }

    @Test("a route that already carries the track, a stereo track or an unread route never warn")
    func nothingToWarnAbout() {
        #expect(!NativeAVPlayerHost.surroundDownmixSuspected(
            trackChannels: 6, routeChannels: 6, maximumRouteChannels: 6))
        #expect(!NativeAVPlayerHost.surroundDownmixSuspected(
            trackChannels: 2, routeChannels: 2, maximumRouteChannels: 2))
        #expect(!NativeAVPlayerHost.surroundDownmixSuspected(
            trackChannels: 6, routeChannels: 0, maximumRouteChannels: 0))
    }
}
