import Darwin
import Foundation
import Testing
@testable import AetherEngine

/// Regression coverage for `HLSLiveIngestReader`'s process-wide `sharedSession`:
/// - `httpMaximumConnectionsPerHost` must provide headroom well above Apple's default of 6 so
///   companion audio readers and Multiview tiles do not starve one another on a single origin.
/// - `requestCachePolicy` and ephemeral storage settings must disable caching, cookies, and
///   credential storage, matching `AVIOReader.makeSessionConfig` and `HLSVODIngestReader`.
/// - Closing one reader must cancel only its own tasks and leave `sharedSession` usable by
///   concurrent and subsequent readers.
@Suite("Live HLS ingest shared session configuration", .offCooperativePool, .timeLimit(.minutes(3)))
struct HLSLiveIngestSessionConfigTests {

    // MARK: - Loopback HLS origin

    /// Minimal HTTP/1.1 loopback origin serving a two-segment ENDLIST media playlist and valid
    /// 188-byte MPEG-TS segments (Connection: close).
    private final class LoopbackHLSOrigin: @unchecked Sendable {
        let port: UInt16
        private let listener: LoopbackListener
        private let playlistBody: Data
        private let segments: [Data]

        init?(segments: [Data]) {
            self.segments = segments
            var lines = [
                "#EXTM3U",
                "#EXT-X-VERSION:3",
                "#EXT-X-TARGETDURATION:1",
                "#EXT-X-MEDIA-SEQUENCE:0",
            ]
            for index in 0..<segments.count {
                lines.append("#EXTINF:1.0,")
                lines.append("seg\(index).ts")
            }
            lines.append("#EXT-X-ENDLIST")
            self.playlistBody = Data(lines.joined(separator: "\n").utf8)

            guard let listener = LoopbackListener(backlog: 16) else { return nil }
            self.listener = listener
            self.port = listener.port
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

        func stop() {
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

            let body: Data
            let contentType: String
            if path == "/media.m3u8" {
                body = playlistBody
                contentType = "application/vnd.apple.mpegurl"
            } else if path.hasPrefix("/seg"), path.hasSuffix(".ts"),
                      let index = Int(path.dropFirst(4).dropLast(3)),
                      segments.indices.contains(index) {
                body = segments[index]
                contentType = "video/mp2t"
            } else {
                let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                _ = notFound.withCString { write(conn, $0, strlen($0)) }
                return
            }

            let header = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            _ = header.withCString { write(conn, $0, strlen($0)) }
            body.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(conn, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    guard n > 0 else { return }
                    offset += n
                }
            }
        }
    }

    private static func makeTSSegment(_ index: Int) -> Data {
        var data = Data(capacity: 4 * 188)
        for packet in 0..<4 {
            var ts = [UInt8](repeating: UInt8(truncatingIfNeeded: index), count: 188)
            ts[0] = 0x47
            ts[1] = UInt8(truncatingIfNeeded: packet)
            data.append(contentsOf: ts)
        }
        return data
    }

