import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

@Suite("ASS cue duration")
struct SubtitleCueEndOffsetTests {
    @Test("Zero-duration ASS animation tail cannot become a five-second glyph")
    func zeroDurationASSTail() {
        let timeBase = 0.001
        #expect(SubtitleCueEndOffset.resolve(decodedMilliseconds: 90, packetDuration: 90,
                                             timeBaseSeconds: timeBase, isASS: true, fallback: 5) == 0.09)
        #expect(SubtitleCueEndOffset.resolve(decodedMilliseconds: 0, packetDuration: 0,
                                             timeBaseSeconds: timeBase, isASS: true, fallback: 5) == nil)
        #expect(SubtitleCueEndOffset.resolve(decodedMilliseconds: 0, packetDuration: nil,
                                             timeBaseSeconds: timeBase, isASS: true, fallback: 5) == nil)
    }

    @Test("Authored ASS durations and other subtitle fallbacks are retained")
    func validAndNonASSDurations() {
        #expect(SubtitleCueEndOffset.resolve(decodedMilliseconds: 40, packetDuration: nil,
                                             timeBaseSeconds: 0.001, isASS: true, fallback: 5) == 0.04)
        #expect(SubtitleCueEndOffset.resolve(decodedMilliseconds: 0, packetDuration: 250,
                                             timeBaseSeconds: 0.001, isASS: true, fallback: 5) == 0.25)
        #expect(SubtitleCueEndOffset.resolve(decodedMilliseconds: 0, packetDuration: 0,
                                             timeBaseSeconds: 0.001, isASS: false, fallback: 5) == 5)
    }

    @Test("Embedded ASS decoder does not publish an undated final fragment")
    func embeddedZeroDurationPacket() throws {
        let data = try #require(Data(base64Encoded: Issue587PreserveASSMarkupCodecGateTests.base64.joined()))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "matroska")
        defer { demuxer.close() }
        let streamIndex = Issue587PreserveASSMarkupCodecGateTests.assStreamIndex
        let stream = try #require(demuxer.stream(at: streamIndex))
        let decoder = try #require(EmbeddedSubtitleDecoder(stream: stream, sourceVideoWidth: 16,
                                                           sourceVideoHeight: 16, preserveASSMarkup: true))
        var sawASS = false
        while let packet = try demuxer.readPacket() {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&owned) }
            guard packet.pointee.stream_index == streamIndex else { continue }
            sawASS = true
            packet.pointee.duration = 0
            #expect(decoder.decode(packet: packet, streamTimeBase: stream.pointee.time_base) == nil)
            break
        }
        #expect(sawASS)
    }
}
