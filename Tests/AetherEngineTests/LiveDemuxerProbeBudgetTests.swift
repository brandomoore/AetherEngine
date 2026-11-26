import Foundation
import Testing
@testable import AetherEngine

@Suite("Live demuxer probe budget", .offCooperativePool, .timeLimit(.minutes(3)))
struct LiveDemuxerProbeBudgetTests {

    @Test("playback profile keeps 50 MiB / 60 s and leaves fpsProbeSize unset")
    func playbackProfileRemainsUnchanged() {
        let playback = DemuxerOpenProfile.playback
        #expect(playback.probesize == 50 * 1024 * 1024)
        #expect(playback.maxAnalyzeDuration == 60 * 1_000_000)
        #expect(playback.fpsProbeSize == nil)
        #expect(playback.allowsProbeDecoding == true)
        #expect(playback.skipStreamInfo == false)
    }

    @Test("livePlayback profile bounds probe budget while staying above the missing-PMT release window")
    func livePlaybackProfileBoundsAndInvariants() {
        let live = DemuxerOpenProfile.livePlayback
        let playback = DemuxerOpenProfile.playback

        #expect(live.probesize == 5 * 1024 * 1024)
        #expect(live.maxAnalyzeDuration == 5 * 1_000_000)
        #expect(live.fpsProbeSize == 6)
        #expect(live.allowsProbeDecoding == true)
        #expect(live.skipStreamInfo == false)

        // maxAnalyzeDuration is in microseconds (AV_TIME_BASE = 1_000_000); releaseAfterNanoseconds is in ns.
        let analyzeDurationNanoseconds = UInt64(live.maxAnalyzeDuration) * 1_000
        #expect(analyzeDurationNanoseconds > TransportStreamHeaderWait.releaseAfterNanoseconds)

        // AVIO tuning stays identical to .playback.
        #expect(live.avioPrefetch == playback.avioPrefetch)
        #expect(live.avioChunkSize == playback.avioChunkSize)
        #expect(live.avioRequestTimeout == playback.avioRequestTimeout)
        #expect(live.avioMaxRetries == playback.avioMaxRetries)
    }

    @Test("playbackOpenProfile selects .playback for VOD and .livePlayback for live")
    @MainActor
    func playbackOpenProfileSelectsByLiveFlag() throws {
        let engine = try AetherEngine()

        var vodOptions = LoadOptions()
        vodOptions.isLive = false
        let vodProfile = engine.playbackOpenProfile(options: vodOptions)
        #expect(vodProfile.probesize == DemuxerOpenProfile.playback.probesize)
        #expect(vodProfile.maxAnalyzeDuration == DemuxerOpenProfile.playback.maxAnalyzeDuration)
        #expect(vodProfile.fpsProbeSize == nil)

        var liveOptions = LoadOptions()
        liveOptions.isLive = true
        let liveProfile = engine.playbackOpenProfile(options: liveOptions)
        #expect(liveProfile.probesize == DemuxerOpenProfile.livePlayback.probesize)
        #expect(liveProfile.maxAnalyzeDuration == DemuxerOpenProfile.livePlayback.maxAnalyzeDuration)
        #expect(liveProfile.fpsProbeSize == 6)
    }

    @Test("playbackOpenProfile honors explicit probesize and maxAnalyzeDuration overrides on live and VOD")
    @MainActor
    func playbackOpenProfileHonorsExplicitOverrides() throws {
        let engine = try AetherEngine()

        var vodOptions = LoadOptions()
        vodOptions.isLive = false
        vodOptions.probesize = 8 * 1024 * 1024
        vodOptions.maxAnalyzeDuration = 12 * 1_000_000
        let vodProfile = engine.playbackOpenProfile(options: vodOptions)
        #expect(vodProfile.probesize == 8 * 1024 * 1024)
        #expect(vodProfile.maxAnalyzeDuration == 12 * 1_000_000)
        #expect(vodProfile.fpsProbeSize == nil)

        var liveOptions = LoadOptions()
        liveOptions.isLive = true
        liveOptions.probesize = 2 * 1024 * 1024
        liveOptions.maxAnalyzeDuration = 3 * 1_000_000
        let liveProfile = engine.playbackOpenProfile(options: liveOptions)
        #expect(liveProfile.probesize == 2 * 1024 * 1024)
        #expect(liveProfile.maxAnalyzeDuration == 3 * 1_000_000)
        #expect(liveProfile.fpsProbeSize == 6)
    }

    @Test("HLSVideoEngine threads livePlayback vs playback onto openProfile and honors overrides")
    func hlsVideoEngineSelectsOpenProfileByLiveSession() {
        let url = URL(string: "https://origin.example/live/stream.ts")!

        let vodSession = HLSVideoEngine(url: url, isLiveSession: false)
        #expect(vodSession.openProfile.probesize == DemuxerOpenProfile.playback.probesize)
        #expect(vodSession.openProfile.maxAnalyzeDuration == DemuxerOpenProfile.playback.maxAnalyzeDuration)
        #expect(vodSession.openProfile.fpsProbeSize == nil)

        let liveSession = HLSVideoEngine(url: url, isLiveSession: true)
        #expect(liveSession.openProfile.probesize == DemuxerOpenProfile.livePlayback.probesize)
        #expect(liveSession.openProfile.maxAnalyzeDuration == DemuxerOpenProfile.livePlayback.maxAnalyzeDuration)
        #expect(liveSession.openProfile.fpsProbeSize == 6)

        let overriddenLiveSession = HLSVideoEngine(
            url: url,
            isLiveSession: true,
            probesize: 3 * 1024 * 1024,
            maxAnalyzeDuration: 4 * 1_000_000
        )
        #expect(overriddenLiveSession.openProfile.probesize == 3 * 1024 * 1024)
        #expect(overriddenLiveSession.openProfile.maxAnalyzeDuration == 4 * 1_000_000)
        #expect(overriddenLiveSession.openProfile.fpsProbeSize == 6)
    }

    @Test("Demuxer.open with livePlayback opens TinyTransportStreamFixture cleanly as mpegts")
    func demuxerOpensTinyTransportStreamWithLivePlaybackProfile() throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(
            reader: TinyTransportStreamFixture.LiveReader(),
            formatHint: "mpegts",
            profile: .livePlayback,
            isLive: true
        )
        #expect(demuxer.containerFormatName == "mpegts")
        #expect(demuxer.videoStreamIndex >= 0)
    }
}