    /// Reads from `reader` off the test's own thread until EOF or `expectedBytes`.
    private static func drain(_ reader: HLSLiveIngestReader, expectedBytes: Int) async throws -> Data {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
            var done = false
        }
        let box = Box()
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 32 * 1024)
            while true {
                let n = buf.withUnsafeMutableBufferPointer {
                    reader.read($0.baseAddress, size: Int32($0.count))
                }
                if n <= 0 { break }
                let enough = box.lock.withLock { () -> Bool in
                    box.data.append(contentsOf: buf[0..<Int(n)])
                    return box.data.count >= expectedBytes
                }
                if enough { break }
            }
            box.lock.withLock { box.done = true }
        }
        do {
            try await waitFor { box.lock.withLock { box.done } }
        } catch {
            reader.close()
            throw error
        }
        return box.lock.withLock { box.data }
    }

    // MARK: - Tests

    @Test("makeSharedSessionConfiguration sets connection headroom, cache policy, and timeouts")
    func sharedSessionConfigurationMatchesContract() {
        let config = HLSLiveIngestReader.makeSharedSessionConfiguration()
        #expect(config.httpMaximumConnectionsPerHost == HLSLiveIngestReader.sharedSessionConnectionsPerHost)
        #expect(config.httpMaximumConnectionsPerHost >= 32)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(config.urlCache == nil)
        #expect(config.httpCookieStorage == nil)
        #expect(config.httpShouldSetCookies == false)
        #expect(config.urlCredentialStorage == nil)
        #expect(config.timeoutIntervalForRequest == 10)
        #expect(config.timeoutIntervalForResource == 30)

        let reader = HLSLiveIngestReader(playlistURL: URL(string: "http://127.0.0.1:9/media.m3u8")!)
        defer { reader.close() }
        let liveConfig = reader.session.configuration
        #expect(liveConfig.httpMaximumConnectionsPerHost == HLSLiveIngestReader.sharedSessionConnectionsPerHost)
        #expect(liveConfig.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(liveConfig.urlCache == nil)
        #expect(liveConfig.httpCookieStorage == nil)
        #expect(liveConfig.httpShouldSetCookies == false)
        #expect(liveConfig.urlCredentialStorage == nil)
        #expect(liveConfig.timeoutIntervalForRequest == 10)
        #expect(liveConfig.timeoutIntervalForResource == 30)
    }

    @Test("readers share one URLSession and closing one does not invalidate it for others")
    func closingOneReaderLeavesSharedSessionUsable() async throws {
        let segments = [Self.makeTSSegment(1), Self.makeTSSegment(2)]
        let expected = segments.reduce(Data(), +)
        let origin = try #require(LoopbackHLSOrigin(segments: segments))
        defer { origin.stop() }

        let playlistURL = origin.url("/media.m3u8")
        let first = HLSLiveIngestReader(playlistURL: playlistURL)
        let concurrent = HLSLiveIngestReader(playlistURL: playlistURL)
        defer {
            first.close()
            concurrent.close()
        }

        #expect(first.session === concurrent.session)
        let fresh = try #require(first.makeFreshMainReader())
        defer { fresh.close() }
        #expect(fresh.session === first.session)

        let firstData = try await Self.drain(first, expectedBytes: expected.count)
        #expect(firstData == expected)
        #expect(first.terminalError == nil)

        // Closing the first reader must not invalidate the shared URLSession.
        first.close()

        let concurrentData = try await Self.drain(concurrent, expectedBytes: expected.count)
        #expect(concurrentData == expected)
        #expect(concurrent.terminalError == nil)

        let subsequent = HLSLiveIngestReader(playlistURL: playlistURL)
        defer { subsequent.close() }
        #expect(subsequent.session === first.session)

        let subsequentData = try await Self.drain(subsequent, expectedBytes: expected.count)
        #expect(subsequentData == expected)
        #expect(subsequent.terminalError == nil)
    }

    @Test("shared session configuration allows more than six concurrent HTTP/1.1 requests to one host")
    func sharedSessionAllowsMoreThanSixConcurrentRequestsPerHost() async throws {
        let origin = try #require(HeldHTTPOrigin())
        defer {
            origin.release()
            origin.stop()
        }

        let session = URLSession(configuration: HLSLiveIngestReader.makeSharedSessionConfiguration())
        defer { session.invalidateAndCancel() }

        let targetConcurrency = 10
        var tasks: [URLSessionDataTask] = []
        tasks.reserveCapacity(targetConcurrency)
        defer {
            for task in tasks { task.cancel() }
        }

        for index in 0..<targetConcurrency {
            let task = session.dataTask(with: origin.url("/slot-\(index)")) { _, _, _ in }
            tasks.append(task)
            task.resume()
        }

        try await waitFor { origin.connectionCount >= targetConcurrency }
        #expect(origin.connectionCount == targetConcurrency)
    }
}
