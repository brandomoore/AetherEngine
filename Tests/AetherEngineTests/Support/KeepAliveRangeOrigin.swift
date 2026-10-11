import Darwin
import Foundation

/// A loopback origin that serves one byte blob with Range support over keep-alive connections and
/// counts the connections that are still open. A client that leaves its `URLSession` uninvalidated
/// leaves its pooled socket here, which is the only place that leak is visible from outside: the
/// session has no public liveness and the origin is the one party that sees the socket.
final class KeepAliveRangeOrigin: @unchecked Sendable {
    let port: UInt16
    private let listener: LoopbackListener
    private let data: Data
    private let lock = NSLock()
    private var connections: Set<Int32> = []
    private var stopped = false
    private var accepted = 0

    init?(data: Data) {
        self.data = data
        guard let listener = LoopbackListener(backlog: 16) else { return nil }
        self.listener = listener
        port = listener.port
        listener.start { [self] fd in admit(fd) }
    }

    var openConnectionCount: Int { lock.withLock { connections.count } }
    var acceptedConnectionCount: Int { lock.withLock { accepted } }

    func stop() {
        lock.lock()
        let already = stopped
        stopped = true
        for fd in connections { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
        guard !already else { return }
        listener.stop()
    }

    private func admit(_ fd: Int32) -> Bool {
        lock.lock()
        if stopped {
            lock.unlock()
            shutdown(fd, SHUT_RDWR)
            close(fd)
            return false
        }
        connections.insert(fd)
        accepted += 1
        lock.unlock()
        Thread.detachNewThread { [self] in serve(fd) }
        return true
    }

    private func serve(_ fd: Int32) {
        defer {
            lock.lock()
            connections.remove(fd)
            close(fd)
            lock.unlock()
        }
        while let head = readRequestHead(fd) {
            var start = 0
            var end = data.count - 1
            if let range = Self.range(in: head) {
                start = range.start
                end = min(end, range.end ?? end)
            }
            guard start < data.count, end >= start else {
                guard writeAll(fd, Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\n\r\n".utf8))
                else { return }
                continue
            }
            let header = "HTTP/1.1 206 Partial Content\r\n"
                + "Content-Length: \(end - start + 1)\r\n"
                + "Content-Range: bytes \(start)-\(end)/\(data.count)\r\n"
                + "Accept-Ranges: bytes\r\nConnection: keep-alive\r\n\r\n"
            guard writeAll(fd, Data(header.utf8)),
                  writeAll(fd, data.subdata(in: start..<(end + 1))) else { return }
        }
    }

    private static func range(in head: String) -> (start: Int, end: Int?)? {
        guard let line = head.components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("range:") }),
              let equals = line.range(of: "bytes=") else { return nil }
        let parts = line[equals.upperBound...].split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (start, Int(parts[1].trimmingCharacters(in: .whitespaces)))
    }

    private func readRequestHead(_ fd: Int32) -> String? {
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let terminator = Data("\r\n\r\n".utf8)
        while collected.range(of: terminator) == nil {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            collected.append(contentsOf: buffer.prefix(count))
            guard collected.count <= 64 * 1024 else { return nil }
        }
        return String(decoding: collected, as: UTF8.self)
    }

    private func writeAll(_ fd: Int32, _ bytes: Data) -> Bool {
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let count = write(fd, base.advanced(by: sent), raw.count - sent)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }
}
