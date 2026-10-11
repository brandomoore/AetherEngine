// Tests/AetherEngineTests/IFrameFragmentBuilderTests.swift
import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
}
private func fixtureExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: fixtureURL(name).path)
}

/// Just enough ISO BMFF to read a track timescale, a fragment's base decode time and its sample count.
enum IFrameTestBoxes {
    static func u32(_ d: Data, _ off: Int) -> UInt32 {
        d.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: off, as: UInt32.self)) }
    }
    static func u64(_ d: Data, _ off: Int) -> UInt64 {
        d.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: off, as: UInt64.self)) }
    }
    /// Body range of the first box of `path` nested from the top of `range`.
    static func find(_ path: [String], in d: Data, range: Range<Int>? = nil) -> Range<Int>? {
        var range = range ?? 0..<d.count
        for name in path {
            var off = range.lowerBound
            var found: Range<Int>?
            while off + 8 <= range.upperBound {
                let size = Int(u32(d, off))
                guard size >= 8, off + size <= range.upperBound else { break }
                if String(bytes: d[(d.startIndex + off + 4)..<(d.startIndex + off + 8)], encoding: .isoLatin1) == name {
                    found = (off + 8)..<(off + size); break
                }
                off += size
            }
            guard let f = found else { return nil }
            range = f
        }
        return range
    }
    static func topLevelTypes(_ d: Data) -> [String] {
        var out: [String] = []; var off = 0
        while off + 8 <= d.count {
            let size = Int(u32(d, off)); guard size >= 8 else { break }
            out.append(String(bytes: d[(d.startIndex + off + 4)..<(d.startIndex + off + 8)], encoding: .isoLatin1) ?? "?")
            off += size
        }
        return out
    }
    static func timescale(initSegment d: Data) -> UInt32? {
        guard let mdhd = find(["moov", "trak", "mdia", "mdhd"], in: d) else { return nil }
        let version = d[d.startIndex + mdhd.lowerBound]
        return u32(d, mdhd.lowerBound + (version == 1 ? 20 : 12))
    }
    static func baseDecodeTime(fragment d: Data) -> UInt64? {
        guard let tfdt = find(["moof", "traf", "tfdt"], in: d) else { return nil }
        let version = d[d.startIndex + tfdt.lowerBound]
        return version == 1 ? u64(d, tfdt.lowerBound + 4) : UInt64(u32(d, tfdt.lowerBound + 4))
    }
    static func sampleCount(fragment d: Data) -> UInt32? {
        guard let trun = find(["moof", "traf", "trun"], in: d) else { return nil }
        return u32(d, trun.lowerBound + 4)
    }
}

/// Opens a fixture and hands back its video config plus the first keyframe's bytes.
struct IFrameFixture {
    let demuxer: Demuxer
    let config: MP4SegmentMuxer.VideoConfig
    let keyframe: Data

