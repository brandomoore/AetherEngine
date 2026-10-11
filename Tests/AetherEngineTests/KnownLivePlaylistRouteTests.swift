import Testing
import Foundation
@testable import AetherEngine

/// AE#678: a live URL known to answer with a playlist skips the raw probe and its discarded request.
@Suite("Known live HLS playlist routing (AE#678)", .serialized)
struct KnownLivePlaylistRouteTests {

    @Test("an m3u8 or m3u path is known without having been seen")
    func extensionIsEnough() throws {
        RemoteHLSMediaSelection.forgetKnownLivePlaylistsForTesting()
        #expect(RemoteHLSMediaSelection.isKnownLivePlaylist(try #require(URL(string: "http://p.example/live/1/index.m3u8?token=a"))))
        #expect(RemoteHLSMediaSelection.isKnownLivePlaylist(try #require(URL(string: "http://p.example/list.M3U"))))
        #expect(!RemoteHLSMediaSelection.isKnownLivePlaylist(try #require(URL(string: "http://p.example/live/u/p/1.ts"))))
    }

    @Test("an extensionless channel URL is known once it has taken the AE#363 route")
    func rerouteIsRemembered() throws {
        RemoteHLSMediaSelection.forgetKnownLivePlaylistsForTesting()
        let channel = try #require(URL(string: "http://p.example/live/u/p/1234"))
        #expect(!RemoteHLSMediaSelection.isKnownLivePlaylist(channel))
        RemoteHLSMediaSelection.noteLivePlaylist(channel)
        #expect(RemoteHLSMediaSelection.isKnownLivePlaylist(channel))
        // The whole URL is the key: one Xtream path serves TS or HLS depending on its query.
        let tsVariant = try #require(URL(string: "http://p.example/live/u/p/1234?output=ts"))
        #expect(!RemoteHLSMediaSelection.isKnownLivePlaylist(tsVariant))
        RemoteHLSMediaSelection.forgetKnownLivePlaylistsForTesting()
    }
}
