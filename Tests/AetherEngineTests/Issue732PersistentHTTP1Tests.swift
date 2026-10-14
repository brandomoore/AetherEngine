import Foundation
import XCTest
@testable import AetherEngine

/// AE#732: under `heldSourceConnection` the HLS VOD ingest carries its playlist, probe and segment
/// requests over one persistent HTTP/1.1 connection per origin, across segment boundaries.
final class Issue732PersistentHTTP1Tests: XCTestCase {

    func testReaderCarriesPlaylistProbeAndEverySegmentOverOneConnection() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        let segments = (0..<5).map { "seg\($0).ts" }
        server.route = { path in
            if path == "/vod.m3u8" { return .init(body: Self.mediaPlaylist(segments)) }
            guard let index = segments.firstIndex(where: { "/" + $0 == path }) else { return .init(status: 404) }
            return .init(body: Self.transportStream(marker: UInt8(index)))
        }

        let made = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: server.url("/vod.m3u8"),
            httpHeaders: ["X-Fixture": "allowed"],
            persistentHTTP1: true)
        let reader = try XCTUnwrap(made)
        defer { reader.close() }

        let stream = Self.drain(reader)
        XCTAssertEqual(stream.count, 5 * 188 * 3)
        XCTAssertEqual((0..<5).map { stream[$0 * 188 * 3 + Self.markerOffset] }, [0, 1, 2, 3, 4])

        let log = server.requests
        XCTAssertEqual(server.connectionCount, 1, "every request rides the first connection")
        // The probe downloaded segment 0 whole, so the producer does not ask for it again.
        XCTAssertEqual(log.map(\.path), ["/vod.m3u8"] + segments.map { "/" + $0 })
        XCTAssertTrue(log.allSatisfy { $0.requestLine.hasSuffix(" HTTP/1.1") })
        XCTAssertTrue(log.allSatisfy { $0.headers["range"] == nil })
        XCTAssertTrue(log.allSatisfy { $0.headers["x-fixture"] == "allowed" })
    }

    func testReaderSurvivesASeekThatCancelsAFetchMidBody() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        let segments = (0..<6).map { "seg\($0).ts" }
        server.route = { path in
            if path == "/vod.m3u8" { return .init(body: Self.mediaPlaylist(segments)) }
            guard let index = segments.firstIndex(where: { "/" + $0 == path }) else { return .init(status: 404) }
            // Segment 2 trickles, so the seek below lands while it is mid-body.
            return .init(body: Self.transportStream(marker: UInt8(index)), trickleUs: index == 2 ? 200_000 : 0)
        }
        let made = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: server.url("/vod.m3u8"), httpHeaders: [:], persistentHTTP1: true)
        let reader = try XCTUnwrap(made)
        defer { reader.close() }

        var head = [UInt8](repeating: 0, count: 188)
        XCTAssertEqual(head.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 188) }, 188)
        try await waitUntil { server.requests.contains { $0.path == "/seg2.ts" } }

        XCTAssertTrue(reader.seek(to: 26)) // segment 4 contains 26 s, the restart is one earlier
        let stream = Self.drain(reader)
        XCTAssertEqual(stream.count, 3 * 188 * 3)
        XCTAssertEqual(stream[Self.markerOffset], 3)
        XCTAssertEqual(server.connectionCount, 2, "the cancelled body cost its connection, nothing more")
    }

    func testServerCloseOpensAFreshConnection() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        server.route = { path in .init(body: Data(path.utf8), connectionClose: path == "/b") }
        let transport = PersistentHTTP1Transport(label: "test")
        defer { transport.close() }

        for path in ["/a", "/b", "/c", "/d"] {
            let answer = try await transport.get(server.url(path), headers: [:], limit: 1024)
            XCTAssertEqual(answer.response.statusCode, 200)
            XCTAssertEqual(String(decoding: answer.body, as: UTF8.self), path)
        }
        XCTAssertEqual(server.requests.map(\.connection), [1, 1, 2, 2])
    }

    func testIdleConnectionDroppedByTheOriginIsRetriedOnce() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        // Hangs up after every response without saying so, which is what an origin's idle timeout
        // looks like to the next request on that connection.
        server.route = { path in .init(body: Data(path.utf8), silentClose: true) }
        let transport = PersistentHTTP1Transport(label: "test")
        defer { transport.close() }

        for path in ["/a", "/b", "/c"] {
            let answer = try await transport.get(server.url(path), headers: [:], limit: 1024)
            XCTAssertEqual(String(decoding: answer.body, as: UTF8.self), path)
        }
        XCTAssertEqual(server.requests.map(\.path), ["/a", "/b", "/c"])
        XCTAssertEqual(server.connectionCount, 3)
    }

    func testChunkedBodyIsDecodedAndKeepsTheConnection() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        let body = Data((0..<5000).map { UInt8($0 & 0xFF) })
        server.route = { _ in .init(body: body, chunked: true) }
        let transport = PersistentHTTP1Transport(label: "test")
        defer { transport.close() }

        for _ in 0..<3 {
            let answer = try await transport.get(server.url("/c"), headers: [:], limit: 1 << 20)
            XCTAssertEqual(answer.body, body)
        }
        XCTAssertEqual(server.connectionCount, 1)
    }

    func testRefusalKeepsTheConnectionAndReportsItsStatus() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        server.route = { path in path == "/denied" ? .init(status: 403, body: Data("no".utf8)) : .init(body: Data("ok".utf8)) }
        let transport = PersistentHTTP1Transport(label: "test")
        defer { transport.close() }

        let refused = try await transport.get(server.url("/denied"), headers: [:], limit: 1024)
        XCTAssertEqual(refused.response.statusCode, 403)
        XCTAssertTrue(refused.body.isEmpty)
        let served = try await transport.get(server.url("/fine"), headers: [:], limit: 1024)
        XCTAssertEqual(served.body, Data("ok".utf8))
        XCTAssertEqual(server.connectionCount, 1)
    }

    func testBodyOverTheLimitIsRefused() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        server.route = { _ in .init(body: Data(count: 4096)) }
        let transport = PersistentHTTP1Transport(label: "test")
        defer { transport.close() }

        do {
            _ = try await transport.get(server.url("/big"), headers: [:], limit: 1024)
            XCTFail("a 4 KB body passed a 1 KB limit")
        } catch let error as BoundedFetch.Exceeded {
            XCTAssertEqual(error.limit, 1024)
        }
    }

    func testCrossOriginRedirectKeepsOneConnectionPerOriginAndDropsCredentials() async throws {
        let cdn = try XCTUnwrap(KeepAliveOrigin())
        defer { cdn.stop() }
        let edge = try XCTUnwrap(KeepAliveOrigin())
        defer { edge.stop() }
        cdn.route = { path in .init(body: Data(path.utf8)) }
        edge.route = { path in .init(status: 302, headers: ["Location": cdn.url(path).absoluteString]) }
        let transport = PersistentHTTP1Transport(label: "test")
        defer { transport.close() }

        for path in ["/1.ts", "/2.ts", "/3.ts"] {
            let answer = try await transport.get(
                edge.url(path), headers: ["Authorization": "secret", "X-Plain": "kept"], limit: 1024)
            XCTAssertEqual(String(decoding: answer.body, as: UTF8.self), path)
            XCTAssertEqual(answer.response.url, cdn.url(path))
        }
        XCTAssertEqual(edge.connectionCount, 1)
        XCTAssertEqual(cdn.connectionCount, 1)
        XCTAssertTrue(edge.requests.allSatisfy { $0.headers["authorization"] == "secret" })
        XCTAssertTrue(cdn.requests.allSatisfy { $0.headers["authorization"] == nil })
        XCTAssertTrue(cdn.requests.allSatisfy { $0.headers["x-plain"] == "kept" })
    }

    func testWholeResourceRequestCarriesNoRange() throws {
        let url = try XCTUnwrap(URL(string: "https://media.example/api/ts?url=a%2Fb.ts"))
        let text = String(decoding: try HeldSourceConnection.requestBytes(
            target: url, host: "media.example", port: 443, secure: true,
            offset: nil, extraHeaders: [:], userAgent: nil), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("GET /api/ts?url=a%2Fb.ts HTTP/1.1\r\nHost: media.example\r\n"))
        XCTAssertFalse(text.lowercased().contains("range:"))
        XCTAssertTrue(text.contains("Connection: keep-alive\r\n"))
    }

    // MARK: - Helpers

    static let markerOffset = 100

    private static func mediaPlaylist(_ segments: [String]) -> Data {
        var text = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n"
        for segment in segments { text += "#EXTINF:6,\n\(segment)\n" }
        return Data((text + "#EXT-X-ENDLIST").utf8)
    }

    /// Three TS packets whose PMT declares HEVC (0x24); the marker sits in the PMT packet's filler.
    private static func transportStream(marker: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0xFF, count: 188 * 3)
        for packet in 0..<3 {
            bytes[packet * 188] = 0x47
            bytes[packet * 188 + 3] = 0x10
        }
        let pmt: [UInt8] = [0x40, 0x64, 0x10, 0, 0x02, 0xB0, 18, 0, 1, 0xC1, 0, 0,
                            0xE1, 0, 0xF0, 0, 0x24, 0xE1, 1, 0xF0, 0]
        bytes.replaceSubrange(1..<(1 + pmt.count), with: pmt)
        bytes[markerOffset] = marker
        return Data(bytes)
    }

    private static func drain(_ reader: HLSVODIngestReader) -> [UInt8] {
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 4096) }
            if count <= 0 { return out }
            out += buffer[0..<Int(count)]
        }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not met in \(timeout) s") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// A loopback HTTP/1.1 origin that keeps connections alive and records which connection carried
