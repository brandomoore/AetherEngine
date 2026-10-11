// A relayed fetch whose consumer stopped reading must cost the session nothing but its own
// memory, bounded. Everything here drives a real origin subprocess, which exists on macOS only.
#if os(macOS)

import Foundation
import Testing

@testable import AetherEngine

/// Audit NET-107: the pump used to park the session's serial delegate queue inside `didReceive`
/// once a fetch held 4 MB its consumer had not taken, so one receiver that stopped reading held up
/// the head and the body of every other relayed fetch for as long as the stall lasted.
@Suite("HLS origin relay with a consumer that stops reading", .timeLimit(.minutes(3)))
struct HLSOriginRelayStalledConsumerTests {

    /// A fixed-length body written as fast as the socket takes it, with a marker file once the last
    /// byte has gone out. The marker is what says the relay kept reading the origin while its own
    /// consumer did not.
    private final class FastBodyOrigin {
        let port: UInt16
        private let process: Process
        private let workDir: URL

        var finishedSending: Bool {
            FileManager.default.fileExists(atPath: workDir.appendingPathComponent("done").path)
        }

        init?(megabytes: Int) async {
            guard let launched = await PythonOrigin.launch(
                prefix: "aether-fast-body-origin", script: Self.serverPy(bytes: megabytes << 20))
            else { return nil }
            process = launched.process
            port = launched.port
            workDir = launched.workDir
        }

        func stop() {
            process.terminate()
            try? FileManager.default.removeItem(at: workDir)
        }

        private static func serverPy(bytes: Int) -> String {
            """
            import http.server

            TOTAL = \(bytes)
            CHUNK = 65536

            class Handler(http.server.BaseHTTPRequestHandler):
                protocol_version = "HTTP/1.1"

                def log_message(self, *args):
                    pass

                def do_GET(self):
                    self.send_response(200)
                    self.send_header("Content-Length", str(TOTAL))
                    self.send_header("Content-Type", "video/mp2t")
                    self.end_headers()
                    sent = 0
                    try:
                        while sent < TOTAL:
                            n = min(CHUNK, TOTAL - sent)
                            self.wfile.write(b"\\x47" * n)
                            sent += n
                        self.wfile.flush()
                        open("done", "w").close()
                    except OSError:
                        return

            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            print("READY", server.server_address[1], flush=True)
            server.serve_forever()
            """
        }
    }

    /// A client that sends its request on a raw socket with a tiny receive buffer and then never
    /// reads, which is what a receiver on a link slower than the stream looks like to the server.
    private final class StalledReader {
        private var fd: Int32

        init?(url: URL) {
            guard let host = url.host, let port = url.port else { return nil }
            fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var small: Int32 = 4096
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout<Int32>.size))

            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { Darwin.close(fd); return nil }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { Darwin.close(fd); return nil }

            let target = url.path + (url.query.map { "?\($0)" } ?? "")
            let wire = Array("GET \(target) HTTP/1.1\r\nHost: \(host):\(port)\r\n\r\n".utf8)
            let sent = wire.withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count, 0) }
            guard sent == wire.count else { Darwin.close(fd); return nil }
        }

        func close() {
            guard fd >= 0 else { return }
            Darwin.close(fd)
            fd = -1
        }
    }

    private func entry(_ server: HLSLocalServer, port: UInt16, path: String) throws -> URL {
        try #require(server.relayURL(for: URL(string: "http://127.0.0.1:\(port)\(path)")!))
    }

    @Test("A player that stops reading one segment does not hold up another relayed fetch")
    func stalledConsumerDoesNotBlockOtherFetches() async throws {
        let big = try #require(await FastBodyOrigin(megabytes: 16))
        let quick = try #require(await TricklingOrigin(slices: 2, pauseSeconds: 0))
        defer { big.stop(); quick.stop() }
        let relay = HLSOriginRelay()
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { server.stop(); relay.stop() }

        let stalled = try #require(StalledReader(url: try entry(server, port: big.port, path: "/big.ts")))
        defer { stalled.close() }

        // The relay keeps taking the body off the origin while nobody reads it downstream. Parked at
        // 4 MB it never does, and the origin's last write never completes.
        try await waitFor { big.finishedSending }

        var request = URLRequest(url: try entry(server, port: quick.port, path: "/quick.ts"))
        request.timeoutInterval = 150
        let (body, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(body.count == TricklingOrigin.totalBytes(slices: 2))
        #expect(relay.cappedFetchCount == 0, "16 MB is under the 32 MiB cap")
    }

    @Test("A consumer that falls past the cap is cut off and the fetch is cancelled, not parked")
    func consumerPastTheCapIsCutOff() async throws {
        let big = try #require(await FastBodyOrigin(megabytes: 16))
        let quick = try #require(await TricklingOrigin(slices: 2, pauseSeconds: 0))
        defer { big.stop(); quick.stop() }
        let relay = HLSOriginRelay(maximumPendingBytes: 1 << 20)
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { server.stop(); relay.stop() }

        let stalled = try #require(StalledReader(url: try entry(server, port: big.port, path: "/big.ts")))
        defer { stalled.close() }

        try await waitFor { relay.cappedFetchCount == 1 }

        var request = URLRequest(url: try entry(server, port: quick.port, path: "/quick.ts"))
        request.timeoutInterval = 150
        let (body, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(body.count == TricklingOrigin.totalBytes(slices: 2))
        #expect(relay.cappedFetchCount == 1)
    }

    @Test("A body that fits under the cap arrives whole however late its consumer starts")
    func bodyUnderTheCapArrivesWhole() async throws {
        // Four megabytes against an eight megabyte cap: even if the consumer took nothing until the
        // origin had finished, the fetch holds at most what the origin sent, so no timing decides this.
        let origin = try #require(await TricklingOrigin(slices: 64, pauseSeconds: 0))
        defer { origin.stop() }
        let relay = HLSOriginRelay(maximumPendingBytes: 8 << 20)
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { server.stop(); relay.stop() }

        var request = URLRequest(url: try entry(server, port: origin.port, path: "/seg.ts"))
        request.timeoutInterval = 150
        let (body, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(body.count == TricklingOrigin.totalBytes(slices: 64))
        #expect(relay.cappedFetchCount == 0)
    }
}

#endif
