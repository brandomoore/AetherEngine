import Testing
import Foundation
@testable import AetherEngine

/// The listener binds 0.0.0.0 so an AirPlay receiver can reach it over the LAN (#86). That also
/// exposes it to every other host on that network, and the endpoint names are fixed, so the
/// ephemeral port was the only thing standing between a port scan and the stream. These pin the
/// per-session path token that replaced that assumption.
struct HLSLocalServerSessionTokenTests {

    // MARK: - Path check

    @Test("The token is stripped and the remainder routes")
    func tokenIsStripped() {
        #expect(HLSLocalServer.pathAfterToken("abc123", in: "/abc123/media.m3u8") == "/media.m3u8")
        #expect(HLSLocalServer.pathAfterToken("abc123", in: "/abc123/seg7.mp4") == "/seg7.mp4")
    }

    @Test("A request without the token is refused")
    func unprefixedIsRefused() {
        #expect(HLSLocalServer.pathAfterToken("abc123", in: "/media.m3u8") == nil)
        #expect(HLSLocalServer.pathAfterToken("abc123", in: "/") == nil)
        #expect(HLSLocalServer.pathAfterToken("abc123", in: "") == nil)
    }

    @Test("A wrong token is refused")
    func wrongTokenIsRefused() {
        #expect(HLSLocalServer.pathAfterToken("abc123", in: "/def456/media.m3u8") == nil)
    }

    @Test("A token that only prefixes the first segment is refused, not truncated")
    func partialSegmentMatchIsRefused() {
        // "/abc123extra/..." starts with "/abc123" as a STRING but is a different path segment.
        // Comparing on the string alone would let it through with a mangled remainder.
        #expect(HLSLocalServer.pathAfterToken("abc123", in: "/abc123extra/media.m3u8") == nil)
    }

    @Test("The bare token with nothing after it is refused")
    func bareTokenIsRefused() {
        #expect(HLSLocalServer.pathAfterToken("abc123", in: "/abc123") == nil)
    }

    // MARK: - Token shape

    @Test("Each server draws its own 128-bit token")
    func tokensAreDistinctAndFullWidth() {
        let a = HLSLocalServer(provider: StubProvider())
        let b = HLSLocalServer(provider: StubProvider())
        #expect(a.pathToken.count == 32)
        #expect(a.pathToken.allSatisfy { $0.isHexDigit })
        #expect(a.pathToken != b.pathToken)
    }

    // MARK: - Over a real socket

    @Test("The served URL carries the token and an unprefixed request 404s")
    func unprefixedRequestIsRefusedOverTheSocket() throws {
        let server = HLSLocalServer(provider: StubProvider())
        try server.start()
        defer { server.stop() }

        let served = try #require(server.mediaPlaylistURL)
        #expect(served.path == "/\(server.pathToken)/media.m3u8")

        #expect(Self.status(port: server.port, path: "/\(server.pathToken)/media.m3u8") == 200)
        // The shape a LAN scanner would try: right port, right endpoint name, no token.
        #expect(Self.status(port: server.port, path: "/media.m3u8") == 404)
        #expect(Self.status(port: server.port, path: "/init.mp4") == 404)
        #expect(Self.status(port: server.port, path: "/seg0.mp4") == 404)
    }

    // MARK: - The token in the log (audit SUB-107)

    @Test("A running server's token is redacted from every log line, and released on stop")
    func tokenIsRedactedWhileTheServerRuns() throws {
        let server = HLSLocalServer(provider: StubProvider())
        try server.start()
        let token = server.pathToken
        let line = "[NativeAVPlayerHost] #2 load url=http://127.0.0.1:\(server.port)/\(token)/master.m3u8"
        #expect(LogRedaction.isRegistered(token))
        #expect(!LogRedaction.redact(line).contains(token))
        #expect(LogRedaction.redact("[HLSLocalServer] GET /\(token)/seg_1.m4s HTTP/1.1")
                == "[HLSLocalServer] GET /<redacted>/seg_1.m4s HTTP/1.1")

