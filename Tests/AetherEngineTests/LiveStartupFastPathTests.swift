import Foundation
import Testing
@testable import AetherEngine

@Suite("Live startup fast path")
struct LiveStartupFastPathTests {

    @Test("liveFilenameHint returns a sanitized extension-only hint for live MPEG-TS URLs")
    func liveFilenameHintMatchesOnlyLiveTransportStreams() throws {
        let tsURL = try #require(URL(string: "http://example.invalid/live/user/pass/12345.ts?token=secret"))
        let m2tsURL = try #require(URL(string: "http://example.invalid/channel/stream.M2TS"))
        let mtsURL = try #require(URL(string: "http://example.invalid/channel/stream.mts"))
        let m3u8URL = try #require(URL(string: "http://example.invalid/live/12345.m3u8"))
        let mp4URL = try #require(URL(string: "http://example.invalid/vod/movie.mp4"))
        let bareURL = try #require(URL(string: "http://example.invalid/live/12345"))

        #expect(Demuxer.liveFilenameHint(for: tsURL, isLive: true) == "stream.ts")
        #expect(Demuxer.liveFilenameHint(for: m2tsURL, isLive: true) == "stream.m2ts")
        #expect(Demuxer.liveFilenameHint(for: mtsURL, isLive: true) == "stream.mts")
        #expect(Demuxer.liveFilenameHint(for: tsURL, isLive: false) == nil)
        #expect(Demuxer.liveFilenameHint(for: m3u8URL, isLive: true) == nil)
        #expect(Demuxer.liveFilenameHint(for: mp4URL, isLive: true) == nil)
        #expect(Demuxer.liveFilenameHint(for: bareURL, isLive: true) == nil)
    }

    @Test("HLSLiveIngestReader pools an ephemeral stateless URLSession across tunes")
    func liveIngestReadersReuseSharedEphemeralSession() throws {
        let urlA = try #require(URL(string: "http://127.0.0.1:9/channelA.m3u8"))
        let urlB = try #require(URL(string: "http://127.0.0.1:9/channelB.m3u8"))
        let readerA = HLSLiveIngestReader(playlistURL: urlA)
        let readerB = HLSLiveIngestReader(playlistURL: urlB)

        #expect(readerA.session === readerB.session)
        #expect(readerA.session.configuration.urlCache == nil)
        #expect(readerA.session.configuration.httpCookieStorage == nil)
        #expect(readerA.session.configuration.httpShouldSetCookies == false)
        #expect(readerA.session.configuration.urlCredentialStorage == nil)

        // Closing one reader must not invalidate the pooled session used by subsequent tunes.
        readerA.close()
        let task = readerB.session.dataTask(with: urlB)
        task.cancel()
        readerB.close()
        #expect(task.state == .canceling || task.state == .completed)
    }
}
