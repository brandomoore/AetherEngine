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

    @Test("Live video has mid-GOP headroom; audio-only HLS ingest keeps the tighter budget")
    func livePlaybackProfileBoundsAndInvariants() {
        let live = DemuxerOpenProfile.livePlayback
        let liveHLSAudio = DemuxerOpenProfile.liveHLSAudioIngest
        let playback = DemuxerOpenProfile.playback

        // Live video, including HLS, keeps enough ceiling for 10 s GOPs and 6 s late PMTs.
        #expect(live.probesize == 50 * 1024 * 1024)
        #expect(live.maxAnalyzeDuration == 15 * 1_000_000)
        #expect(live.fpsProbeSize == 6)
        #expect(live.allowsProbeDecoding == true)
        #expect(live.skipStreamInfo == false)

        #expect(liveHLSAudio.probesize == 8 * 1024 * 1024)
        #expect(liveHLSAudio.maxAnalyzeDuration == 5 * 1_000_000)
        #expect(liveHLSAudio.fpsProbeSize == 6)
        #expect(liveHLSAudio.allowsProbeDecoding == true)
        #expect(liveHLSAudio.skipStreamInfo == false)

        // maxAnalyzeDuration is in microseconds (AV_TIME_BASE = 1_000_000); releaseAfterNanoseconds is in ns.
        #expect(UInt64(live.maxAnalyzeDuration) * 1_000 > TransportStreamHeaderWait.releaseAfterNanoseconds)
        #expect(UInt64(liveHLSAudio.maxAnalyzeDuration) * 1_000 > TransportStreamHeaderWait.releaseAfterNanoseconds)

        // AVIO tuning stays identical to .playback on both live profiles.
        for candidate in [live, liveHLSAudio] {
            #expect(candidate.avioPrefetch == playback.avioPrefetch)
            #expect(candidate.avioChunkSize == playback.avioChunkSize)
            #expect(candidate.avioRequestTimeout == playback.avioRequestTimeout)
            #expect(candidate.avioMaxRetries == playback.avioMaxRetries)
        }
    }

    @Test("playbackOpenProfile selects .playback for VOD, .livePlayback for live, and .liveHLSAudioIngest for audio-only live HLS")
    @MainActor
    func playbackOpenProfileSelectsByLiveAndAudioOnly() throws {
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

        let hlsAudioProfile = AetherEngine.basePlaybackOpenProfile(isLive: true, isHLSAudioOnly: true)
        #expect(hlsAudioProfile.probesize == DemuxerOpenProfile.liveHLSAudioIngest.probesize)
        #expect(hlsAudioProfile.maxAnalyzeDuration == DemuxerOpenProfile.liveHLSAudioIngest.maxAnalyzeDuration)
        #expect(hlsAudioProfile.fpsProbeSize == 6)
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

    @Test("HLSVideoEngine keeps the smaller live HLS companion audio budget and honors overrides on both opens")
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
        #expect(liveSessionWithCompanion.companionOpenProfile.probesize == DemuxerOpenProfile.liveHLSAudioIngest.probesize)
        #expect(liveSessionWithCompanion.companionOpenProfile.maxAnalyzeDuration == DemuxerOpenProfile.liveHLSAudioIngest.maxAnalyzeDuration)
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

    @Test("Live HLS ingest resolves video parameters when the first keyframe is more than 5 s after joining")
    @MainActor
    func liveHLSProbeResolvesVideoAfterMidGOPJoin() async throws {
        let ts = try LongGOPTransportStreamFixture.data()
        let origin = try #require(RangeFilesOrigin())
        defer { origin.stop() }
        // PAT-aligned byte offsets near 2, 6, 10 and 14 s of the fixture. The first two
        // segments have no SPS/PPS or IDR, and the third carries the first IDR after the join.
        origin.serve("/seg0.ts", ts.subdata(in: 18_800..<55_084), contentType: "video/mp2t")
        origin.serve("/seg1.ts", ts.subdata(in: 55_084..<93_248), contentType: "video/mp2t")
        origin.serve("/seg2.ts", ts.subdata(in: 93_248..<129_344), contentType: "video/mp2t")
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:1
        #EXTINF:4.0,
        seg0.ts
        #EXTINF:4.0,
        seg1.ts
        #EXTINF:4.0,
        seg2.ts
        #EXT-X-ENDLIST

        """
        origin.serve("/live.m3u8", Data(playlist.utf8), contentType: "application/vnd.apple.mpegurl")
        let url = try #require(URL(string: "\(origin.baseURL)/live.m3u8"))
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions()
        options.isLive = true
        options.autoplay = false
        // This fixture is progressive. Avoid depending on native player startup; assert what the
        // engine's routing probe learned, before either playback path examines the stream.
        options.preferredDecodePath = .software
        let probe = try #require(try await engine.load(url: url, options: options))
        #expect(engine.customReader is HLSLiveIngestReader)
        #expect(probe.videoCodecName == "h264")
        #expect(probe.videoWidth == 32)
        #expect(probe.videoHeight == 32)
        #expect(engine.sourceVideoScan == .progressive)
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
