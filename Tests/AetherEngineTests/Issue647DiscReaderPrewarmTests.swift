import Testing
import Foundation
@testable import AetherEngine

/// #647: a remote disc image the host warmed is read out of the warm, the way any other source is.
///
/// Before this the disc reader never looked at the store: it probed the size with `bytes=0-0`,
/// refetched the head, and left the warm in the store for the streaming reader that never came.
///
/// `.serialized`: the Demuxer case goes through the process-wide store. The reader cases use a
/// private store so nothing here depends on another suite leaving `.shared` alone.
@Suite("Disc reader adopts a prewarmed source (#647)", .serialized)
struct Issue647DiscReaderPrewarmTests {

    private let fileSize: Int64 = 64 * 1024 * 1024
    private let warmBytes = 1024 * 1024

    private func url(_ server: ThrottledOriginServer, _ name: String = "disc.iso") -> URL {
        URL(string: "http://127.0.0.1:\(server.port)/\(name)")!
    }

    private func read(_ reader: IOReader, at offset: Int64, _ size: Int) -> [UInt8] {
        _ = reader.seek(offset: offset, whence: SEEK_SET)
        var out: [UInt8] = []
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buf.deallocate() }
        while out.count < size {
            let n = reader.read(buf, size: Int32(size - out.count))
            guard n > 0 else { break }
            out.append(contentsOf: UnsafeBufferPointer(start: buf, count: Int(n)))
        }
        return out
    }

    private func expected(at offset: Int64, _ size: Int) -> [UInt8] {
        (0..<Int64(size)).map { ThrottledOriginServer.patternByte(at: offset + $0) }
    }

    private func warmedReader(_ server: ThrottledOriginServer,
                              store: SourcePrewarmStore) async throws -> HTTPDiscIOReader {
        let report = await SourcePrewarmFetcher.warm(url: url(server), extraHeaders: [:],
                                                     byteBudget: warmBytes, into: store)
        #expect(report.retainedBytes == warmBytes)
        let warm = try #require(HTTPDiscIOReader.takePrewarm(for: url(server), extraHeaders: [:],
                                                             store: store))
        #expect(!store.isWarm(for: url(server)), "adoption takes the entry")
        return try #require(HTTPDiscIOReader(url: url(server), prewarmed: warm))
    }

    @Test("reads inside the warm cost no request, and the size is not probed")
    func warmServesTheHead() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: fileSize, patternedBody: true))
        defer { server.stop() }
        let reader = try await warmedReader(server, store: SourcePrewarmStore(totalByteCap: 8 << 20))
        defer { reader.close() }
        let afterWarm = server.requestedRanges.count

        #expect(reader.seek(offset: 0, whence: 65536) == fileSize)
        // The disc layer's opening shape: the ISO 9660 sniff at 0x8001, the UDF anchor at sector
        // 256, a directory read back near the start.
        #expect(read(reader, at: 0x8001, 5) == expected(at: 0x8001, 5))
        #expect(read(reader, at: 256 * 2048, 2048) == expected(at: 256 * 2048, 2048))
        #expect(read(reader, at: 40_960, 64 * 1024) == expected(at: 40_960, 64 * 1024))
        #expect(server.requestedRanges.count == afterWarm,
                "a read inside the warm went to the network: \(server.requestedRanges.dropFirst(afterWarm))")
    }

    @Test("a read across the warm frontier is exact and fetches from the frontier on")
    func frontierContinues() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: fileSize, patternedBody: true))
        defer { server.stop() }
        let reader = try await warmedReader(server, store: SourcePrewarmStore(totalByteCap: 8 << 20))
        defer { reader.close() }
        let afterWarm = server.requestedRanges.count

        let start = Int64(warmBytes) - 1000
        #expect(read(reader, at: start, 300_000) == expected(at: start, 300_000))
        let opened = Array(server.requestedRanges.dropFirst(afterWarm))
        #expect(opened.first?.start == Int64(warmBytes), "requests: \(opened)")
        #expect(!opened.contains(where: { $0.start < Int64(warmBytes) }), "requests: \(opened)")
    }

    @Test("a fork shares the warm and the size, so it neither probes nor refetches the head")
    func forkSharesTheWarm() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: fileSize, patternedBody: true))
        defer { server.stop() }
        let reader = try await warmedReader(server, store: SourcePrewarmStore(totalByteCap: 8 << 20))
        defer { reader.close() }
        let afterWarm = server.requestedRanges.count

        let fork = try #require(reader.makeIndependentReader())
        defer { fork.close() }
        #expect(fork.seek(offset: 0, whence: 65536) == fileSize)
        #expect(read(fork, at: 0, 128 * 1024) == expected(at: 0, 128 * 1024))
        #expect(server.requestedRanges.count == afterWarm,
                "the fork went to the network: \(server.requestedRanges.dropFirst(afterWarm))")
    }

    @Test("a warm fetched with other headers is not adopted")
    func headersMustMatch() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: fileSize))
        defer { server.stop() }
        let store = SourcePrewarmStore(totalByteCap: 8 << 20)
        _ = await SourcePrewarmFetcher.warm(url: url(server), extraHeaders: ["Referer": "a"],
                                            byteBudget: warmBytes, into: store)
        #expect(HTTPDiscIOReader.takePrewarm(for: url(server), extraHeaders: ["Referer": "b"],
                                             store: store) == nil)
    }

    @Test("a disc-image URL that is no disc hands the warm to the streaming reader")
    func notADiscKeepsTheWarm() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: fileSize, patternedBody: true))
        defer { server.stop() }
        let source = url(server, "not-a-disc.iso")
        _ = await SourcePrewarmFetcher.warm(url: source, extraHeaders: [:],
                                            byteBudget: warmBytes, into: .shared)
        let afterWarm = server.requestedRanges.count

        let demuxer = Demuxer()
        defer { demuxer.close() }
        // Patterned bytes are no container, so the open fails; what it asked the origin is the point.
        try? demuxer.open(url: source)

        let opened = Array(server.requestedRanges.dropFirst(afterWarm))
        #expect(!opened.contains(where: { $0.start == 0 }),
                "the open re-fetched bytes it already had: \(opened)")
        #expect(!SourcePrewarmStore.shared.isWarm(for: source))
    }
}
