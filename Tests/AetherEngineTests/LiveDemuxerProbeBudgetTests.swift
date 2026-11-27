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

    @Test("livePlayback and liveHLSIngest profiles preserve raw mid-GOP headroom while bounding HLS ingest")
    func livePlaybackProfileBoundsAndInvariants() {
        let live = DemuxerOpenProfile.livePlayback
        let liveHLS = DemuxerOpenProfile.liveHLSIngest
        let playback = DemuxerOpenProfile.playback

        // Raw mid-GOP live TS / custom readers keep enough ceiling for 10 s GOPs and 6 s late PMTs.
        #expect(live.probesize == 32 * 1024 * 1024)
        #expect(live.maxAnalyzeDuration == 15 * 1_000_000)
        #expect(live.fpsProbeSize == 6)
        #expect(live.allowsProbeDecoding == true)
        #expect(live.skipStreamInfo == false)

        // Keyframe-aligned HLS live ingest uses the tighter 8 MiB / 5 s ceiling while staying
        // strictly above the 2.5 s missing-PMT release window.
        #expect(liveHLS.probesize == 8 * 1024 * 1024)
        #expect(liveHLS.maxAnalyzeDuration == 5 * 1_000_000)
        #expect(liveHLS.fpsProbeSize == 6)
        #expect(liveHLS.allowsProbeDecoding == true)
        #expect(liveHLS.skipStreamInfo == false)

        // maxAnalyzeDuration is in microseconds (AV_TIME_BASE = 1_000_000); releaseAfterNanoseconds is in ns.
        #expect(UInt64(live.maxAnalyzeDuration) * 1_000 > TransportStreamHeaderWait.releaseAfterNanoseconds)
        #expect(UInt64(liveHLS.maxAnalyzeDuration) * 1_000 > TransportStreamHeaderWait.releaseAfterNanoseconds)

        // AVIO tuning stays identical to .playback on both live profiles.
        for candidate in [live, liveHLS] {
            #expect(candidate.avioPrefetch == playback.avioPrefetch)
            #expect(candidate.avioChunkSize == playback.avioChunkSize)
            #expect(candidate.avioRequestTimeout == playback.avioRequestTimeout)
            #expect(candidate.avioMaxRetries == playback.avioMaxRetries)
        }
    }

    @Test("playbackOpenProfile selects .playback for VOD, .livePlayback for raw live, and .liveHLSIngest for HLS ingest")
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

        let hlsIngestProfile = AetherEngine.basePlaybackOpenProfile(isLive: true, isHLSLiveIngest: true)
        #expect(hlsIngestProfile.probesize == DemuxerOpenProfile.liveHLSIngest.probesize)
        #expect(hlsIngestProfile.maxAnalyzeDuration == DemuxerOpenProfile.liveHLSIngest.maxAnalyzeDuration)
        #expect(hlsIngestProfile.fpsProbeSize == 6)
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
        #expect(liveSession.companionOpenProfile.probesize == DemuxerOpenProfile.livePlayback.probesize)

        let companion = HLSLiveIngestReader(playlistURL: URL(string: "http://127.0.0.1:9/audio.m3u8")!)
        defer { companion.close() }
        let liveSessionWithCompanion = HLSVideoEngine(
            url: url,
            isLiveSession: true,
            companionAudioReader: companion
        )
        #expect(liveSessionWithCompanion.openProfile.probesize == DemuxerOpenProfile.livePlayback.probesize)
        #expect(liveSessionWithCompanion.companionOpenProfile.probesize == DemuxerOpenProfile.liveHLSIngest.probesize)
        #expect(liveSessionWithCompanion.companionOpenProfile.maxAnalyzeDuration == DemuxerOpenProfile.liveHLSIngest.maxAnalyzeDuration)
        #expect(liveSessionWithCompanion.companionOpenProfile.fpsProbeSize == 6)

        let overriddenLiveSession = HLSVideoEngine(
            url: url,
            isLiveSession: true,
            companionAudioReader: companion,
            probesize: 3 * 1024 * 1024,
            maxAnalyzeDuration: 4 * 1_000_000
        )
        #expect(overriddenLiveSession.openProfile.probesize == 3 * 1024 * 1024)
        #expect(overriddenLiveSession.openProfile.maxAnalyzeDuration == 4 * 1_000_000)
        #expect(overriddenLiveSession.openProfile.fpsProbeSize == 6)
        #expect(overriddenLiveSession.companionOpenProfile.probesize == 3 * 1024 * 1024)
        #expect(overriddenLiveSession.companionOpenProfile.maxAnalyzeDuration == 4 * 1_000_000)
        #expect(overriddenLiveSession.companionOpenProfile.fpsProbeSize == 6)
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
