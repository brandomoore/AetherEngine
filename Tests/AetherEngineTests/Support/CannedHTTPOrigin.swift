import Darwin
import Foundation

/// A loopback origin that answers each path from a table and records the headers every request
/// arrived with (names lowercased), so a credential that must not reach a host is checked where it
/// would have landed. One request per connection; the table can be filled after start, so two of
/// these can point at each other.
final class CannedHTTPOrigin: @unchecked Sendable {
    enum Answer: Sendable {
        case body(String, contentType: String)
        case redirect(to: String)
        case status(Int)
    }

    struct Request: Sendable {
        let path: String
        let headers: [String: String]
    }

    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var _routes: [String: Answer] = [:]
    private var _requests: [Request] = []
    private var _connections: Set<Int32> = []
    private var _stopped = false

    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else {
            close(fd)
            return nil
        }
        listenFD = fd
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    func route(_ path: String, _ answer: Answer) {
        lock.withLock { _routes[path] = answer }
    }

    var requests: [Request] { lock.withLock { _requests } }

    func requests(to path: String) -> [Request] { requests.filter { $0.path == path } }

    func stop() {
        lock.lock()
        let alreadyStopped = _stopped
        _stopped = true
        for fd in _connections { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
        guard !alreadyStopped else { return }
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            if _stopped {
                lock.unlock()
                close(fd)
                return
            }
            _connections.insert(fd)
            lock.unlock()
            Thread.detachNewThread { [self] in serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        defer {
            lock.lock()
            _connections.remove(fd)
            close(fd)
            lock.unlock()
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0, buffer.count < 65_536 else { return }
            buffer.append(chunk, count: n)
        }
        let lines = String(decoding: buffer, as: UTF8.self).components(separatedBy: "\r\n")
        let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "/")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let answer = lock.withLock { () -> Answer? in
            _requests.append(Request(path: path, headers: headers))
            return _routes[path]
        }
        let response: String
        switch answer {
        case .body(let body, let contentType):
            response = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        case .redirect(let location):
            response = "HTTP/1.1 302 Found\r\nLocation: \(location)\r\n"
                + "Content-Length: 0\r\nConnection: close\r\n\r\n"
        case .status(let code):
            response = "HTTP/1.1 \(code) Status\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        case nil:
            response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        }
        let bytes = Array(response.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { return }
            sent += n
        }
    }
}
