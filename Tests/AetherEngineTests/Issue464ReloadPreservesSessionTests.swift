import Foundation
import Testing
@testable import AetherEngine

/// AE#464 round 2 (cmcpherson274, measured on tvOS 26.6): what a session-preserving reload has to
/// preserve. Both of these were reachable from every rebuild the engine makes on its own, not just
/// from an audio-delay nudge, and neither failed visibly: one settled the rebuilt host paused with
/// no error, the other rebuilt the session at its head.
@Suite("AE#464 round 2: a session-preserving rebuild preserves the transport")
struct Issue464RebuildTransportTests {

    @Test("a host that owns transport gets its session back playing, not frozen on the mount flag")
    func nativeIntentWins() {
        // The reported shape: LoadOptions.autoplay = false because the app drives transport itself.
        // Replaying that flag left the rebuilt host at timeControlStatus=paused for 40 s while the
        // producer parked on a consumer that would never ask for a segment, and the host reported
        // progress the whole time. What the rebuild has to come back in is the session's own intent.
        #expect(AetherEngine.rebuildResumesPlaying(state: .playing, nativeTransportIntent: true, underReconstruction: nil))
        #expect(!AetherEngine.rebuildResumesPlaying(state: .playing, nativeTransportIntent: false, underReconstruction: nil))
    }

    @Test("the durable intent outranks the momentary state, so a rebuild mid-seek is not a pause")
    func intentSurvivesAScrub() {
        // #122: `transportIntentIsPlaying` is the last engine-routed transport command and survives a
        // seek; `state` is `.seeking` for the whole landing. Reading the state there would turn every
        // correction raised during a scrub into a stop.
        #expect(AetherEngine.rebuildResumesPlaying(state: .seeking, nativeTransportIntent: true, underReconstruction: nil))
        // And the reverse: a paused scrub stays paused, which is the same thing #123's finalize wants.
        #expect(!AetherEngine.rebuildResumesPlaying(state: .seeking, nativeTransportIntent: false, underReconstruction: nil))
    }

    @Test("routes with no competing transport owner answer from state, as togglePlayPause does")
    func softwareAndAudioFallBackToState() {
        #expect(AetherEngine.rebuildResumesPlaying(state: .playing, nativeTransportIntent: nil, underReconstruction: nil))
        #expect(AetherEngine.rebuildResumesPlaying(state: .seeking, nativeTransportIntent: nil, underReconstruction: nil))
        #expect(!AetherEngine.rebuildResumesPlaying(state: .paused, nativeTransportIntent: nil, underReconstruction: nil))
    }

    @Test("a session that was not running does not come back running")
    func terminalStatesDoNotResume() {
        #expect(!AetherEngine.rebuildResumesPlaying(state: .idle, nativeTransportIntent: nil, underReconstruction: nil))
        #expect(!AetherEngine.rebuildResumesPlaying(state: .loading, nativeTransportIntent: nil, underReconstruction: nil))
        #expect(!AetherEngine.rebuildResumesPlaying(state: .ended, nativeTransportIntent: nil, underReconstruction: nil))
        #expect(!AetherEngine.rebuildResumesPlaying(state: .error("x"), nativeTransportIntent: nil, underReconstruction: nil))
    }
}

@Suite("AE#464 round 2: a rebuild stacked behind another one keeps the playhead")
struct Issue464RebuildPositionTests {

    @Test("with no load in flight the clock is the playhead, exactly as before")
    func steadyStateReadsTheClock() {
        #expect(AetherEngine.rebuildPosition(state: .playing, clock: 15.3, underReconstruction: nil) == 15.3)
        #expect(AetherEngine.rebuildPosition(state: .playing, clock: 15.3, underReconstruction: 0) == 15.3)
        #expect(AetherEngine.rebuildPosition(state: .paused, clock: 15.3, underReconstruction: 0) == 15.3)
    }

