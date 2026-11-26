import CommonCrypto
import Foundation
import Testing
@testable import AetherEngine

/// Regression coverage for live HLS ingest startup optimizations:
/// - Eagerly starting the demuxed companion audio reader at master resolution (skipped on
///   single-request origins so video keeps the sole slot).
/// - Overlapping AES-128 key fetch with segment download, deduplicating concurrent misses for the
///   same key URI, keeping failed key fetches uncached, and preserving 404 segment skip semantics.
@Suite("Live HLS ingest startup optimizations", .offCooperativePool, .timeLimit(.minutes(3)))
struct HLSLiveIngestStartupOptimizationTests {

    // MARK: - Loopback origin

    /// HTTP/1.1 loopback origin with mutable routes, request counters, and per-path response gates.
    /// Hits are recorded before parking on a held path so tests can observe in-flight overlap
    /// deterministically with `waitFor`.
    private final class GatedHLSOrigin: @unchecked Sendable {
        struct Route {
            var status: Int
            var body: Data
        }

        let port: UInt16
        private let listener: LoopbackListener
        private let condition = NSCondition()
        private var routes: [String: Route]
        private var held: Set<String>
        private var hits: [String: Int] = [:]
        private var stopped = false

        init?(routes: [String: Route], hold: Set<String> = []) {
            self.routes = routes
            self.held = hold
            guard let listener = LoopbackListener(backlog: 32) else { return nil }
            self.listener = listener
            port = listener.port
            listener.start { [weak self] conn in
                guard let self else { close(conn); return false }
                Thread.detachNewThread { [weak self] in
                    self?.serve(conn)
                }
                return true
            }
        }

        func url(_ path: String) -> URL {
            URL(string: "http://127.0.0.1:\(port)\(path)")!
        }

        func hitCount(for path: String) -> Int {
            condition.lock()
            defer { condition.unlock() }
            return hits[path] ?? 0
        }

        func isHeld(_ path: String) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            return held.contains(path)
        }

        func setRoute(_ path: String, status: Int, body: Data = Data()) {
            condition.lock()
            routes[path] = Route(status: status, body: body)
            condition.unlock()
        }

        func release(_ path: String) {
            condition.lock()
            held.remove(path)
            condition.broadcast()
            condition.unlock()
        }

        func releaseAll() {
            condition.lock()
            held.removeAll()
            condition.broadcast()
            condition.unlock()
        }

        func stop() {
            condition.lock()
            stopped = true
            held.removeAll()
            condition.broadcast()
            condition.unlock()
            listener.stop()
        }

