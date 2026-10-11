import Foundation
import Testing
@testable import AetherEngine

/// AE#619: the persistent reader's window used to drop its consumed head with
/// `window.subdata(in:)`, which copied everything still ahead of the cut, up to ~18 MB once per
/// 4 MB consumed. The window now holds the delivered chunks as they arrived. These cases pin that
/// it still behaves exactly like one contiguous buffer, byte for byte, under every operation the
/// reader performs.
@Suite("AE#619: the chunked read window")
struct Issue619ChunkedByteWindowTests {

    private func bytes(_ window: ChunkedByteWindow, from offset: Int = 0, count: Int? = nil) -> [UInt8] {
        let n = count ?? window.count - offset
        var out = [UInt8](repeating: 0, count: n)
        out.withUnsafeMutableBufferPointer { window.copyBytes(to: $0.baseAddress!, from: offset, count: n) }
        return out
    }

    private func chunk(_ start: Int, _ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: start &+ $0 &* 7) })
    }

    @Test("an empty window reads as empty")
    func emptyWindow() {
        var window = ChunkedByteWindow()
        #expect(window.isEmpty && window.count == 0)
        window.append(Data())
        #expect(window.isEmpty)
        #expect(window.prefix(16).isEmpty)
    }

    @Test("a read across chunk boundaries returns the bytes in order")
    func readAcrossChunks() {
        var window = ChunkedByteWindow()
        var reference = Data()
        for (i, size) in [3, 1, 4096, 17, 1].enumerated() {
            let c = chunk(i * 100, size)
            window.append(c)
            reference.append(c)
        }
        #expect(window.count == reference.count)
        #expect(bytes(window) == [UInt8](reference))
        #expect(bytes(window, from: 2, count: 3) == [UInt8](reference[2..<5]))
        #expect(window.prefix(6) == [UInt8](reference.prefix(6)))
    }

    @Test("dropping the head keeps the rest, including a partly consumed chunk")
    func dropHead() {
        var window = ChunkedByteWindow()
        var reference = Data()
        for i in 0..<8 {
            let c = chunk(i, 1000)
            window.append(c)
            reference.append(c)
        }
        for drop in [0, 1, 999, 1000, 2500] {
            window.dropFirst(drop)
            reference = reference.subdata(in: drop..<reference.count)
            #expect(bytes(window) == [UInt8](reference))
        }
        window.dropFirst(window.count)
        #expect(window.isEmpty)
        window.append(chunk(9, 5))
        #expect(bytes(window) == [UInt8](chunk(9, 5)))
    }

    @Test("truncating keeps exactly the leading bytes, inside a chunk and on its edge")
    func truncate() {
        for keep in [0, 1, 999, 1000, 1001, 2999, 3000] {
            var window = ChunkedByteWindow()
            var reference = Data()
            for i in 0..<3 {
                let c = chunk(i, 1000)
                window.append(c)
                reference.append(c)
            }
            window.dropFirst(0)
            window.truncate(to: keep)
            #expect(bytes(window) == [UInt8](reference.prefix(keep)))
            window.append(chunk(7, 10))
            #expect(bytes(window) == [UInt8](reference.prefix(keep) + chunk(7, 10)))
        }
    }

    @Test("a slice of a larger buffer is held by its own indices")
    func sliceChunk() {
        let backing = chunk(0, 64)
        var window = ChunkedByteWindow()
        window.append(backing[10..<20])
        window.append(backing[40..<44])
        #expect(bytes(window) == [UInt8](backing[10..<20] + backing[40..<44]))
    }

    /// The reader's own mix, many times over: append what arrives, read near the head, drop the
    /// consumed head, and now and then cut the tail for a reconnect. Checked against a contiguous
    /// `Data` doing the same thing the old way.
    @Test("a long random run matches a contiguous buffer")
    func randomRunMatchesReference() {
        var rng = SystemRandomNumberGenerator()
        var window = ChunkedByteWindow()
        var reference = Data()
        var serial = 0
        for _ in 0..<5_000 {
            switch Int.random(in: 0..<10, using: &rng) {
            case 0..<5:
                let c = chunk(serial, Int.random(in: 0..<3000, using: &rng))
                serial += 1
                window.append(c)
                reference.append(c)
            case 5..<8 where !reference.isEmpty:
                let offset = Int.random(in: 0..<reference.count, using: &rng)
                let n = Int.random(in: 0...(reference.count - offset), using: &rng)
                #expect(bytes(window, from: offset, count: n) == [UInt8](reference[offset..<offset + n]))
            case 8:
                let n = Int.random(in: 0...reference.count, using: &rng)
                window.dropFirst(n)
                reference = reference.subdata(in: n..<reference.count)
            default:
                let keep = Int.random(in: 0...reference.count, using: &rng)
                window.truncate(to: keep)
                reference = reference.prefix(keep)
            }
            #expect(window.count == reference.count)
        }
        #expect(bytes(window) == [UInt8](reference))
    }

    /// The point of the change, pinned without a clock: dropping the head of a long window must
    /// not touch the bytes still ahead of it. A chunk that is still referenced elsewhere keeps its
    /// storage identity through a drop, which a copy would not.
    @Test("dropping the head does not copy what remains")
    func dropDoesNotCopy() {
        var window = ChunkedByteWindow()
        for i in 0..<16 { window.append(Data(repeating: UInt8(i), count: 1 << 20)) }
        let before = window.chunkStorageAddresses()
        window.dropFirst(4 << 20)
        let after = window.chunkStorageAddresses()
        #expect(Array(before.suffix(12)) == after)
    }
}

