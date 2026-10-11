import Testing
import Foundation
@testable import AetherEngine

/// A source that is lost mid-read reports a read error, never end-of-file: the consumer treats EOF
/// as "played to the end" and never retries it (audit DMX-6, DMX-10).
@Suite("Lost source reads report EIO")
struct LostSourceReadErrorTests {

    /// Answers every request with a length-less 200 and every GET with `bodyBytes` of a body that
    /// never completes. The reader can resolve no size and runs the forward-only streaming path.
    private final class LengthlessResettingOrigin: @unchecked Sendable {
        let port: UInt16
        private let listenFD: Int32
        private let bodyBytes: Int
        private let lock = NSLock()
        private var stopped = false
        private var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        init?(bodyBytes: Int) {
            self.bodyBytes = bodyBytes
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(fd, 16) == 0 else { Darwin.close(fd); return nil }
            var name = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &name) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
            }
            listenFD = fd
            port = UInt16(bigEndian: name.sin_port)
            Thread.detachNewThread { [self] in acceptLoop() }
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
            shutdown(listenFD, SHUT_RDWR)
            Darwin.close(listenFD)
        }

        private func acceptLoop() {
            while true {
                let fd = accept(listenFD, nil, nil)
                guard fd >= 0 else { return }
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread { [self] in serve(fd) }
            }
        }

        private func serve(_ fd: Int32) {
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            var request = Data()
            while request.range(of: Data("\r\n\r\n".utf8)) == nil {
                let n = recv(fd, &buf, buf.count, 0)
                guard n > 0 else { Darwin.close(fd); return }
                request.append(contentsOf: buf[0..<n])
            }
            let isHead = request.starts(with: Data("HEAD".utf8))
            // Chunked with no Content-Length, so no probe can size the source. The body promises
            // one chunk of twice `bodyBytes` and stops half way with a FIN: a truncated chunked
            // body is a transport error, where a length-less FIN would be a clean end.
            let header = Array(("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\n"
                + "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
                + (isHead ? "" : String(2 * bodyBytes, radix: 16) + "\r\n")).utf8)
            _ = header.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            if !isHead {
                let chunk = [UInt8](repeating: 0x47, count: 16 * 1024)
                var sent = 0
                while sent < bodyBytes {
                    let n = chunk.withUnsafeBytes { send(fd, $0.baseAddress, min($0.count, bodyBytes - sent), 0) }
                    guard n > 0 else { break }
                    sent += n
                }
            }
            // Half-close, as `ThrottledOriginServer.serveThenDrop` does: a full close can turn into
            // an RST that discards bytes the reader has not been handed yet.
            shutdown(fd, SHUT_WR)
            while !isStopped { usleep(50_000) }
            Darwin.close(fd)
        }
    }

    private func drain(_ reader: AVIOReader) -> Int32 {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { buf.deallocate() }
        while true {
            let n = reader.read(into: buf, size: 64 * 1024)
            if n <= 0 { return n }
        }
    }

    @Test("a length-less stream cut off mid-body reports EIO, not EOF", .timeLimit(.minutes(1)))
    func cutOffLengthlessStreamIsAnError() throws {
        let origin = try #require(LengthlessResettingOrigin(bodyBytes: 256 * 1024))
        defer { origin.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(origin.port)/live.ts")!,
                                prefetchEnabled: false)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        #expect(drain(reader) == FFmpegErr.eio)
    }

    @Test("a seekable read whose fetch fails reports EIO, not EOF", .timeLimit(.minutes(1)))
    func failedSeekableFetchIsAnError() throws {
        let target: Int64 = 8 * 1024 * 1024
        let respond: @Sendable (Int, Int64, String) -> ThrottledOriginServer.Directive = { _, offset, _ in
            offset == target ? .status(500) : .serve206
        }
        let origin = ThrottledOriginServer(totalSize: 32 * 1024 * 1024, throttleUs: 0, respond: respond)
        let server = try #require(origin)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                chunkSize: 256 * 1024, prefetchEnabled: false)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        #expect(reader.seek(offset: target, whence: SEEK_SET) == target)
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        #expect(reader.read(into: buf, size: 4096) == FFmpegErr.eio)
    }
}
