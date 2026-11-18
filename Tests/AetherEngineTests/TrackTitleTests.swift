import XCTest
@testable import AetherEngine

final class TrackTitleTests: XCTestCase {
    func testAuthoredTitlesAndNamesPrecedeTheHandler() {
        // Public probe metadata uses name="Surround 6.1"/"SDH" with default MP4 handlers:
        // https://github.com/jellyfin/jellyfin/blob/07bcec2e1f4e835bc3a667c856dd444ec46b4611/tests/Jellyfin.MediaEncoding.Tests/Test%20Data/Probing/video_mp4_metadata.json
        XCTAssertEqual(
            Demuxer.resolvedTrackTitle(title: nil, name: "Surround 6.1", handlerName: "SoundHandler"),
            "Surround 6.1"
        )
        XCTAssertEqual(
            Demuxer.resolvedTrackTitle(title: nil, name: "SDH", handlerName: "SubtitleHandler"),
            "SDH"
        )
        XCTAssertEqual(
            Demuxer.resolvedTrackTitle(title: "Full subtitles", name: "Signs", handlerName: "SubtitleHandler"),
            "Full subtitles"
        )
        XCTAssertEqual(
            Demuxer.resolvedTrackTitle(title: " \n", name: " Signs & Songs ", handlerName: "Other"),
            "Signs & Songs"
        )
        XCTAssertEqual(
            Demuxer.resolvedTrackTitle(title: "SoundHandler", name: nil, handlerName: nil),
            "SoundHandler"
        )
    }

    func testCustomMP4HandlerNamesRemainVerbatim() {
        for title in ["Signs & Songs", "Audio Description", "Full [Translator edit]", "SDH-Colored"] {
            XCTAssertEqual(Demuxer.resolvedTrackTitle(title: nil, name: nil, handlerName: title), title)
        }
    }

    func testMissingAndMuxerDefaultHandlersKeepTheGeneratedFallback() {
        for handler in [nil, "", " \n", "SoundHandler", "SubtitleHandler", "VideoHandler",
                        "TextHandler", "Core Media Audio", "GPAC ISO Subtitle Handler"] {
            XCTAssertNil(Demuxer.resolvedTrackTitle(title: nil, name: nil, handlerName: handler))
        }
    }
}