    init(_ name: String, codecTag: String) throws {
        let dem = Demuxer()
        try dem.open(url: fixtureURL(name))
        let index = dem.videoStreamIndex
        let stream = try #require(dem.stream(at: index))
        config = MP4SegmentMuxer.VideoConfig(
            codecpar: UnsafePointer(stream.pointee.codecpar),
            timeBase: stream.pointee.time_base,
            codecTagOverride: codecTag)
        var found: Data?
        for _ in 0..<200 {
            guard let pkt = try dem.readPacket() else { break }
            var owned: UnsafeMutablePointer<AVPacket>? = pkt
            defer { av_packet_free(&owned) }
            if pkt.pointee.stream_index == index, (pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0,
               let bytes = pkt.pointee.data {
                found = Data(bytes: bytes, count: Int(pkt.pointee.size)); break
            }
        }
        keyframe = try #require(found)
        demuxer = dem
    }
}

@Suite("I-frame fragment builder", .serialized)
struct IFrameFragmentBuilderTests {
    private func stagingDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iframe-builder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("one keyframe becomes one fragment with one sample at the requested time",
          .enabled(if: fixtureExists("sdr-h264.mp4")))
    func oneSampleAtRequestedTime() throws {
        let fx = try IFrameFixture("sdr-h264.mp4", codecTag: "avc1")
        defer { fx.demuxer.close() }
        let dir = try stagingDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let builder = IFrameFragmentBuilder(video: fx.config, stagingDir: dir)

        let out = try #require(builder.build(payload: fx.keyframe, index: 7,
                                             startSeconds: 28.0, durationSeconds: 4.0))
        #expect(IFrameTestBoxes.topLevelTypes(out.initSegment) == ["ftyp", "moov"])
        #expect(IFrameTestBoxes.topLevelTypes(out.fragment).contains("moof"))
        #expect(IFrameTestBoxes.topLevelTypes(out.fragment).contains("mdat"))
        #expect(IFrameTestBoxes.sampleCount(fragment: out.fragment) == 1)
        let timescale = Double(try #require(IFrameTestBoxes.timescale(initSegment: out.initSegment)))
        let tfdt = Double(try #require(IFrameTestBoxes.baseDecodeTime(fragment: out.fragment)))
        #expect(abs(tfdt / timescale - 28.0) < 0.002)
    }

    @Test("the init is byte-identical across fragments built out of order",
          .enabled(if: fixtureExists("sdr-h264.mp4")))
    func initIsStable() throws {
        let fx = try IFrameFixture("sdr-h264.mp4", codecTag: "avc1")
        defer { fx.demuxer.close() }
        let dir = try stagingDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let builder = IFrameFragmentBuilder(video: fx.config, stagingDir: dir)

        let late = try #require(builder.build(payload: fx.keyframe, index: 40,
                                              startSeconds: 160.0, durationSeconds: 4.0))
        let early = try #require(builder.build(payload: fx.keyframe, index: 2,
                                               startSeconds: 8.0, durationSeconds: 4.0))
        #expect(late.initSegment == early.initSegment)
        let timescale = Double(try #require(IFrameTestBoxes.timescale(initSegment: early.initSegment)))
        let tfdt = Double(try #require(IFrameTestBoxes.baseDecodeTime(fragment: early.fragment)))
        #expect(abs(tfdt / timescale - 8.0) < 0.002)
    }

    @Test("nothing is left behind in the staging directory",
          .enabled(if: fixtureExists("sdr-h264.mp4")))
    func stagingIsCleaned() throws {
        let fx = try IFrameFixture("sdr-h264.mp4", codecTag: "avc1")
        defer { fx.demuxer.close() }
        let dir = try stagingDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let builder = IFrameFragmentBuilder(video: fx.config, stagingDir: dir)
        _ = builder.build(payload: fx.keyframe, index: 0, startSeconds: 0, durationSeconds: 4.0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test("an empty payload builds nothing", .enabled(if: fixtureExists("sdr-h264.mp4")))
    func emptyPayload() throws {
        let fx = try IFrameFixture("sdr-h264.mp4", codecTag: "avc1")
        defer { fx.demuxer.close() }
        let dir = try stagingDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let builder = IFrameFragmentBuilder(video: fx.config, stagingDir: dir)
        #expect(builder.build(payload: Data(), index: 0, startSeconds: 0, durationSeconds: 4.0) == nil)
    }

    @Test("building a fragment is cheap enough to do per request",
          .enabled(if: fixtureExists("sdr-h264.mp4")))
    func buildCost() throws {
        let fx = try IFrameFixture("sdr-h264.mp4", codecTag: "avc1")
        defer { fx.demuxer.close() }
        let dir = try stagingDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let builder = IFrameFragmentBuilder(video: fx.config, stagingDir: dir)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<50 {
                _ = builder.build(payload: fx.keyframe, index: i,
                                  startSeconds: Double(i) * 4, durationSeconds: 4)
            }
        }
        let perFragmentMs = Double(elapsed.components.attoseconds) / 1e15 / 50
            + Double(elapsed.components.seconds) * 1000 / 50
        print("IFrameFragmentBuilder: \(String(format: "%.2f", perFragmentMs)) ms per fragment")
        #expect(perFragmentMs < 25)
    }
}
