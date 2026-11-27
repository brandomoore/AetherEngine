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

    // MARK: - Companion lifecycle, joinIsSpent, and OriginRequestBudget edge cases

    private static var liveTwoSegmentVideoPlaylist: Data {
        Data("""
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:1
        #EXTINF:6.0,
        v1.ts
        #EXTINF:6.0,
        v2.ts
        """.utf8)
    }

    private static var liveTwoSegmentAudioPlaylist: Data {
        Data("""
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:1
        #EXTINF:6.0,
        a1.ts
        #EXTINF:6.0,
        a2.ts
        """.utf8)
    }

    /// 2 s 16x16 2 fps H.264 + 48 kHz mono AAC MPEG-TS segment for live muxed-variant tests.
    private static var muxedVideoAudioTSData: Data {
        let b64 = """
        R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK////////////////
        ////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////
        //////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL/////////////////////////
        ////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////
        /////////////////////////////////////////////0dQABAAArAXAAHBAADhAPAAG+EA8AAP
        4QHwAC9EuZv/////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////R0EAMAdQ
        AAB+zH4AAAAB4AAAgIAFIQAH52EAAAABCfAAAAABZ0LACtp7ARAAAAMAEAAAAwBA8SJqAAAAAWjO
        AZcgAAABBgX//03cRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEg
        LSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3
        dy52aWRlb2xhbi5HAQARb3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVi
        bG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDow
        LjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9
        MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X0cBABJwc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9
        MCB0aHJlYWRzPTEgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVj
        aW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAg
        YmZyYW1lcz0wIHdlaWdodHA9MCBrZXlpbnQ9MiBrZXlpbnRfbWluPTIgc2NlRwEAM0EA////////
        ////////////////////////////////////////////////////////////////////////////
        /25lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9NTEuMCBxY29tcD0w
        LjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0wAIAAAAFliIQ6
        JigAFcBHQQEwAUAAAAHAANKAgAUhAAfYYf/xTEADX/zcAExhdmM2My4xLjEwMgACMEAO//FMQAF/
        /AEYIAf/8UxAAX/8ARggB//xTEABf/wBGCAH//FMQAF//AEYIAf/8UxAAX/8ARggB//xTEABf/wB
        GCAH//FMQAF//AEYIAf/8UxAAX/8ARggB//xTEABf/wBGCAH//FMQAF//AEYIAf/8UxAAX/8ARgg
        B//xTEABf/wBGCAH//FMQAF//AEYIEcBATGVAP//////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////
        //////8H//FMQAF//AEYIAf/8UxAAX/8ARggB//xTEABf/wBGCAHR0EANJoQAADWsH4A////////
        ////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////AAAB4AAAgIAFIQALRvEAAAABCfAAAAABQZogEqVH
        QQEyAUAAAAHAAMOAgAUhAAnXYf/xTEABf/wBGCAH//FMQAF//AEYIAf/8UxAAX/8ARggB//xTEAB
        f/wBGCAH//FMQAF//AEYIAf/8UxAAX/8ARggB//xTEABf/wBGCAH//FMQAF//AEYIAf/8UxAAX/8
        ARggB//xTEABf/wBGCAH//FMQAF//AEYIAf/8UxAAX/8ARggB//xTEABf/wBGCAH//FMQAF//AEY
        IAf/8UxAAX/8ARggB//xTEcBATOkAP//////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////
        //////////////////9AAX/8ARggB//xTEABf/wBGCAHR0AAEQAAsA0AAcEAAAAB8AAqsQSy////
        ////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////
        //////////////////////////////////////////////////////////////////9HUAARAAKw
        FwABwQAA4QDwABvhAPAAD+EB8AAvRLmb////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////
        /////////////0dBADVzUAABLpR+AP//////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////
        /////////////////////wAAAeAAAICABSEADaaBAAAAAQnwAAAAAWdCwAraewEQAAADABAAAAMA
        QPEiagAAAAFozgGXIAAAAWWIggMomKAAID+AR0EBNAFAAAABwADDgIAFIQAL1mH/8UxAAX/8ARgg
        B//xTEABf/wBGCAH//FMQAF//AEYIAf/8UxAAX/8ARggB//xTEABf/wBGCAH//FMQAF//AEYIAf/
        8UxAAX/8ARggB//xTEABf/wBGCAH//FMQAF//AEYIAf/8UxAAX/8ARggB//xTEABf/wBGCAH//FM
        QAF//AEYIAf/8UxAAX/8ARggB//xTEABf/wBGCAH//FMQAF//AEYIAf/8UxHAQE1pAD/////////
        ////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////QAF//AEYIAf/8UxAAX/8
        ARggB0dBATYBQAAAAcAAw4CABSEADdVh//FMQAF//AEYIAf/8UxAAX/8ARggB//xTEABf/wBGCAH
        //FMQAF//AEYIAf/8UxAAX/8ARggB//xTEABf/wBGCAH//FMQAF//AEYIAf/8UxAAX/8ARggB//x
        TEABf/wBGCAH//FMQAF//AEYIAf/8UxAAX/8ARggB//xTEABf/wBGCAH//FMQAF//AEYIAf/8UxA
        AX/8ARggB//xTEABf/wBGCAH//FMRwEBN6QA////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////
        /////////////////////////0ABf/wBGCAH//FMQAF//AEYIAdHQQA2mhAAAYZ4fgD/////////
        ////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////
        //////////////////////////////////8AAAHgAACAgAUhABEGEQAAAAEJ8AAAAAFBmiASpUdB
        ATgBQAAAAcAAw4CABSEAD9Rh//FMQAF//AEYIAf/8UxAAX/8ARggB//xTEABf/wBGCAH//FMQAF/
        /AEYIAf/8UxAAX/8ARggB//xTEABf/wBGCAH//FMQAF//AEYIAf/8UxAAX/8ARggB//xTEABf/wB
        GCAH//FMQAF//AEYIAf/8UxAAX/8ARggB//xTEABf/wBGCAH//FMQAF//AEYIAf/8UxAAX/8ARgg
        B//xTEABf/wBGCAH//FMRwEBOaQA////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////
        ////////////////////////////////////////////////////////////////////////////
        /////////////////0ABf/wBGCAH//FMQAF//AEYIAdHQQE6O0D/////////////////////////
        ////////////////////////////////////////////////////AAABwAB2gIAFIQAR02H/8UxA
        AX/8ARggB//xTEABf/wBGCAH//FMQAF//AEYIAf/8UxAAX/8ARggB//xTEABf/wBGCAH//FMQAF/
        /AEYIAf/8UxAAX/8ARggB//xTEABf/wBGCAH//FMQAF//AEYIAf/8UxAAX/8ARggBw==
        """
        return Data(base64Encoded: b64, options: .ignoreUnknownCharacters)!
    }

    @Test("eagerly started companion with no attached consumer does not block main joinIsSpent")
    func unreadEagerCompanionDoesNotBlockMainJoinIsSpent() async throws {
        let v1 = Self.makeTSSegment(tag: 1)
        let v2 = Self.makeTSSegment(tag: 2)
        let a1 = Self.makeTSSegment(tag: 11)
        let a2 = Self.makeTSSegment(tag: 12)
        let origin = try #require(GatedHLSOrigin(
            routes: [
                "/master.m3u8": .init(status: 200, body: Self.demuxedMasterPlaylist),
                "/video.m3u8": .init(status: 200, body: Self.liveTwoSegmentVideoPlaylist),
                "/audio.m3u8": .init(status: 200, body: Self.liveTwoSegmentAudioPlaylist),
                "/v1.ts": .init(status: 200, body: v1),
                "/v2.ts": .init(status: 200, body: v2),
                "/a1.ts": .init(status: 200, body: a1),
                "/a2.ts": .init(status: 200, body: a2),
            ],
            hold: ["/a2.ts"]
        ))
        defer { origin.stop() }

        let reader = HLSLiveIngestReader(playlistURL: origin.url("/master.m3u8"))
        defer { reader.close() }

        // Drain without an expectedBytes cap so the consumer parks on the live FIFO after v1 + v2.
        let mainDrain = AsyncDrain(reader)

        try await waitFor {
            mainDrain.data.count == v1.count + v2.count
                && origin.hitCount(for: "/a1.ts") >= 1
                && origin.hitCount(for: "/a2.ts") >= 1
                && reader.pumpJoinState.parked
        }
        let companion = try #require(reader.companionAudioReader as? HLSLiveIngestReader)
        #expect(origin.isHeld("/a2.ts"))
        #expect(!companion.pumpJoinState.committed)
        #expect(!companion.pumpJoinState.started, "eager prefetch without a consumer must not count as active")
        #expect(reader.joinIsSpent)
    }

    @Test("closing a companion on muxed-audio fallback unblocks joinIsSpent and frees buffered bytes")
    func closedCompanionOnMuxedFallbackUnblocksJoinIsSpentAndFreesBuffer() async throws {
        let v1 = Self.makeTSSegment(tag: 1)
        let v2 = Self.makeTSSegment(tag: 2)
        let a1 = Self.makeTSSegment(tag: 11)
        let a2 = Self.makeTSSegment(tag: 12)

        // Case 1: consumer attaches via resolveSegmentFormatHint while a2.ts is held (join uncommitted,
        // a1.ts already buffered in FIFO), then companion.close() runs on fallback.
        do {
            let origin = try #require(GatedHLSOrigin(
                routes: [
                    "/master.m3u8": .init(status: 200, body: Self.demuxedMasterPlaylist),
                    "/video.m3u8": .init(status: 200, body: Self.liveTwoSegmentVideoPlaylist),
                    "/audio.m3u8": .init(status: 200, body: Self.liveTwoSegmentAudioPlaylist),
                    "/v1.ts": .init(status: 200, body: v1),
                    "/v2.ts": .init(status: 200, body: v2),
                    "/a1.ts": .init(status: 200, body: a1),
                    "/a2.ts": .init(status: 200, body: a2),
                ],
                hold: ["/a2.ts"]
            ))
            defer { origin.stop() }

            let reader = HLSLiveIngestReader(playlistURL: origin.url("/master.m3u8"))
            defer { reader.close() }

            let mainDrain = AsyncDrain(reader)
            try await waitFor {
                mainDrain.data.count == v1.count + v2.count
                    && reader.companionAudioReader != nil
                    && reader.pumpJoinState.parked
            }
            let companion = try #require(reader.companionAudioReader as? HLSLiveIngestReader)
            #expect(companion.resolveSegmentFormatHint() == "mpegts")
            try await waitFor { companion.bufferedByteCount == a1.count }

            // While the attached companion is still open and waiting on held a2.ts, joinIsSpent is false.
            #expect(companion.pumpJoinState.started)
            #expect(!companion.pumpJoinState.committed)
            #expect(!reader.joinIsSpent)

            // Simulate HLSVideoEngine muxed-audio fallback closing the unusable companion.
            companion.close()
            #expect(companion.isIngestClosed)
            #expect(companion.bufferedByteCount == 0)
            #expect(!companion.pumpJoinState.started)
            #expect(reader.joinIsSpent)
        }

        // Case 2: companion fails before committing its join batch (404 audio playlist -> nil format hint).
        do {
            let origin = try #require(GatedHLSOrigin(
                routes: [
                    "/master.m3u8": .init(status: 200, body: Self.demuxedMasterPlaylist),
                    "/video.m3u8": .init(status: 200, body: Self.liveTwoSegmentVideoPlaylist),
                    "/audio.m3u8": .init(status: 404, body: Data()),
                    "/v1.ts": .init(status: 200, body: v1),
                    "/v2.ts": .init(status: 200, body: v2),
                ]
            ))
            defer { origin.stop() }

            let reader = HLSLiveIngestReader(playlistURL: origin.url("/master.m3u8"))
            defer { reader.close() }

            let mainDrain = AsyncDrain(reader)
            try await waitFor {
                mainDrain.data.count == v1.count + v2.count
                    && reader.companionAudioReader != nil
                    && reader.pumpJoinState.parked
            }
            let companion = try #require(reader.companionAudioReader as? HLSLiveIngestReader)
            #expect(companion.resolveSegmentFormatHint() == nil)
            companion.close()
            #expect(companion.isIngestClosed)
            #expect(reader.joinIsSpent)
        }
    }

    @Test("paced origins and cross-host single-slot master playlists skip speculative overlap")
    func pacedAndCrossHostSerialOriginsSkipSpeculativeOverlap() async throws {
        // 1. Paced origin disarms speculative overlap even when concurrency limit > 1.
        // Use dedicated GatedHLSOrigin ports rather than OriginRequestBudget.resetForTesting()
        // so parallel tests keep their per-origin host limits intact.
        let pacedOrigin = try #require(GatedHLSOrigin(routes: [:]))
        let unpacedOrigin = try #require(GatedHLSOrigin(routes: [:]))
        defer {
            pacedOrigin.stop()
            unpacedOrigin.stop()
        }
        let pacedURL = pacedOrigin.url("/master.m3u8")
        let targetURL = unpacedOrigin.url("/audio.m3u8")
        let pin = OriginRequestBudget.shared.pinQuietPeriodCapForTesting(5)
        defer { pin.release() }
        OriginRequestBudget.shared.noteRefusal(for: pacedURL, status: 429, retryAfter: nil)
        #expect(OriginRequestBudget.shared.isPaced(pacedURL))
        #expect(!HLSLiveIngestReader.allowsSpeculativeOverlap(readerOriginURL: pacedURL, targetURL: targetURL))
        #expect(!HLSLiveIngestReader.allowsSpeculativeOverlap(readerOriginURL: targetURL, targetURL: pacedURL))

        // 2. Cross-host master playlist: host limit 1 on master origin suppresses eager companion fetch
        // on a separate rendition host while video is held.
        let v1 = Self.makeTSSegment(tag: 1)
        let a1 = Self.makeTSSegment(tag: 11)
        let mediaOrigin = try #require(GatedHLSOrigin(
            routes: [
                "/video.m3u8": .init(status: 200, body: Self.twoSegmentVideoPlaylist),
                "/audio.m3u8": .init(status: 200, body: Self.twoSegmentAudioPlaylist),
                "/v1.ts": .init(status: 200, body: v1),
                "/v2.ts": .init(status: 200, body: v1),
                "/a1.ts": .init(status: 200, body: a1),
                "/a2.ts": .init(status: 200, body: a1),
            ],
            hold: ["/v1.ts"]
        ))
        defer { mediaOrigin.stop() }

        let crossHostMaster = Data("""
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,AUTOSELECT=YES,URI="\(mediaOrigin.url("/audio.m3u8").absoluteString)"
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,AUDIO="aud"
        \(mediaOrigin.url("/video.m3u8").absoluteString)
        """.utf8)
        let portalOrigin = try #require(GatedHLSOrigin(
            routes: [
                "/master.m3u8": .init(status: 200, body: crossHostMaster),
            ]
        ))
        defer { portalOrigin.stop() }

        let masterURL = portalOrigin.url("/master.m3u8")
        OriginRequestBudget.shared.setHostLimit(1, for: masterURL)
        defer { OriginRequestBudget.shared.setHostLimit(nil, for: masterURL) }

        let reader = HLSLiveIngestReader(playlistURL: masterURL)
        defer { reader.close() }

        let mainDrain = AsyncDrain(reader)
        try await waitFor {
            mediaOrigin.hitCount(for: "/v1.ts") >= 1 && reader.companionAudioReader != nil
        }

        let audioRequestedEagerly = try await waitFor(upTo: .milliseconds(200)) {
            mediaOrigin.hitCount(for: "/audio.m3u8") > 0
        }
        #expect(!audioRequestedEagerly)
        #expect(mediaOrigin.hitCount(for: "/audio.m3u8") == 0)

        mediaOrigin.release("/v1.ts")
        try await waitFor { mainDrain.isDone }
        #expect(mediaOrigin.hitCount(for: "/audio.m3u8") == 0)
    }

    @Test("software and audio-only live loads close an eagerly started companion audio reader")
    @MainActor
    func softwareAndAudioOnlyLiveLoadsCloseEagerCompanion() async throws {
        let muxedSeg = Self.muxedVideoAudioTSData
        let audioSeg = Self.makeTSSegment(tag: 21)
        let origin = try #require(GatedHLSOrigin(
            routes: [
                "/master.m3u8": .init(status: 200, body: Self.demuxedMasterPlaylist),
                "/video.m3u8": .init(status: 200, body: Self.liveTwoSegmentVideoPlaylist),
                "/audio.m3u8": .init(status: 200, body: Self.liveTwoSegmentAudioPlaylist),
                "/v1.ts": .init(status: 200, body: muxedSeg),
                "/v2.ts": .init(status: 200, body: muxedSeg),
                "/a1.ts": .init(status: 200, body: audioSeg),
                "/a2.ts": .init(status: 200, body: audioSeg),
            ]
        ))
        defer { origin.stop() }

        // 1. Live muxed variant routed to software decode closes the unused companion reader.
        do {
            let engine = try AetherEngine()
            defer { engine.stop() }
            let reader = HLSLiveIngestReader(playlistURL: origin.url("/master.m3u8"))
            defer { reader.close() }

            var options = LoadOptions()
            options.isLive = true
            options.autoplay = false
            options.preferredDecodePath = .software

            _ = try await engine.load(source: .custom(reader, formatHint: "mpegts"), options: options)
            let companion = try #require(reader.companionAudioReader as? HLSLiveIngestReader)
            #expect(engine.playbackBackend == .software)
            #expect(companion.isIngestClosed)
            #expect(companion.bufferedByteCount == 0)
        }

        // 2. Live muxed variant routed to audio-only playback closes the unused companion reader.
        do {
            let engine = try AetherEngine()
            defer { engine.stop() }
            let reader = HLSLiveIngestReader(playlistURL: origin.url("/master.m3u8"))
            defer { reader.close() }

            var options = LoadOptions()
            options.isLive = true
            options.autoplay = false
            options.audioOnly = true

            _ = try await engine.load(source: .custom(reader, formatHint: "mpegts"), options: options)
            let companion = try #require(reader.companionAudioReader as? HLSLiveIngestReader)
            #expect(engine.playbackBackend == .audio)
            #expect(companion.isIngestClosed)
            #expect(companion.bufferedByteCount == 0)
        }

        // 3. Video-only live variant with companion audio routed to software fast-fails and closes the companion.
        do {
            let videoOnlySeg = TinyTransportStreamFixture.data
            let videoOnlyOrigin = try #require(GatedHLSOrigin(
                routes: [
                    "/master.m3u8": .init(status: 200, body: Self.demuxedMasterPlaylist),
                    "/video.m3u8": .init(status: 200, body: Self.liveTwoSegmentVideoPlaylist),
                    "/audio.m3u8": .init(status: 200, body: Self.liveTwoSegmentAudioPlaylist),
                    "/v1.ts": .init(status: 200, body: videoOnlySeg),
                    "/v2.ts": .init(status: 200, body: videoOnlySeg),
                    "/a1.ts": .init(status: 200, body: audioSeg),
                    "/a2.ts": .init(status: 200, body: audioSeg),
                ]
            ))
            defer { videoOnlyOrigin.stop() }

            let engine = try AetherEngine()
            defer { engine.stop() }
            let reader = HLSLiveIngestReader(playlistURL: videoOnlyOrigin.url("/master.m3u8"))
            defer { reader.close() }

            var options = LoadOptions()
            options.isLive = true
            options.autoplay = false
            options.preferredDecodePath = .software

            await #expect(throws: HLSIngestError.self) {
                _ = try await engine.load(source: .custom(reader, formatHint: "mpegts"), options: options)
            }
            let companion = try #require(reader.companionAudioReader as? HLSLiveIngestReader)
            #expect(companion.isIngestClosed)
            #expect(companion.bufferedByteCount == 0)
        }
    }

    @Test("HLSVideoEngine muxed-audio fallback closes unusable companion and lets joinIsSpent settle")
    func hlsVideoEngineMuxedFallbackClosesCompanionAndSettlesJoinIsSpent() async throws {
        let muxedSeg = Self.muxedVideoAudioTSData
        let singleLiveVideoPlaylist = Data("""
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:12
        #EXT-X-MEDIA-SEQUENCE:1
        #EXTINF:12.0,
        v1.ts
        """.utf8)
        let origin = try #require(GatedHLSOrigin(
            routes: [
                "/master.m3u8": .init(status: 200, body: Self.demuxedMasterPlaylist),
                "/video.m3u8": .init(status: 200, body: singleLiveVideoPlaylist),
                "/audio.m3u8": .init(status: 404, body: Data()),
                "/v1.ts": .init(status: 200, body: muxedSeg),
            ]
        ))
        defer { origin.stop() }

        let reader = HLSLiveIngestReader(playlistURL: origin.url("/master.m3u8"))
        defer { reader.close() }

        // Bound probe below the 4-frame fixture length so find_stream_info returns immediately
        // without parking until the live ingest stall counter cancels the FIFO.
        let fastProbeProfile = DemuxerOpenProfile.livePlayback.withProbeBudget(
            probesize: 4 * 1024,
            maxAnalyzeDuration: 500_000
        )
        let preopened = try await BlockingWork.detached {
            let dem = Demuxer()
            try dem.open(reader: reader, formatHint: "mpegts", profile: fastProbeProfile, isLive: true)
            return dem
        }.value
        let companion = try #require(reader.companionAudioReader as? HLSLiveIngestReader)

        let session = HLSVideoEngine(
            url: URL(string: "aether-custom://source")!,
            isLiveSession: true,
            liveStartupSingleSegmentMinimumSeconds: 0.5,
            liveCutTargetSeconds: 0.5,
            liveCadenceObservation: { [weak reader] in reader?.observedLiveCadenceSeconds },
            liveJoinSpentObservation: { [weak reader] in reader?.joinIsSpent },
            preopenedDemuxer: preopened,
            sourceReopenableByURL: false,
            companionAudioReader: companion
        )
        defer { session.stop() }

        _ = try await BlockingWork.detached {
            try session.start()
        }.value

        #expect(companion.isIngestClosed)
        #expect(companion.bufferedByteCount == 0)
        try await waitFor { reader.joinIsSpent }
    }

    @Test("AES-128 key fetch falls back to serial after segment download when origin is single-slot")
    func aes128KeyFetchFallsBackToSerialWhenOriginIsSingleSlot() async throws {
        let keyBytes = Data((0..<16).map { UInt8($0 + 0x50) })
        let ivBytes = Data(repeating: 0, count: 15) + Data([1])
        let plaintext = TinyTransportStreamFixture.data
        let ciphertext = Self.encryptAES128CBC(plaintext, key: keyBytes, iv: ivBytes)

        let playlist = Data("""
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:2
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x00000000000000000000000000000001
        #EXTINF:2.0,
        e1.ts
        #EXT-X-ENDLIST
        """.utf8)

        let origin = try #require(GatedHLSOrigin(
            routes: [
                "/enc.m3u8": .init(status: 200, body: playlist),
                "/e1.ts": .init(status: 200, body: ciphertext),
                "/key.bin": .init(status: 200, body: keyBytes),
            ],
            hold: ["/e1.ts"]
        ))
        defer { origin.stop() }

        let playlistURL = origin.url("/enc.m3u8")
        OriginRequestBudget.shared.setHostLimit(1, for: playlistURL)
        defer { OriginRequestBudget.shared.setHostLimit(nil, for: playlistURL) }

        let reader = HLSLiveIngestReader(playlistURL: playlistURL)
        defer { reader.close() }

        let drain = AsyncDrain(reader)
        try await waitFor { origin.hitCount(for: "/e1.ts") >= 1 }

        let keyRequestedWhileSegmentHeld = try await waitFor(upTo: .milliseconds(200)) {
            origin.hitCount(for: "/key.bin") > 0
        }
        #expect(!keyRequestedWhileSegmentHeld)
        #expect(origin.hitCount(for: "/key.bin") == 0)

        origin.release("/e1.ts")
        try await waitFor { drain.isDone }
        #expect(reader.terminalError == nil)
        #expect(drain.data == plaintext)
        #expect(origin.hitCount(for: "/key.bin") == 1)
    }

    @Test("terminal main ingest and non-muxed companion open failures close eager companion immediately")
    @MainActor
    func terminalMainIngestAndFailedCompanionOpenCloseEagerCompanion() async throws {
        let fmp4VideoPlaylist = Data("""
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6.0,
        v1.m4s
        """.utf8)
        let audioSeg = Self.makeTSSegment(tag: 31)

        // 1. Direct HLSLiveIngestReader: main variant goes terminal on EXT-X-MAP after eagerly starting
        // its companion audio reader; companion must close without waiting for caller reader.close().
        do {
            let origin = try #require(GatedHLSOrigin(
                routes: [
                    "/master.m3u8": .init(status: 200, body: Self.demuxedMasterPlaylist),
                    "/video.m3u8": .init(status: 200, body: fmp4VideoPlaylist),
                    "/audio.m3u8": .init(status: 200, body: Self.liveTwoSegmentAudioPlaylist),
                    "/a1.ts": .init(status: 200, body: audioSeg),
                    "/a2.ts": .init(status: 200, body: audioSeg),
                ]
            ))
            defer { origin.stop() }

            let reader = HLSLiveIngestReader(playlistURL: origin.url("/master.m3u8"))
            defer { reader.close() }

            let drain = AsyncDrain(reader)
            try await waitFor { drain.isDone }
            #expect(reader.terminalError == .unsupportedSegmentFormat)

            let companion = try #require(reader.companionAudioReader as? HLSLiveIngestReader)
            try await waitFor { companion.isIngestClosed }
            #expect(companion.bufferedByteCount == 0)
        }

        // 2. Engine-built live HLS reroute (AE#678): failed load closes both the engine-built main
        // ingest reader and its companion audio reader before throwing.
        do {
            let origin = try #require(GatedHLSOrigin(
                routes: [
                    "/master.m3u8": .init(status: 200, body: Self.demuxedMasterPlaylist),
                    "/video.m3u8": .init(status: 200, body: fmp4VideoPlaylist),
                    "/audio.m3u8": .init(status: 200, body: Self.liveTwoSegmentAudioPlaylist),
                    "/a1.ts": .init(status: 200, body: audioSeg),
                    "/a2.ts": .init(status: 200, body: audioSeg),
                ]
            ))
            defer { origin.stop() }

            let engine = try AetherEngine()
            defer { engine.stop() }
            let masterURL = origin.url("/master.m3u8")
            RemoteHLSMediaSelection.noteLivePlaylist(masterURL)

            var options = LoadOptions()
            options.isLive = true
            options.autoplay = false

            await #expect(throws: HLSIngestError.self) {
                _ = try await engine.load(source: .url(masterURL), options: options)
            }
            let engineIngest = try #require(engine.customReader as? HLSLiveIngestReader)
            #expect(engineIngest.isIngestClosed)
            #expect(engineIngest.bufferedByteCount == 0)
        }

        // 3. HLSVideoEngine with video-only main (no muxed audio fallback) and unusable companion
        // closes the companion before throwing.
        do {
            let videoOnlySeg = TinyTransportStreamFixture.data
            let singleLiveVideoPlaylist = Data("""
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:12
            #EXT-X-MEDIA-SEQUENCE:1
            #EXTINF:12.0,
            v1.ts
            """.utf8)
            let origin = try #require(GatedHLSOrigin(
                routes: [
                    "/master.m3u8": .init(status: 200, body: Self.demuxedMasterPlaylist),
                    "/video.m3u8": .init(status: 200, body: singleLiveVideoPlaylist),
                    "/audio.m3u8": .init(status: 404, body: Data()),
                    "/v1.ts": .init(status: 200, body: videoOnlySeg),
                ]
            ))
            defer { origin.stop() }

            let reader = HLSLiveIngestReader(playlistURL: origin.url("/master.m3u8"))
            defer { reader.close() }

            let fastProbeProfile = DemuxerOpenProfile.liveHLSIngest.withProbeBudget(
                probesize: 4 * 1024,
                maxAnalyzeDuration: 500_000
            )
            let preopened = try await BlockingWork.detached {
                let dem = Demuxer()
                try dem.open(reader: reader, formatHint: "mpegts", profile: fastProbeProfile, isLive: true)
                return dem
            }.value
            let companion = try #require(reader.companionAudioReader as? HLSLiveIngestReader)

            let session = HLSVideoEngine(
                url: URL(string: "aether-custom://source")!,
                isLiveSession: true,
                liveStartupSingleSegmentMinimumSeconds: 0.5,
                liveCutTargetSeconds: 0.5,
                preopenedDemuxer: preopened,
                sourceReopenableByURL: false,
                companionAudioReader: companion
            )
            defer { session.stop() }

            await #expect(throws: HLSVideoEngine.HLSVideoEngineError.self) {
                _ = try await BlockingWork.detached {
                    try session.start()
                }.value
            }
            #expect(companion.isIngestClosed)
            #expect(companion.bufferedByteCount == 0)
        }
    }

    @Test("cancelling the last waiter aborts an in-flight AES-128 key fetch and allows a fresh retry")
    func cancellingLastWaiterAbortsInFlightKeyFetchAndAllowsRetry() async throws {
        let keyBytes = Data((0..<16).map { UInt8($0 + 0x60) })
        let origin = try #require(GatedHLSOrigin(
            routes: [
                "/hung-key.bin": .init(status: 200, body: keyBytes),
            ],
            hold: ["/hung-key.bin"]
        ))
        defer { origin.stop() }

        let reader = HLSLiveIngestReader(playlistURL: origin.url("/enc.m3u8"))
        defer { reader.close() }
        let keyURL = origin.url("/hung-key.bin")

        let waiter1 = Task { try await reader.fetchKey(keyURL) }
        let waiter2 = Task { try await reader.fetchKey(keyURL) }

        try await waitFor {
            origin.hitCount(for: "/hung-key.bin") == 1 && reader.inFlightKeyFetchCount == 1
        }

        // Cancelling only one waiter keeps the shared key fetch alive for the remaining waiter.
        waiter1.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiter1.value }
        #expect(reader.inFlightKeyFetchCount == 1)

        // Cancelling the last remaining waiter aborts the shared fetch and clears the in-flight entry.
        waiter2.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiter2.value }
        try await waitFor { reader.inFlightKeyFetchCount == 0 }

        // Releasing the origin allows a subsequent fetchKey call to start a fresh request cleanly.
        origin.release("/hung-key.bin")
        let recovered = try await reader.fetchKey(keyURL)
        #expect(recovered == keyBytes)
        #expect(origin.hitCount(for: "/hung-key.bin") == 2)
    }

    @Test("multi-slot capped origins partition companion concurrency and avoid speculative key overcommit")
    func cappedOriginsPartitionCompanionSlotsAndGuardKeyHeadroom() async throws {
        // 1. Slot partitioning across shared-origin main video and companion audio.
        #expect(HLSLiveIngestReader.segmentFetchConcurrency(budgetLimit: nil, sharesOriginWithPartner: true, role: .mainVideo) == 4)
        #expect(HLSLiveIngestReader.segmentFetchConcurrency(budgetLimit: 2, sharesOriginWithPartner: true, role: .mainVideo) == 1)
        #expect(HLSLiveIngestReader.segmentFetchConcurrency(budgetLimit: 2, sharesOriginWithPartner: true, role: .companionAudio) == 1)
        #expect(HLSLiveIngestReader.segmentFetchConcurrency(budgetLimit: 3, sharesOriginWithPartner: true, role: .mainVideo) == 2)
        #expect(HLSLiveIngestReader.segmentFetchConcurrency(budgetLimit: 3, sharesOriginWithPartner: true, role: .companionAudio) == 1)
        #expect(HLSLiveIngestReader.segmentFetchConcurrency(budgetLimit: 4, sharesOriginWithPartner: true, role: .mainVideo) == 2)
        #expect(HLSLiveIngestReader.segmentFetchConcurrency(budgetLimit: 4, sharesOriginWithPartner: true, role: .companionAudio) == 2)

        // 2. Two-segment AES-128 batch on a 2-slot origin fills both slots with segments rather than
        // parking a speculative 3rd key request behind them.
        let keyBytes = Data((0..<16).map { UInt8($0 + 0x70) })
        let ivBytes = Data(repeating: 0, count: 15) + Data([1])
        let plaintext = TinyTransportStreamFixture.data
        let ciphertext = Self.encryptAES128CBC(plaintext, key: keyBytes, iv: ivBytes)

        let twoSegPlaylist = Data("""
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:2
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x00000000000000000000000000000001
        #EXTINF:2.0,
        e1.ts
        #EXTINF:2.0,
        e2.ts
        #EXT-X-ENDLIST
        """.utf8)

        let origin = try #require(GatedHLSOrigin(
            routes: [
                "/enc.m3u8": .init(status: 200, body: twoSegPlaylist),
                "/e1.ts": .init(status: 200, body: ciphertext),
                "/e2.ts": .init(status: 200, body: ciphertext),
                "/key.bin": .init(status: 200, body: keyBytes),
            ],
            hold: ["/e1.ts", "/e2.ts"]
        ))
        defer { origin.stop() }

        let playlistURL = origin.url("/enc.m3u8")
        OriginRequestBudget.shared.setHostLimit(2, for: playlistURL)
        defer { OriginRequestBudget.shared.setHostLimit(nil, for: playlistURL) }

        let reader = HLSLiveIngestReader(playlistURL: playlistURL)
        defer { reader.close() }

        let drain = AsyncDrain(reader)
        try await waitFor {
            origin.hitCount(for: "/e1.ts") >= 1 && origin.hitCount(for: "/e2.ts") >= 1
        }

        let keyOvercommitted = try await waitFor(upTo: .milliseconds(200)) {
            origin.hitCount(for: "/key.bin") > 0
        }
        #expect(!keyOvercommitted)
        #expect(origin.hitCount(for: "/key.bin") == 0)

        origin.releaseAll()
        try await waitFor { drain.isDone }
        #expect(reader.terminalError == nil)
        #expect(drain.data == plaintext + plaintext)
        #expect(origin.hitCount(for: "/key.bin") == 1)
    }
}