/// each request.
final class KeepAliveOrigin: @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var chunked = false
        /// Answers with `Connection: close` and hangs up.
        var connectionClose = false
        /// Hangs up after the response without announcing it.
        var silentClose = false
        /// Sends the body one 188-byte packet per interval.
        var trickleUs: useconds_t = 0

        init(status: Int = 200, headers: [String: String] = [:], body: Data = Data(),
             chunked: Bool = false, connectionClose: Bool = false, silentClose: Bool = false,
             trickleUs: useconds_t = 0) {
            self.status = status
            self.headers = headers
            self.body = body
            self.chunked = chunked
            self.connectionClose = connectionClose
            self.silentClose = silentClose
            self.trickleUs = trickleUs
        }
    }

    struct Request {
        let connection: Int
        let path: String
        let requestLine: String
        let headers: [String: String]
    }

    private let listener: LoopbackListener
    private let lock = NSLock()
    private var _route: @Sendable (String) -> Reply = { _ in Reply(status: 404) }
    private var _requests: [Request] = []
    private var _connections = 0
    private var _fds: [Int32] = []
    private var stopped = false

    init?() {
        guard let listener = LoopbackListener() else { return nil }
        self.listener = listener
        listener.start { [self] fd in admit(fd) }
    }

    var route: @Sendable (String) -> Reply {
        get { lock.withLock { _route } }
        set { lock.withLock { _route = newValue } }
    }

    var requests: [Request] { lock.withLock { _requests } }
    var connectionCount: Int { lock.withLock { _connections } }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(listener.port)\(path)")!
    }

    func stop() {
        lock.lock()
        let already = stopped
        stopped = true
        for fd in _fds { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
        if !already { listener.stop() }
    }

    private func admit(_ fd: Int32) -> Bool {
        lock.lock()
        if stopped {
            lock.unlock()
            close(fd)
            return false
        }
        _connections += 1
        let id = _connections
        _fds.append(fd)
        lock.unlock()
        Thread.detachNewThread { [self] in serve(fd, id: id) }
        return true
    }

    private func serve(_ fd: Int32, id: Int) {
        defer {
            lock.lock()
            _fds.removeAll { $0 == fd }
            close(fd)
            lock.unlock()
        }
        var leftover = Data()
        while true {
            guard let (head, rest) = readHead(fd, leftover: leftover) else { return }
            leftover = rest
            let lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.first ?? ""
            let parts = requestLine.components(separatedBy: " ")
            let path = parts.count >= 2 ? parts[1] : "?"
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
            let route: @Sendable (String) -> Reply = lock.withLock {
                _requests.append(Request(connection: id, path: path, requestLine: requestLine, headers: headers))
                return _route
            }
            let reply = route(path)
            if !respond(fd, reply) || reply.connectionClose || reply.silentClose { return }
        }
    }

    private func respond(_ fd: Int32, _ reply: Reply) -> Bool {
        var head = "HTTP/1.1 \(reply.status) X\r\n"
        for (name, value) in reply.headers { head += "\(name): \(value)\r\n" }
        if reply.chunked {
            head += "Transfer-Encoding: chunked\r\n"
        } else {
            head += "Content-Length: \(reply.body.count)\r\n"
        }
        if reply.connectionClose { head += "Connection: close\r\n" }
        head += "\r\n"
        guard send(fd, Data(head.utf8)) else { return false }
        if reply.chunked {
            var offset = 0
            while offset < reply.body.count {
                let piece = reply.body[offset..<min(reply.body.count, offset + 1000)]
                guard send(fd, Data((String(piece.count, radix: 16) + "\r\n").utf8) + piece + Data("\r\n".utf8))
                else { return false }
                offset += piece.count
            }
            return send(fd, Data("0\r\n\r\n".utf8))
        }
        guard reply.trickleUs > 0 else { return send(fd, reply.body) }
        var offset = 0
        while offset < reply.body.count {
            let end = min(reply.body.count, offset + 188)
            guard send(fd, reply.body[offset..<end]) else { return false }
            offset = end
            usleep(reply.trickleUs)
        }
        return true
    }

    private func readHead(_ fd: Int32, leftover: Data) -> (String, Data)? {
        var collected = leftover
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let terminator = Data("\r\n\r\n".utf8)
        while collected.range(of: terminator) == nil {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { return nil }
            collected.append(contentsOf: buffer[0..<n])
        }
        let split = collected.range(of: terminator)!
        return (String(decoding: collected[..<split.lowerBound], as: UTF8.self),
                Data(collected[split.upperBound...]))
    }

    private func send(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                guard n > 0 else { return false }
                sent += n
            }
            return true
        }
    }
}