        private func serve(_ conn: Int32) {
            defer { close(conn) }
            var request = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while request.range(of: Data("\r\n\r\n".utf8)) == nil {
                let n = read(conn, &buf, buf.count)
                guard n > 0 else { return }
                request.append(contentsOf: buf[0..<n])
                if request.count > 64 * 1024 { return }
            }
            guard let head = String(data: request, encoding: .utf8),
                  let requestLine = head.components(separatedBy: "\r\n").first else { return }
            let parts = requestLine.components(separatedBy: " ")
            guard parts.count >= 2 else { return }
            let path = parts[1]

            condition.lock()
            hits[path, default: 0] += 1
            while held.contains(path), !stopped {
                condition.wait()
            }
            let isStopped = stopped
            let route = routes[path]
            condition.unlock()

            guard !isStopped else { return }

            let status = route?.status ?? 404
            let body = route?.body ?? Data()
            let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Error")
            let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            _ = header.withCString { write(conn, $0, strlen($0)) }
            body.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let n = write(conn, base.advanced(by: offset), raw.count - offset)
                    guard n > 0 else { return }
                    offset += n
                }
            }
        }
    }

    // MARK: - Helpers

    /// Drains an `IOReader` to EOF (or `expectedBytes` if provided) on a detached thread so blocking
    /// FIFO reads never run on the cooperative pool.
    private final class AsyncDrain: @unchecked Sendable {
        private let lock = NSLock()
        private var _data = Data()
        private var _done = false

        var isDone: Bool { lock.withLock { _done } }
        var data: Data { lock.withLock { _data } }

        init(_ reader: IOReader, expectedBytes: Int? = nil) {
            Thread.detachNewThread { [self] in
                var buf = [UInt8](repeating: 0, count: 32 * 1024)
                while true {
                    let n = buf.withUnsafeMutableBufferPointer {
                        reader.read($0.baseAddress, size: Int32($0.count))
                    }
                    if n <= 0 { break }
                    let enough: Bool = lock.withLock {
                        _data.append(contentsOf: buf[0..<Int(n)])
                        if let expectedBytes { return _data.count >= expectedBytes }
                        return false
                    }
                    if enough { break }
                }
                lock.withLock { _done = true }
            }
        }
    }

    private static func makeTSSegment(tag: UInt8, packets: Int = 4) -> Data {
        var data = Data(capacity: packets * 188)
        for packet in 0..<packets {
            var ts = [UInt8](repeating: tag, count: 188)
            ts[0] = 0x47
            ts[1] = UInt8(truncatingIfNeeded: packet)
            data.append(contentsOf: ts)
        }
        return data
    }

    private static func encryptAES128CBC(_ plaintext: Data, key: Data, iv: Data) -> Data {
        var out = Data(count: plaintext.count + kCCBlockSizeAES128)
        var outLen = 0
        let status = out.withUnsafeMutableBytes { outBuf in
            plaintext.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            inBuf.baseAddress, plaintext.count,
                            outBuf.baseAddress, outBuf.count,
                            &outLen
                        )
                    }
                }
            }
        }
        precondition(status == kCCSuccess)
        out.count = outLen
        return out
    }

    private static var demuxedMasterPlaylist: Data {
        Data("""
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,AUDIO="aud"
        video.m3u8
        """.utf8)
    }

    private static var twoSegmentVideoPlaylist: Data {
        Data("""
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:1
        #EXTINF:4.0,
        v1.ts
        #EXTINF:4.0,
        v2.ts
        #EXT-X-ENDLIST
        """.utf8)
    }

    private static var twoSegmentAudioPlaylist: Data {
        Data("""
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:2
        #EXT-X-MEDIA-SEQUENCE:1
        #EXTINF:2.0,
        a1.ts
        #EXTINF:2.0,
        a2.ts
        #EXT-X-ENDLIST
        """.utf8)
    }

    // MARK: - Companion audio eager startup

    @Test("companion audio starts eagerly while main video is still fetching")
    func companionAudioStartsEagerlyWhileMainVideoFetches() async throws {
        let v1 = Self.makeTSSegment(tag: 1)
        let v2 = Self.makeTSSegment(tag: 2)
        let a1 = Self.makeTSSegment(tag: 11)
        let a2 = Self.makeTSSegment(tag: 12)
        let origin = try #require(GatedHLSOrigin(
            routes: [
                "/master.m3u8": .init(status: 200, body: Self.demuxedMasterPlaylist),
                "/video.m3u8": .init(status: 200, body: Self.twoSegmentVideoPlaylist),
                "/audio.m3u8": .init(status: 200, body: Self.twoSegmentAudioPlaylist),
                "/v1.ts": .init(status: 200, body: v1),
                "/v2.ts": .init(status: 200, body: v2),
                "/a1.ts": .init(status: 200, body: a1),
                "/a2.ts": .init(status: 200, body: a2),
            ],
            hold: ["/v1.ts"]
        ))
        defer { origin.stop() }

        let reader = HLSLiveIngestReader(playlistURL: origin.url("/master.m3u8"))
        defer { reader.close() }

        let mainDrain = AsyncDrain(reader)

        // While /v1.ts is still held at the origin, the companion must already have fetched its
        // playlist and first audio segment eagerly.
        try await waitFor {
            origin.hitCount(for: "/v1.ts") >= 1
                && origin.hitCount(for: "/audio.m3u8") >= 1
                && origin.hitCount(for: "/a1.ts") >= 1
                && reader.companionAudioReader != nil
        }
        #expect(origin.isHeld("/v1.ts"))

        let companion = try #require(reader.companionAudioReader as? HLSLiveIngestReader)
        #expect(companion.resolveSegmentFormatHint() == "mpegts")

        origin.release("/v1.ts")
        let audioDrain = AsyncDrain(companion)
        try await waitFor { mainDrain.isDone && audioDrain.isDone }

        #expect(reader.terminalError == nil)
        #expect(companion.terminalError == nil)
        #expect(mainDrain.data == v1 + v2)
        #expect(audioDrain.data == a1 + a2)
        #expect(mainDrain.data.first == 0x47)
        #expect(audioDrain.data.first == 0x47)

        reader.close()
    }

    @Test("companion audio does not start eagerly when origin budget is 1")
    func companionAudioDoesNotStartEagerlyWhenOriginBudgetIsOne() async throws {
        let v1 = Self.makeTSSegment(tag: 1)
        let v2 = Self.makeTSSegment(tag: 2)
        let a1 = Self.makeTSSegment(tag: 11)
        let a2 = Self.makeTSSegment(tag: 12)
        let origin = try #require(GatedHLSOrigin(
            routes: [
                "/master.m3u8": .init(status: 200, body: Self.demuxedMasterPlaylist),
                "/video.m3u8": .init(status: 200, body: Self.twoSegmentVideoPlaylist),
                "/audio.m3u8": .init(status: 200, body: Self.twoSegmentAudioPlaylist),
                "/v1.ts": .init(status: 200, body: v1),
                "/v2.ts": .init(status: 200, body: v2),
                "/a1.ts": .init(status: 200, body: a1),
                "/a2.ts": .init(status: 200, body: a2),
            ],
            hold: ["/v1.ts"]
        ))
        defer { origin.stop() }

        let masterURL = origin.url("/master.m3u8")
        OriginRequestBudget.shared.setHostLimit(1, for: masterURL)
        defer { OriginRequestBudget.shared.setHostLimit(nil, for: masterURL) }

        let reader = HLSLiveIngestReader(playlistURL: masterURL)
        defer { reader.close() }

        let mainDrain = AsyncDrain(reader)

        try await waitFor {
            origin.hitCount(for: "/v1.ts") >= 1 && reader.companionAudioReader != nil
        }

        let audioRequestedEagerly = try await waitFor(upTo: .milliseconds(200)) {
            origin.hitCount(for: "/audio.m3u8") > 0
        }
        #expect(!audioRequestedEagerly)
        #expect(origin.hitCount(for: "/audio.m3u8") == 0)

        origin.release("/v1.ts")
        try await waitFor { mainDrain.isDone }
        #expect(reader.terminalError == nil)
        #expect(mainDrain.data == v1 + v2)
        #expect(origin.hitCount(for: "/audio.m3u8") == 0)

        let companion = try #require(reader.companionAudioReader as? HLSLiveIngestReader)
        #expect(companion.resolveSegmentFormatHint() == "mpegts")
        #expect(origin.hitCount(for: "/audio.m3u8") == 1)

        let audioDrain = AsyncDrain(companion)
        try await waitFor { audioDrain.isDone }
        #expect(companion.terminalError == nil)
        #expect(audioDrain.data == a1 + a2)
    }

    // MARK: - AES-128 parallel and deduplicated key fetch

    @Test("AES-128 key fetch overlaps segment download and deduplicates across the join batch")
    func aes128KeyFetchOverlapsSegmentDownloadAndDeduplicatesJoinBatch() async throws {
        let keyBytes = Data((0..<16).map { UInt8($0 + 1) })
        let ivBytes = Data(repeating: 0, count: 15) + Data([1])
        let plaintext = TinyTransportStreamFixture.data
        let ciphertext = Self.encryptAES128CBC(plaintext, key: keyBytes, iv: ivBytes)

        // Five 2 s segments: the tracker's eviction margin leaves e0.ts and joins e1.ts..e4.ts as a
        // 4-segment concurrent join batch.
        let playlist = Data("""
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:2
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x00000000000000000000000000000001
        #EXTINF:2.0,
        e0.ts
        #EXTINF:2.0,
        e1.ts
        #EXTINF:2.0,
        e2.ts
        #EXTINF:2.0,
        e3.ts
        #EXTINF:2.0,
        e4.ts
        #EXT-X-ENDLIST
        """.utf8)

        let origin = try #require(GatedHLSOrigin(
            routes: [
                "/enc.m3u8": .init(status: 200, body: playlist),
                "/key.bin": .init(status: 200, body: keyBytes),
                "/e0.ts": .init(status: 200, body: ciphertext),
                "/e1.ts": .init(status: 200, body: ciphertext),
                "/e2.ts": .init(status: 200, body: ciphertext),
                "/e3.ts": .init(status: 200, body: ciphertext),
                "/e4.ts": .init(status: 200, body: ciphertext),
            ],
            hold: ["/e1.ts", "/e2.ts", "/e3.ts", "/e4.ts"]
        ))
        defer { origin.stop() }

        let reader = HLSLiveIngestReader(playlistURL: origin.url("/enc.m3u8"))
        defer { reader.close() }

        let drain = AsyncDrain(reader)

        // /key.bin must arrive while /e1.ts..e4.ts are still held, proving key fetch overlaps segment
        // download rather than running serially after it.
        try await waitFor {
            origin.hitCount(for: "/e1.ts") >= 1
                && origin.hitCount(for: "/e2.ts") >= 1
                && origin.hitCount(for: "/e3.ts") >= 1
                && origin.hitCount(for: "/e4.ts") >= 1
                && origin.hitCount(for: "/key.bin") >= 1
        }
        #expect(origin.isHeld("/e1.ts"))

        origin.releaseAll()
        try await waitFor { drain.isDone }

        var expected = Data(capacity: plaintext.count * 4)
        for _ in 0..<4 { expected.append(plaintext) }

        #expect(reader.terminalError == nil)
        #expect(drain.data == expected)
        #expect(origin.hitCount(for: "/key.bin") == 1)
    }

    @Test("failed AES-128 key fetch is not cached and the next attempt recovers")
    func aes128KeyFailureIsNotCachedAndNextAttemptRecovers() async throws {
        let keyBytes = Data((0..<16).map { UInt8($0 + 0x20) })
        let origin = try #require(GatedHLSOrigin(
            routes: [
                "/key.bin": .init(status: 500, body: Data()),
            ]
        ))
        defer { origin.stop() }

        let reader = HLSLiveIngestReader(playlistURL: origin.url("/enc.m3u8"))
        defer { reader.close() }

        let keyURL = origin.url("/key.bin")
        do {
            _ = try await reader.fetchKey(keyURL)
            Issue.record("expected HTTP 500 key fetch to throw")
        } catch let error as HLSIngestError {
            if case .playlistUnreachable(let status) = error {
                #expect(status == 500)
            } else {
                Issue.record("unexpected HLSIngestError: \(error)")
            }
        }
        #expect(reader.cachedKeyCount == 0)
        #expect(origin.hitCount(for: "/key.bin") == 1)

        origin.setRoute("/key.bin", status: 200, body: keyBytes)
        let recovered = try await reader.fetchKey(keyURL)
        #expect(recovered == keyBytes)
        #expect(reader.cachedKeyCount == 1)
        #expect(origin.hitCount(for: "/key.bin") == 2)

        // Subsequent call must hit the in-memory cache rather than issuing another HTTP request.
        let cached = try await reader.fetchKey(keyURL)
        #expect(cached == keyBytes)
        #expect(origin.hitCount(for: "/key.bin") == 2)
    }

    @Test("404 AES-128 segment still skips cleanly when its parallel key fetch fails")
    func aes128Segment404StillSkipsEvenWhenKeyFails() async throws {
        let goodKey = Data((0..<16).map { UInt8($0 + 0x40) })
        let iv2 = Data(repeating: 0, count: 15) + Data([2])
        let plaintext = TinyTransportStreamFixture.data
        let encSeg2 = Self.encryptAES128CBC(plaintext, key: goodKey, iv: iv2)

        let playlist = Data("""
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:2
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-KEY:METHOD=AES-128,URI="bad-key.bin",IV=0x00000000000000000000000000000001
        #EXTINF:2.0,
        e1.ts
        #EXT-X-KEY:METHOD=AES-128,URI="good-key.bin",IV=0x00000000000000000000000000000002
        #EXTINF:2.0,
        e2.ts
        #EXT-X-ENDLIST
        """.utf8)

        let origin = try #require(GatedHLSOrigin(
            routes: [
                "/enc.m3u8": .init(status: 200, body: playlist),
                "/e1.ts": .init(status: 404, body: Data()),
                "/bad-key.bin": .init(status: 500, body: Data()),
                "/e2.ts": .init(status: 200, body: encSeg2),
                "/good-key.bin": .init(status: 200, body: goodKey),
            ],
            hold: ["/e1.ts"]
        ))
        defer { origin.stop() }

        let reader = HLSLiveIngestReader(playlistURL: origin.url("/enc.m3u8"))
        defer { reader.close() }

        let drain = AsyncDrain(reader)

        // Wait until /bad-key.bin has been requested (and answered 500) while /e1.ts is still open,
        // then release /e1.ts with 404 to confirm the skipped segment never surfaces the key error.
        try await waitFor {
            origin.hitCount(for: "/e1.ts") >= 1 && origin.hitCount(for: "/bad-key.bin") >= 1
        }
        origin.release("/e1.ts")

        try await waitFor { drain.isDone }

        #expect(reader.terminalError == nil)
        #expect(drain.data == plaintext)
        #expect(origin.hitCount(for: "/good-key.bin") == 1)
    }
}
