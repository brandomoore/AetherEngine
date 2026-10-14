import Foundation
import Testing
@testable import AetherEngine

/// A DVD-Video image with no ISO9660 bridge volume, only UDF: recognized through UDF instead of falling
/// through to a raw open of the whole image.
@Suite("UDF-only DVD-Video images")
struct UDFOnlyDVDImageTests {

    static func bytes(_ seed: UInt8, _ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: Int(seed) &* 37 &+ $0) }
    }

    /// Two title sets; the first one's content is two VOBs. The IFOs are unreadable on purpose: the
    /// title sets then come from the VOB names alone, as on any disc whose VMGI does not parse.
    static func files(contentA: Int = 5000, contentB: Int = 4100) -> [(name: String, bytes: [UInt8])] {
        [("VIDEO_TS.IFO", bytes(1, 2048)),
         ("VIDEO_TS.VOB", bytes(2, 2048)),
         ("VTS_01_0.IFO", bytes(3, 2048)),
         ("VTS_01_0.VOB", bytes(4, 2048)),
         ("VTS_01_1.VOB", bytes(5, contentA)),
         ("VTS_01_2.VOB", bytes(6, contentB)),
         ("VTS_02_1.VOB", bytes(7, 3000))]
    }

    static func readToEnd(_ reader: IOReader) -> [UInt8] {
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1000)
        while true {
            let n = buffer.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 1000) }
            if n <= 0 { break }
            out += buffer[0..<Int(n)]
        }
        return out
    }

    @Test("the main title set's VOBs play back to back, not the image from its first byte")
    func recognizesTheTitleSets() throws {
        let image = UDFFixture.makeDVD(files: Self.files())
        let reader = DataIOReader(data: image)
        #expect(!DiscReader.looksLikeISO9660(reader))
        let info = try #require(try DiscReader.wrap(reader))
        #expect(info.formatHint == "mpeg")
        #expect(info.titles.count == 2)
        #expect(info.titles.map(\.dvdVTSN) == [1, 2])
        #expect(Self.readToEnd(info.reader) == Self.bytes(5, 5000) + Self.bytes(6, 4100))

        let second = try #require(try DiscReader.wrap(DataIOReader(data: image), selectTitleID: 1))
        #expect(Self.readToEnd(second.reader) == Self.bytes(7, 3000))
    }

    @Test("a file recorded as runs that do not continue each other is left out of the title")
    func fragmentedFileIsLeftOut() throws {
        let image = UDFFixture.makeDVD(files: Self.files(), fragmented: ["VTS_01_2.VOB"])
        let info = try #require(try DiscReader.wrap(DataIOReader(data: image)))
        #expect(Self.readToEnd(info.reader) == Self.bytes(5, 5000))
    }

    @Test("a UDF-only VIDEO_TS with no title VOBs is not a disc")
    func noTitleVOBs() throws {
        let image = UDFFixture.makeDVD(files: [("VIDEO_TS.IFO", Self.bytes(1, 2048)), ("VIDEO_TS.VOB", Self.bytes(2, 2048))])
        #expect(try DiscReader.wrap(DataIOReader(data: image)) == nil)
    }

    @Test("disc-inspect calls it DVD-Video, as playback does")
    func inspectorAgrees() {
        let inspection = DiscInspector.inspect(DataIOReader(data: UDFFixture.makeDVD(files: Self.files())))
        #expect(inspection.kind == .dvdVideo)
        #expect(!inspection.iso9660Signature)
        #expect(inspection.udfAnchor)
        #expect(inspection.dvdVOBFiles.contains("VTS_01_1.VOB"))
        #expect(inspection.wrapRecognized)
        #expect(inspection.wrapFormatHint == "mpeg")
    }

    /// Records where a reader was asked to seek.
    final class SeekLog: IOReader, @unchecked Sendable {
        private let base: DataIOReader
        private let lock = NSLock()
        private var offsets: [Int64] = []
        init(_ data: Data) { base = DataIOReader(data: data) }
        var seeks: [Int64] { lock.withLock { offsets } }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { base.read(buffer, size: size) }
        func seek(offset: Int64, whence: Int32) -> Int64 {
            if whence == SEEK_SET { lock.withLock { offsets.append(offset) } }
            return base.seek(offset: offset, whence: whence)
        }
        func close() {}
    }

    @Test("a source that is no disc is still sniffed for the UDF anchor once")
    func nonDiscReadsTheAnchorOnce() throws {
        let reader = SeekLog(Data(repeating: 0, count: 600 * 1024))
        #expect(try DiscReader.wrap(reader) == nil)
        #expect(reader.seeks.filter { $0 == 256 * 2048 }.count == 1)
    }
}