        server.stop()
        #expect(!LogRedaction.isRegistered(token))
        server.stop()
        #expect(!LogRedaction.isRegistered(token))
    }

    @Test("Stopping one server leaves the other's token redacted")
    func twoServersKeepTheirOwnRegistration() throws {
        let first = HLSLocalServer(provider: StubProvider())
        let second = HLSLocalServer(provider: StubProvider())
        try first.start()
        try second.start()
        defer { second.stop() }

        first.stop()
        #expect(!LogRedaction.isRegistered(first.pathToken))
        #expect(LogRedaction.isRegistered(second.pathToken))
    }

    @Test("The logged request line names the route, not the token")
    func requestLineOmitsTheToken() {
        #expect(HLSLocalServer.requestLineForLog(
            method: "GET", routePath: "/seg_1.m4s", query: "", version: "HTTP/1.1")
                == "GET /seg_1.m4s HTTP/1.1")
        #expect(HLSLocalServer.requestLineForLog(
            method: "GET", routePath: "/media.m3u8", query: "_HLS_msn=12", version: "HTTP/1.1")
                == "GET /media.m3u8?_HLS_msn=12 HTTP/1.1")
    }

    // MARK: - Credential headers in the log (audit Vcred-102)

    /// On the #316 / AE#495 stand-in route AVPlayer carries the host's own headers to this server, so
    /// the once-per-session header dump printed whatever credential the host passed.
    @Test("The first-request header dump names a credential header but never prints its value")
    func headerDumpOmitsCredentialValues() throws {
        let tap = EngineLogCapture()
        defer { tap.end() }
        let server = HLSLocalServer(provider: StubProvider())
        try server.start()
        defer { server.stop() }
        let marker = "X-Probe-\(UUID().uuidString.prefix(8))"

        let status = Self.status(
            port: server.port, path: "/\(server.pathToken)/media.m3u8",
            extraHeaders: [#"Authorization: Digest username="bob", response="6629fae49393a05397450978507c4ef1""#,
                           "X-Portal-Auth: SECRETportal123", "\(marker): 1", "Range: bytes=0-1"])
        #expect(status == 200)

        // Header names no redactor rule knows, which is the point: the dump must not depend on one.
        let dumped = tap.lines.filter { $0.contains("first request headers") && $0.contains(marker) }
        #expect(dumped.count == 1)
        for line in dumped {
            #expect(!line.contains("6629fae49393a05397450978507c4ef1"), "\(line)")
            #expect(!line.contains("SECRETportal123"), "\(line)")
            #expect(line.contains("Authorization"))
            #expect(line.contains("X-Portal-Auth"))
            #expect(line.contains("Range: bytes=0-1"))
        }
    }

    @Test("Only the capability headers keep their values in the dump")
    func headerDumpFormat() {
        let dumped = HLSLocalServer.requestHeadersForLog([
            "Host: 127.0.0.1:50123", "Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123",
            "Cookie: session=SECRETsess123", "Range: bytes=0-1", "X-Playback-Session-Id: 5A0C",
            "Accept: */*", "User-Agent: AppleCoreMedia/1.0", "garbage",
        ])
        #expect(dumped == "Host: 127.0.0.1:50123 | Authorization | Cookie | Range: bytes=0-1 | "
                + "X-Playback-Session-Id: 5A0C | Accept: */* | User-Agent: AppleCoreMedia/1.0 | ?")
    }

    // MARK: - Helpers

    /// Status line of a plain GET, or 0 when the request could not be completed. A 0 is never the
    /// answer under test, and a loaded CI runner has dropped one exchange mid-suite while the
    /// requests around it on the same server were answered, so it is retried before it counts.
    private static func status(port: UInt16, path: String, extraHeaders: [String] = []) -> Int {
        for attempt in 0..<3 {
            if attempt > 0 { usleep(100_000) }
            let code = singleStatus(port: port, path: path, extraHeaders: extraHeaders)
            if code != 0 { return code }
        }
        return 0
    }

    private static func singleStatus(port: UInt16, path: String, extraHeaders: [String]) -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return 0 }
        let extra = extraHeaders.map { "\($0)\r\n" }.joined()
        let request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\(extra)Connection: close\r\n\r\n"
        let sent = Array(request.utf8).withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent > 0 else { return 0 }
        var buffer = [UInt8](repeating: 0, count: 256)
        let received = recv(fd, &buffer, buffer.count, 0)
        guard received > 0,
              let line = String(bytes: buffer[0..<received], encoding: .utf8)?
                  .components(separatedBy: "\r\n").first else { return 0 }
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? (Int(parts[1]) ?? 0) : 0
    }
}

/// Smallest provider that lets the server build and serve a media playlist.
private final class StubProvider: HLSSegmentProvider, @unchecked Sendable {
    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { 1 }
    func segmentDuration(at index: Int) -> Double { 4.0 }
    var playlistType: HLSPlaylistType { .vod }
}
