// #693: a transient refusal at byte 0. KIPTV's Xtream origin answered the ranged open of a series
// episode with a 403, and the unranged GET the reader sent right after it, to the same resource, was
// answered 200. #378 had read every 401/403/404/410 at byte 0 as "the origin's answer to the
// RESOURCE", so that one 403 decided the whole session: the reader streamed forward-only, the load
// promoted the source to a sequential origin, the saved position was dropped and every seek past
// the downloaded window snapped back. Ten hours later the same origin answered every ranged request
// with a 206.
//
// A refusal that the next request does not repeat says nothing about the resource. The open now asks
// the same range once more before it settles, and only a second refusal sends it down the #378 path.
import Foundation
import Testing
@testable import AetherEngine

@Suite("#693 a refusal at byte 0 that is not repeated keeps the source seekable", .serialized)
struct Issue693TransientRefusalTests {

    private static let fileSize = 8 * 1024 * 1024

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }

    /// A range-capable origin. `refuseByteZero` decides, per ranged request at byte 0 (1-based), whether
    /// that one is answered 403.
    private static func origin(refuseByteZero: @escaping @Sendable (Int) -> Bool) throws -> ScriptedOriginServer {
        let byteZero = Counter()
        return try #require(ScriptedOriginServer { request in
            let total = Int64(fileSize)
            guard let range = request.range else {
                return .init(status: 200, declaredLength: total, bodyBytes: fileSize)
            }
            if range.hasPrefix("bytes=-") {
                return .init(status: 206, declaredLength: 65_536,
                             contentRange: "bytes \(total - 65_536)-\(total - 1)/\(total)", bodyBytes: 65_536)
            }
            let bounds = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            let start = Int64(bounds.first ?? "") ?? 0
            let end = min(Int64(bounds.count > 1 ? bounds[1] : "") ?? (total - 1), total - 1)
            if start == 0, refuseByteZero(byteZero.next()) {
                return .init(status: 403, declaredLength: 0)
            }
            let length = Int(end - start + 1)
            return .init(status: 206, declaredLength: Int64(length),
                         contentRange: "bytes \(start)-\(end)/\(total)", bodyBytes: length)
        })
    }

    @Test("a 403 that the second ranged open does not repeat leaves the source seekable, without an unranged GET")
    func transientRefusalKeepsSeekability() throws {
        let server = try Self.origin { $0 == 1 }
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/series/episode.mp4")!

        let reader = AVIOReader(url: url)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        #expect(reader.isSeekable, "one 403 at byte 0 turned a range-capable origin forward-only")

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let read = buffer.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, size: Int32($0.count)) }
        #expect(read > 0, "the second ranged open delivered nothing: \(read)")

        let requests = server.requests
        #expect(!requests.contains { $0.method == "GET" && $0.range == nil },
                "settled on the unranged GET although the range form was served: \(requests)")
        #expect(!requests.contains { $0.method == "HEAD" })
        #expect(requests.filter { $0.range?.hasPrefix("bytes=0-") == true }.count == 2,
                "expected the refused ranged open and exactly one more: \(requests)")
    }

    @Test("a 403 that the second ranged open repeats settles forward-only on one unranged GET, as #378 does")
    func repeatedRefusalSettlesForwardOnly() throws {
        let server = try Self.origin { _ in true }
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/series/episode.mp4")!

        let reader = AVIOReader(url: url)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        #expect(!reader.isSeekable)

        let requests = server.requests
        #expect(requests.filter { $0.range?.hasPrefix("bytes=0-") == true }.count == 2,
                "the range form was not asked a second time, or more than that: \(requests)")
        #expect(requests.filter { $0.method == "GET" && $0.range == nil }.count == 1, "\(requests)")
        #expect(!requests.contains { $0.method == "HEAD" })
        #expect(!requests.contains { $0.range == "bytes=0-1" })
    }

    // MARK: - What the host sees when the session does settle

    @MainActor
    @Test("isSequentialOrigin does not outlive the session it described")
    func sequentialFlagClearsOnStop() throws {
        let engine = try AetherEngine()
        #expect(!engine.isSequentialOrigin)
        engine.isSequentialOrigin = true
        engine.stop()
        #expect(!engine.isSequentialOrigin, "the next load would start out reporting a sequential origin")
    }
}
