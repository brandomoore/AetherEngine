// Tests/AetherEngineTests/CompositorPreviewBuilderTests.swift
import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

@MainActor
@Suite("Compositor preview builder", .serialized)
struct CompositorPreviewBuilderTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("compositor-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A resident segment the way the session cuts one: a `dvh1` init with the Profile 5 record and
    /// a fragment that starts mid-title.
    private func residentSegment(in dir: URL) throws -> (initData: Data, segmentURL: URL, keyframe: Data) {
        let dem = Demuxer()
        defer { dem.close() }
        try dem.open(reader: DataIOReader(data: SupersededProbeGeometryTests.dolbyVisionProfile5OverHDR10()),
                     formatHint: "mp4")
        let index = dem.videoStreamIndex
        let stream = try #require(dem.stream(at: index))
        var keyframe: Data?
        for _ in 0..<64 {
            guard let pkt = try dem.readPacket() else { break }
            var owned: UnsafeMutablePointer<AVPacket>? = pkt
            defer { av_packet_free(&owned) }
            if pkt.pointee.stream_index == index, pkt.pointee.flags & AV_PKT_FLAG_KEY != 0, let bytes = pkt.pointee.data {
                keyframe = Data(bytes: bytes, count: Int(pkt.pointee.size)); break
            }
        }
        let payload = try #require(keyframe)
        let staging = dir.appendingPathComponent("segment-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let builder = IFrameFragmentBuilder(
            video: MP4SegmentMuxer.VideoConfig(codecpar: UnsafePointer(stream.pointee.codecpar),
                                               timeBase: stream.pointee.time_base, codecTagOverride: "dvh1"),
            stagingDir: staging)
        let out = try #require(builder.build(payload: payload, index: 3, startSeconds: 12.0, durationSeconds: 4.0))
        let url = dir.appendingPathComponent("seg3.m4s")
        try out.fragment.write(to: url)
        return (out.initSegment, url, payload)
    }

    @Test("the first keyframe of a resident segment becomes a standalone one-sample dvh1 file at zero")
    func standaloneOneKeyframeFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segment = try residentSegment(in: dir)
        let staging = dir.appendingPathComponent("preview-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let out = try #require(CompositorPreviewBuilder.build(
            initData: segment.initData, segmentURL: segment.segmentURL, durationSeconds: 4.0,
            codecTagOverride: "dvh1", colorOverride: nil, stagingDir: staging))
        #expect(IFrameTestBoxes.topLevelTypes(out.file).prefix(2) == ["ftyp", "moov"])
        let fragmentStart = try #require(Self.offsetOfFirstMoof(out.file))
        let fragment = out.file.subdata(in: fragmentStart..<out.file.count)
        #expect(IFrameTestBoxes.sampleCount(fragment: fragment) == 1)
        #expect(IFrameTestBoxes.baseDecodeTime(fragment: fragment) == 0)

        let dem = Demuxer()
        defer { dem.close() }
        try dem.open(reader: DataIOReader(data: out.file), formatHint: "mp4")
        let stream = try #require(dem.stream(at: dem.videoStreamIndex))
        let par = try #require(stream.pointee.codecpar)
        #expect(par.pointee.codec_tag == Self.fourCC("dvh1"))
        let record = try #require(av_packet_side_data_get(par.pointee.coded_side_data,
                                                           par.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF))
        let dovi = record.pointee.data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
        #expect(dovi.dv_profile == 5)
        let first = try #require(try dem.readPacket())
        var owned: UnsafeMutablePointer<AVPacket>? = first
        defer { av_packet_free(&owned) }
        #expect(first.pointee.flags & AV_PKT_FLAG_KEY != 0)
        #expect(Data(bytes: first.pointee.data, count: Int(first.pointee.size)) == segment.keyframe)
        #expect(try dem.readPacket() == nil)
    }

    @Test("a missing segment file builds nothing")
    func missingSegment() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segment = try residentSegment(in: dir)
        #expect(CompositorPreviewBuilder.build(
            initData: segment.initData, segmentURL: dir.appendingPathComponent("gone.m4s"), durationSeconds: 4,
            codecTagOverride: "dvh1", colorOverride: nil, stagingDir: dir) == nil)
    }

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func offsetOfFirstMoof(_ d: Data) -> Int? {
        var off = 0
        while off + 8 <= d.count {
            let size = Int(IFrameTestBoxes.u32(d, off))
            guard size >= 8 else { return nil }
            if String(bytes: d[(d.startIndex + off + 4)..<(d.startIndex + off + 8)], encoding: .isoLatin1) == "moof" { return off }
            off += size
        }
        return nil
    }
}