    @Test("a load in flight has zeroed the clock, so the parked position is the honest one")
    func stackedReloadKeepsThePosition() {
        // The measured leg: three stepper presses inside one runloop turn (10:32:42.804-.807) started
        // three reloads. Generations 2 and 3 were superseded, and the survivor snapshotted a clock
        // that generation 2's load had already reset, so it cut seg0+ on a title 15 s in.
        #expect(AetherEngine.rebuildPosition(state: .loading, clock: 0, underReconstruction: 15.3) == 15.3)
    }

    @Test("nothing parked means nothing invented; the clock still answers")
    func nothingParkedFallsThrough() {
        #expect(AetherEngine.rebuildPosition(state: .loading, clock: 0, underReconstruction: nil) == 0)
    }

    @Test("a cold load parks its own head, so a reload during startup does not resurrect a stale position")
    func coldLoadParksZero() {
        // `load` parks `startPosition ?? 0`. A fresh load at the head therefore parks 0, which is
        // what a reload stacked onto it must read: the previous session's playhead is gone.
        #expect(AetherEngine.rebuildPosition(state: .loading, clock: 0, underReconstruction: 0) == 0)
    }

    @Test("a load that has returned but not yet published a playhead still answers with its parked position")
    func returnedLoadBeforeFirstPublishKeepsThePosition() {
        // Round 5 (cmcpherson274, E8-F4): the autostart at the tail of `load()` writes `.playing`
        // before the new host has published a position, so a correction raised the moment a rebuild
        // returned read the zeroed clock and rebuilt at the head. Measured on the CLI with two
        // `setAudioDelay` presses 50-90 ms apart on `.loopback`: `#3 mount seek: item axis 0.00s`.
        #expect(AetherEngine.rebuildPosition(state: .playing, clock: 0, underReconstruction: 312.8) == 312.8)
        #expect(AetherEngine.rebuildPosition(state: .paused, clock: 0, underReconstruction: 312.8) == 312.8)
    }

    @Test("once the session has published a playhead, or has none, the clock answers again")
    func publishedOrTerminalReadsTheClock() {
        #expect(AetherEngine.rebuildPosition(state: .playing, clock: 312.9, underReconstruction: 312.8) == 312.9)
        #expect(AetherEngine.rebuildPosition(state: .seeking, clock: 0, underReconstruction: 312.8) == 0)
        #expect(AetherEngine.rebuildPosition(state: .idle, clock: 0, underReconstruction: 312.8) == 0)
        #expect(AetherEngine.rebuildPosition(state: .ended, clock: 0, underReconstruction: 312.8) == 0)
    }
}

/// AE#464 round 3 (measured on the CLI while building the in-flight latch): the window round 2
/// found for the POSITION hides the transport too, and hides it in the same way. A rebuild stacked
/// behind one still in flight reads `state == .loading` and finds the native host it would ask
/// being replaced, so both readings answer "paused" about a session that is playing.
@Suite("AE#464 round 3: a rebuild stacked behind another one keeps the transport")
struct Issue464StackedRebuildTransportTests {

