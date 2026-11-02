import AVFoundation
import Combine
import Testing
@testable import AetherEngine

@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct DisplayMatchingPlaybackTests {
    // Six seconds of synthetic black H.264 video, from Plozz's chapterless playback fixture.
    private static let sdrFixture = """
            AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAQnbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAoAAAA8AAAAQAAAQAA
            AAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAA
            A1J0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAA8AAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAA
            AAAAAAAAAAAAAABAAAAAAKAAAABaAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAPAAAAAAAAABAAAAAALKbWRpYQAAACBtZGhk
            AAAAAAAAAAAAAAAAAAAoAAAA8ABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAACdW1p
            bmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAjVzdGJsAAAAuXN0c2QA
            AAAAAAAAAQAAAKlhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAKAAWgBIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMiBsaWJ4
            MjY0AAAAAAAAAAAAAAAAGP//AAAAL2F2Y0MBQsAK/+EAGGdCwAraCjfkwEQAAAMABAAAAwBQPEiagAEABGjOD8gAAAAQcGFzcAAA
            AAEAAAABAAAAFGJ0cnQAAAAAAAAIGgAACBoAAAAYc3R0cwAAAAAAAAABAAAAPAAABAAAAAAoc3RzcwAAAAAAAAAGAAAAAQAAAAsA
            AAAVAAAAHwAAACkAAAAzAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAA8AAAAAQAAAQRzdHN6AAAAAAAAAAAAAAA8AAACmgAAAAoAAAAK
            AAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAEYAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAABGAAAA
            CgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAARgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAA
            AEYAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAABGAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoA
            AAAKAAAAFHN0Y28AAAAAAAAAAQAABFcAAABhdWR0YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAA
            AAAAACxpbHN0AAAAJKl0b28AAAAcZGF0YQAAAAEAAAAATGF2ZjYzLjEuMTAyAAAACGZyZWUAAAYcbWRhdAAAAlIGBf//TtxF6b3m
            2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgcjMyMjIgYjM1NjA1YSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVm
            dCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0wIHJlZj0xIGRl
            YmxvY2s9MDowOjAgYW5hbHlzZT0wOjAgbWU9ZGlhIHN1Ym1lPTAgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MCBt
            ZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTAgOHg4ZGN0PTAgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0x
            IGNocm9tYV9xcF9vZmZzZXQ9MCB0aHJlYWRzPTMgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVj
            aW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0wIHdlaWdodHA9
            MCBrZXlpbnQ9MTAga2V5aW50X21pbj0xIHNjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9MjMu
            MCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0wAIAAAABAZYiEOhGKAAI4scAA
            QaI4ABWTk5OTk5OTk5OuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuvAAAAAZBmiA+gewAAAAGQZpAPoHsAAAA
            BkGaYD6B7AAAAAZBmoAQoHsAAAAGQZqgEKB7AAAABkGawBCgewAAAAZBmuAQoHsAAAAGQZsAEKB7AAAABkGbIBCgewAAAEJliIIB
            GhGKAAM4scAASpo4AAgmycnJycnJycnJ111111111111111111111111111111111111111111111111114AAAAGQZogPoHsAAAA
            BkGaQD6B7AAAAAZBmmA+gewAAAAGQZqAEKB7AAAABkGaoBCgewAAAAZBmsAQoHsAAAAGQZrgEKB7AAAABkGbABCgewAAAAZBmyAQ
            oHsAAABCZYiEBKhGKAANb8cAAS9I4AAgsycnJycnJycnJ111111111111111111111111111111111111111111111111114AAAA
            BkGaID6B7AAAAAZBmkA+gewAAAAGQZpgPoHsAAAABkGagBCgewAAAAZBmqAQoHsAAAAGQZrAEKB7AAAABkGa4BCgewAAAAZBmwAQ
            oHsAAAAGQZsgEKB7AAAAQmWIggEqEYoAA1vxwABL0jgACCzJycnJycnJycnXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
            XXXXXXXXXgAAAAZBmiA+gewAAAAGQZpAPoHsAAAABkGaYD6B7AAAAAZBmoAQoHsAAAAGQZqgEKB7AAAABkGawBCgewAAAAZBmuAQ
            oHsAAAAGQZsAEKB7AAAABkGbIBCgewAAAEJliIQEqEYoAA1vxwABL0jgACCzJycnJycnJycnXXXXXXXXXXXXXXXXXXXXXXXXXXXX
            XXXXXXXXXXXXXXXXXXXXXXgAAAAGQZogPoHsAAAABkGaQD6B7AAAAAZBmmA+gewAAAAGQZqAEKB7AAAABkGaoBCgewAAAAZBmsAQ
            oHsAAAAGQZrgEKB7AAAABkGbABCgewAAAAZBmyAQoHsAAABCZYiCASoRigADW/HAAEvSOAAILMnJycnJycnJyddddddddddddddd
            dddddddddddddddddddddddddddddddddddeAAAABkGaID6B7AAAAAZBmkA+gewAAAAGQZpgPoHsAAAABkGagBCgewAAAAZBmqAQ
            oHsAAAAGQZrAEKB7AAAABkGa4BCgewAAAAZBmwAQoHsAAAAGQZsgEKB7
    """

    @Test("real SDR playback keeps advancing on the same player and source across presentation changes")
    func playbackContinuesWithoutReopening() async throws {
        let reader = ProbeRecordingReader(data: try ProbeTestFixtures.decode(Self.sdrFixture))
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions()
        options.displayCriteriaOwner = .host
        options.suppressDisplayCriteria = true
        options.matchContentEnabled = false
        _ = try await engine.load(source: .custom(reader, formatHint: "mp4"), options: options)
        try await waitFor { engine.isSessionReady && engine.state == .playing && engine.clock.currentTime > 0 }
        #expect(engine.sourceVideoFormat == .sdr)
        let player = try #require(engine.currentAVPlayer)
        let item = try #require(player.currentItem)
        let host = try #require(engine.nativeHost)
        let generation = engine.loadGeneration
        var reenteredLoading = false
        let observation = engine.$state.sink { state in
            MainActor.assumeIsolated {
                if state == .loading { reenteredLoading = true }
            }
        }
        defer { observation.cancel() }

        for enabled in [true, false, true, false] {
            let before = engine.clock.currentTime
            #expect(engine.updateDisplayMatching(enabled: enabled) == .applied)
            try await waitFor { engine.clock.currentTime > before + 0.1 }
            #expect(engine.currentAVPlayer === player)
            #expect(player.currentItem === item)
            #expect(engine.nativeHost === host)
            #expect(engine.customReader === reader)
            #expect(engine.loadGeneration == generation)
            #expect(reader.closeCount == 0)
            #expect(!reenteredLoading)
        }

        engine.pause()
        let pausedPosition = engine.clock.currentTime
        for enabled in [true, false] {
            #expect(engine.updateDisplayMatching(enabled: enabled) == .applied)
            #expect(engine.state == .paused)
            #expect(engine.clock.currentTime == pausedPosition)
            #expect(player.currentItem === item)
            #expect(engine.loadGeneration == generation)
        }
    }
}
