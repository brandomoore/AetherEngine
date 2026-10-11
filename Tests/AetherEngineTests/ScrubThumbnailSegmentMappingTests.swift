import Testing
import Foundation
@testable import AetherEngine

/// Audit SEG-2: scrub stills read init.mp4 plus a mapped segment file as one stream instead of
/// concatenating two heap copies. The reader must present exactly the bytes the concatenation did.
@Suite("Scrub thumbnail segment mapping")
struct ScrubThumbnailSegmentMappingTests {

    private func readAll(_ reader: DataIOReader, chunk: Int32) -> [UInt8] {
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: Int(chunk))
        while true {
            let n = buffer.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: chunk) }
            if n <= 0 { break }
            out += buffer[0..<Int(n)]
        }
        return out
    }

    @Test("a multi-part reader reads across the part boundary like one buffer")
    func readsAcrossParts() {
        let head = [UInt8](0..<7)
        let tail = [UInt8](100..<150)
        let reader = DataIOReader(parts: [Data(head), Data(), Data(tail)])
        #expect(reader.seek(offset: 0, whence: 65536) == 57)
        #expect(readAll(reader, chunk: 5) == head + tail)
    }

    @Test("seeks land on the right part, including SEEK_END and a slice with a nonzero start index")
    func seeksAcrossParts() {
        let backing = Data([UInt8](0..<20))
        let slice = backing[10..<20]   // startIndex 10
        let reader = DataIOReader(parts: [Data([0xAA, 0xBB]), slice])
        #expect(reader.seek(offset: 3, whence: SEEK_SET) == 3)
        #expect(readAll(reader, chunk: 4) == [UInt8](11..<20))
        #expect(reader.seek(offset: -11, whence: SEEK_END) == 1)
        #expect(readAll(reader, chunk: 64) == [0xBB] + [UInt8](10..<20))
    }

    @Test("the source maps the segment file and yields init followed by segment")
    func sourceMapsSegmentFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scrub-map-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let segURL = dir.appendingPathComponent("seg-3.m4s")
        let segBytes = (0..<4096).map { UInt8($0 & 0xFF) }
        try Data(segBytes).write(to: segURL)
        let initBytes: [UInt8] = [1, 2, 3, 4]

        let source = HLSVideoEngine.ScrubThumbnailSource(
            segmentIndex: 3, initData: Data(initBytes), segmentURL: segURL)
        let reader = try #require(source.makeReader())
        #expect(readAll(reader, chunk: 1000) == initBytes + segBytes)

        let missing = HLSVideoEngine.ScrubThumbnailSource(
            segmentIndex: 4, initData: Data(initBytes), segmentURL: dir.appendingPathComponent("gone.m4s"))
        #expect(missing.makeReader() == nil, "an evicted segment is a nil still, not a crash")
    }
}
