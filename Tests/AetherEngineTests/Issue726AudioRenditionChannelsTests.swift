import Testing
import Foundation
@testable import AetherEngine

/// AE#726: CHANNELS on the master's EXT-X-MEDIA:TYPE=AUDIO tag. `CODECS` is `ec-3` for JOC and non-JOC
/// alike (#34), so `"16/JOC"` is the only playlist-level statement that a rendition carries objects;
/// without it a stream-copied Atmos bitstream reached the receiver as the 5.1 bed (device A/B in PR #727).
struct Issue726AudioRenditionChannelsTests {

    private func provider(
        language: String?, channels: Int?, atmosStreamCopy: Bool
    ) -> VideoSegmentProvider {
        VideoSegmentProvider(
            cache: SegmentCache(forwardWindow: 4, backwardWindow: 4),
            segments: [HLSVideoEngine.Segment(startPts: 0, endPts: 4000, startSeconds: 0, durationSeconds: 4)],
            codecsString: "hvc1.2.4.L150.b0,ec-3", supplementalCodecs: nil,
            resolution: (3840, 2160), videoRange: .sdr, frameRate: 24.0, hdcpLevel: nil,
            sourceBitrate: 10_000_000,
            audioLanguage: language,
            audioChannelCount: channels,
            audioIsAtmosStreamCopy: atmosStreamCopy
        )
    }

    private func audioTag(_ master: String) -> String? {
        master.split(separator: "\n").first { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") }.map(String.init)
    }

    @Test("a tagged JOC stream copy is declared 16/JOC after the existing attributes")
    func taggedJOC() {
        let master = HLSLocalServer.buildMasterPlaylistText(
            provider: provider(language: "eng", channels: 6, atmosStreamCopy: true))
        #expect(audioTag(master)?.hasSuffix(
            "LANGUAGE=\"eng\",DEFAULT=YES,AUTOSELECT=YES,CHANNELS=\"16/JOC\"") == true)
    }

    @Test("an untagged JOC stream copy still gets a rendition, without LANGUAGE")
    func untaggedJOC() {
        let p = provider(language: nil, channels: 6, atmosStreamCopy: true)
        #expect(p.masterAudioRendition?.language == nil)
        #expect(p.masterAudioRendition?.name == VideoSegmentProvider.untaggedAtmosRenditionName)
        let master = HLSLocalServer.buildMasterPlaylistText(provider: p)
        #expect(audioTag(master) == "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Dolby Atmos\","
            + "DEFAULT=YES,AUTOSELECT=YES,CHANNELS=\"16/JOC\"")
        #expect(master.contains("AUDIO=\"aud\""))
    }

    /// The rendition is what forces a master on an SDR source (AE#458), so widening it to every untagged
    /// track would reroute every untagged source for an attribute nothing has been measured to need.
    @Test("an untagged non-JOC track keeps the master without an audio group")
    func untaggedBedHasNoRendition() {
        let p = provider(language: nil, channels: 6, atmosStreamCopy: false)
        #expect(p.masterAudioRendition == nil)
        #expect(p.masterAudioChannels == nil)
        let master = HLSLocalServer.buildMasterPlaylistText(provider: p)
        #expect(!master.contains("TYPE=AUDIO"))
        #expect(!master.contains("AUDIO=\"aud\""))
    }

    @Test("a tagged track that is not object audio is declared with its served channel count")
    func taggedBed() {
        let master = HLSLocalServer.buildMasterPlaylistText(
            provider: provider(language: "deu", channels: 8, atmosStreamCopy: false))
        #expect(audioTag(master)?.hasSuffix("AUTOSELECT=YES,CHANNELS=\"8\"") == true)
    }

    @Test("an unknown channel count omits CHANNELS rather than guessing")
    func unknownCount() {
        let master = HLSLocalServer.buildMasterPlaylistText(
            provider: provider(language: "deu", channels: nil, atmosStreamCopy: false))
        #expect(audioTag(master)?.contains("CHANNELS=") == false)
    }

    @Test("the audible readback names a rendition without LANGUAGE as untagged, not as nothing declared")
    func readbackUntagged() {
        let missing = AudibleSelectionReadback.line(
            served: nil, declaredUntagged: true, servingMaster: true,
            groupPresent: false, options: [], selected: nil)
        #expect(missing.contains("served=untagged"))
        #expect(missing.contains("AVKit labels the track Not Specified"))
        let unknown = AudibleSelectionReadback.Option(displayName: "Unknown", languageTag: nil)
        let found = AudibleSelectionReadback.line(
            served: nil, declaredUntagged: true, servingMaster: true,
            groupPresent: true, options: [unknown], selected: unknown)
        #expect(found.contains("served=untagged"))
        #expect(!found.contains("MISMATCH"))
    }
}