    @Test("a load in flight owns the transport answer, exactly as it owns the position one")
    func stackedRebuildReadsTheParkedIntent() {
        // The measured leg: three stepper presses in one runloop turn raised three reloads. The
        // first read `.playing` and parked `autoplay = true`; the second and third read `.loading`
        // with no host to ask and wrote `autoplay = false`, so the surviving generation mounted
        // paused and stayed there for the rest of the run (cur=14.58 from t=15 to t=19) while the
        // harness whose job is to catch that ended `VERDICT: OK`.
        #expect(AetherEngine.rebuildResumesPlaying(
            state: .loading, nativeTransportIntent: nil, underReconstruction: true))
        // The host is gone either way in that window, but pin the precedence: what the load in
        // flight was handed outranks a stale intent as well as the absent one.
        #expect(AetherEngine.rebuildResumesPlaying(
            state: .loading, nativeTransportIntent: false, underReconstruction: true))
        #expect(!AetherEngine.rebuildResumesPlaying(
            state: .loading, nativeTransportIntent: true, underReconstruction: false))
    }

    @Test("a session paused when the first rebuild started comes back paused, not woken")
    func aPausedSessionStaysPaused() {
        // The park carries the honest answer in both directions. A host that paused, then corrected
        // an option, must not have its session started by the correction.
        #expect(!AetherEngine.rebuildResumesPlaying(
            state: .loading, nativeTransportIntent: nil, underReconstruction: false))
    }

    @Test("the park is read only inside the window it describes")
    func parkIsScopedToTheLoadingWindow() {
        // Same scoping rule as `rebuildPosition`: outside `.loading` the session can be asked
        // directly, and a stale park must not outrank it. A viewer who paused after the rebuild
        // finished is the case this protects.
        #expect(!AetherEngine.rebuildResumesPlaying(
            state: .paused, nativeTransportIntent: false, underReconstruction: true))
        #expect(AetherEngine.rebuildResumesPlaying(
            state: .playing, nativeTransportIntent: nil, underReconstruction: false))
    }
}

/// Audit LIF-102: `reloadWithAudioOverride` is the rebuild behind every audio-track pick, the custom
/// disc-title pick and `reloadAtCurrentPosition` on a custom source, and it ended in an unconditional
/// `play()`. The pure answer above was right and the call site ignored it: pause, pick another
/// language, and the film started behind the menu.
@Suite("Audit LIF-102: the audio-switch and custom-source rebuild comes back in the session's transport",
       .timeLimit(.minutes(2)))
@MainActor
struct Issue464RebuildCallSiteTransportTests {

    private static func customSource() throws -> MediaSource {
        .custom(DataIOReader(data: try ProbeTestFixtures.hdr10Plus()), formatHint: "mp4")
    }

    @Test("an audio-track rebuild of a paused session leaves it paused")
    func audioSwitchKeepsAPausedSessionPaused() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(source: Self.customSource())
        engine.pause()
        #expect(engine.state == .paused)
        let url = try #require(engine.loadedURL)

        let failure = await engine.reloadWithAudioOverride(
            url: url, audioStreamIndex: nil, expectedGeneration: engine.loadGeneration)

        #expect(failure == nil)
        #expect(engine.state != .playing)
        #expect(engine.nativeHost?.transportIntentIsPlaying == false)
        try await waitFor { engine.state == .paused }
    }

    @Test("a rebuild stacked behind that audio switch reads the paused transport, not the mount flag")
    func stackedRebuildReadsThePausedTransport() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(source: Self.customSource())
        engine.pause()
        let url = try #require(engine.loadedURL)

        let rebuild = Task { @MainActor in
            await engine.reloadWithAudioOverride(
                url: url, audioStreamIndex: nil, expectedGeneration: engine.loadGeneration)
        }
        try await waitFor { engine.state == .loading }
        #expect(!engine.sessionRebuildResumesPlaying)
        _ = await rebuild.value
    }

    @Test("a mount with autoplay off stays paused across a custom-source reload")
    func pausedMountStaysPausedAcrossACustomReload() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(source: Self.customSource(), options: LoadOptions(autoplay: false))
        try await waitFor { engine.state == .paused }

        try await engine.reloadAtCurrentPosition()

        #expect(engine.state != .playing)
        #expect(engine.nativeHost?.transportIntentIsPlaying == false)
        try await waitFor { engine.state == .paused }
    }

    @Test("a playing session still comes back playing")
    func playingSessionComesBackPlaying() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(source: Self.customSource())
        #expect(engine.state == .playing)

        try await engine.reloadAtCurrentPosition()

        #expect(engine.state == .playing)
        #expect(engine.nativeHost?.transportIntentIsPlaying == true)
    }
}