/// The same window behind the real reader: bytes read forward and bytes read back inside the
/// lookback after several trims are the origin's bytes at those offsets, and the backward read is
/// served from the window rather than from a new request.
@Suite("AE#619: the reader's window over a live connection")
struct Issue619ReaderWindowTests {

    private func readExactly(_ reader: AVIOReader, _ count: Int, at offset: Int64) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        let ok = out.withUnsafeMutableBufferPointer { buffer -> Bool in
            while got < count {
                let n = reader.read(into: buffer.baseAddress! + got, size: Int32(min(64 * 1024, count - got)))
                if n <= 0 { return false }
                got += Int(n)
            }
            return true
        }
        return ok ? out : nil
    }

    private func expected(_ count: Int, at offset: Int64) -> [UInt8] {
        (0..<count).map { ThrottledOriginServer.patternByte(at: offset + Int64($0)) }
    }

    @Test("forward reads and a backward read inside the lookback return the origin's bytes")
    func backwardReadAfterTrimsHitsTheWindow() throws {
        let server = try #require(ThrottledOriginServer(totalSize: 256 * 1024 * 1024, throttleUs: 0,
                                                         patternedBody: true))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // 12 MB forward in 1 MB steps: past `winLookback + winTrimBatch` (6 MB), so the head has
        // been trimmed at least once by the time the backward read lands.
        var offset: Int64 = 0
        for _ in 0..<12 {
            let got = try #require(readExactly(reader, 1 << 20, at: offset))
            #expect(got == expected(1 << 20, at: offset), "forward read at \(offset)")
            offset += 1 << 20
        }

        let requestsBefore = server.requestedRanges.count
        let back = offset - 1_500_000
        #expect(reader.seek(offset: back, whence: SEEK_SET) == back)
        let got = try #require(readExactly(reader, 256 * 1024, at: back))
        #expect(got == expected(256 * 1024, at: back), "backward read at \(back)")
        #expect(!server.requestedRanges.dropFirst(requestsBefore).contains { $0.start == back },
                "a read inside the lookback went to the network: \(server.requestedRanges)")

        // And forward again past where the first pass stopped.
        let resume = back + 256 * 1024
        let tail = try #require(readExactly(reader, 4 << 20, at: resume))
        #expect(tail == expected(4 << 20, at: resume), "forward read after the backward one")
    }
}
