import AVFoundation
import Testing
@testable import AetherEngine

@MainActor
struct DisplayMatchingUpdateTests {
    private func readyEngine(options: LoadOptions = .init()) throws -> AetherEngine {
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(options)
        engine.publishRemoteHLSVideoDescription(.init(
            width: 1920, height: 1080, codecName: "h264",
            format: .init(pixelFormat: nil, bitDepth: 8, colorPrimaries: "bt709",
                          transfer: "bt709", matrix: "bt709", range: "tv", profile: nil)
        ))
        engine.sourceVideoFormat = .sdr
        engine.videoFormat = .sdr
        engine.sourceVideoFrameRate = 50
        engine.state = .playing
        engine.isSessionReady = true
        return engine
    }

    @Test("SDR toggles preserve the item, transport, clock and every unrelated option",
          arguments: [PlaybackState.playing, .paused])
    func preservesSession(state: PlaybackState) throws {
        var options = LoadOptions()
        options.autoplay = false
        options.isLive = true
        options.httpHeaders = ["User-Agent": "display-policy-test"]
        options.audioDelaySeconds = 0.25
        let engine = try readyEngine(options: options)
        defer { engine.stop() }
        let item = AVPlayerItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: item)
        engine.currentAVPlayer = player
        engine.state = state
        engine.clock.currentTime = 42
        engine.activeAudioTrackIndex = 2
        engine.activeSubtitleTrackIndex = 3
        let generation = engine.loadGeneration

        for enabled in [false, true, false, true] {
            #expect(engine.updateDisplayMatching(enabled: enabled) == .applied)
            var expected = options
            expected.displayCriteriaOwner = enabled ? .engine : .host
            expected.suppressDisplayCriteria = !enabled
            expected.matchContentEnabled = enabled
            #expect(engine.loadedOptions == expected)
            #expect(engine.currentAVPlayer === player)
            #expect(player.currentItem === item)
            #expect(engine.state == state)
            #expect(engine.clock.currentTime == 42)
            #expect(engine.activeAudioTrackIndex == 2)
            #expect(engine.activeSubtitleTrackIndex == 3)
            #expect(engine.loadGeneration == generation)
        }
    }

    @Test("forward-only SDR sources do not need to become seekable")
    func forwardOnlySource() throws {
        var options = LoadOptions()
        options.isLive = true
        let engine = try readyEngine(options: options)
        defer { engine.stop() }
        engine.isSourceSeekable = false
        let generation = engine.loadGeneration
        #expect(engine.updateDisplayMatching(enabled: false) == .applied)
        #expect(engine.updateDisplayMatching(enabled: true) == .applied)
        #expect(engine.isSourceSeekable == false)
        #expect(engine.loadGeneration == generation)
    }

    @Test("an SDR output badge never hides the source's HDR pipeline requirement",
          arguments: [VideoFormat.hdr10, .hdr10Plus, .hlg, .dolbyVision])
    func hdrSourceRequiresReload(format: VideoFormat) throws {
        let engine = try readyEngine()
        defer { engine.stop() }
        engine.sourceVideoFormat = format
        let options = engine.loadedOptions
        let generation = engine.loadGeneration
        #expect(engine.updateDisplayMatching(enabled: false) == .requiresReload)
        #expect(engine.loadedOptions == options)
        #expect(engine.loadGeneration == generation)
    }

    @Test("an HDR output pipeline is never corrected in place")
    func hdrOutputRequiresReload() throws {
        let engine = try readyEngine()
        defer { engine.stop() }
        engine.videoFormat = .hdr10
        let options = engine.loadedOptions
        #expect(engine.updateDisplayMatching(enabled: false) == .requiresReload)
        #expect(engine.loadedOptions == options)
    }

    @Test("transient and terminal states cannot install an SDR policy",
          arguments: [PlaybackState.idle, .loading, .seeking, .ended, .error("fixture")])
    func stateMustBeReady(state: PlaybackState) throws {
        let engine = try readyEngine()
        defer { engine.stop() }
        engine.state = state
        let options = engine.loadedOptions
        #expect(engine.updateDisplayMatching(enabled: false) == .notReady)
        #expect(engine.loadedOptions == options)
    }

    @Test("the reset-default SDR format is not proof of source readiness")
    func missingSourceFacts() throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        engine.state = .playing
        engine.isSessionReady = true
        let options = engine.loadedOptions
        #expect(engine.updateDisplayMatching(enabled: false) == .notReady)
        #expect(engine.loadedOptions == options)
    }

    @Test("AVKit and shared secondary ownership cannot be seized")
    func respectsOtherOwners() throws {
        var avKit = LoadOptions()
        avKit.displayCriteriaOwner = .avKit
        var legacyAVKit = LoadOptions()
        legacyAVKit.suppressDisplayCriteria = true
        var secondary = LoadOptions()
        secondary.sharedOutputRole = .secondary
        for options in [avKit, legacyAVKit, secondary] {
            let engine = try readyEngine(options: options)
            defer { engine.stop() }
            #expect(engine.updateDisplayMatching(enabled: true) == .requiresReload)
            #expect(engine.loadedOptions == options)
        }
    }

    @Test("a pending session cannot install the presentation policy")
    func pendingSession() throws {
        let engine = try readyEngine()
        defer { engine.stop() }
        engine.isSessionReady = false
        let options = engine.loadedOptions
        #expect(engine.updateDisplayMatching(enabled: false) == .notReady)
        #expect(engine.loadedOptions == options)
    }
}
