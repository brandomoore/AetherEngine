import Darwin
import Foundation

/// A loopback origin that serves a table of binary files with `Range` support (206 with
/// `Content-Range`, the `bytes=a-b`, `bytes=a-` and `bytes=-n` forms) and records every request with
/// its headers (names lowercased). One request per connection. `ignoresRange` answers every request
/// with the whole file at 200, the origin a SegmentBase source cannot be read from.
final class RangeFilesOrigin: @unchecked Sendable {
    struct File: Sendable {
        var data: Data
        var contentType: String
    }

    struct Request: Sendable {
        let path: String
        let range: String?
        let headers: [String: String]
    }

    let port: UInt16
    private let listener: LoopbackListener
    private let lock = NSLock()
    private var _files: [String: File] = [:]
    private var _requests: [Request] = []
    private var _connections: Set<Int32> = []
    private var _stopped = false
    private var _ignoresRange = false
    private var _stalled: Set<String> = []

    init?() {
        guard let listener = LoopbackListener(backlog: 32) else { return nil }
        self.listener = listener
        port = listener.port
        listener.start { [self] fd in admit(fd) }
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    func serve(_ path: String, _ data: Data, contentType: String = "application/octet-stream") {
        lock.withLock { _files[path] = File(data: data, contentType: contentType) }
    }

    var ignoresRange: Bool {
        get { lock.withLock { _ignoresRange } }
        set { lock.withLock { _ignoresRange = newValue } }
    }

    /// Requests to these paths are read and never answered, until `stop()`.
    func stall(_ path: String) {
        lock.withLock { _ = _stalled.insert(path) }
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
        listener.stop()
    }

    private func admit(_ fd: Int32) -> Bool {
        lock.lock()
        if _stopped {
            lock.unlock()
            close(fd)
            return false
        }
        _connections.insert(fd)
        lock.unlock()
        Thread.detachNewThread { [self] in handle(fd) }
        return true
    }

    private func handle(_ fd: Int32) {
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
        let parts = lines.first?.split(separator: " ") ?? []
        let method = parts.first.map(String.init) ?? "GET"
        let target = parts.dropFirst().first.map(String.init) ?? "/"
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "/")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let (file, ignoresRange, stalled) = lock.withLock { () -> (File?, Bool, Bool) in
            _requests.append(Request(path: path, range: headers["range"], headers: headers))
            return (_files[path], _ignoresRange, _stalled.contains(path))
        }
        if stalled {
            while recv(fd, &chunk, chunk.count, 0) > 0 {}
            return
        }
        guard let file else {
            send(fd, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        let size = file.data.count
        var start = 0
        var end = size - 1
        var partial = false
        if !ignoresRange, let range = headers["range"], range.hasPrefix("bytes="), size > 0 {
            let spec = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            if spec.count == 2 {
                if spec[0].isEmpty, let suffix = Int(spec[1]) {
                    start = max(0, size - suffix)
                } else if let a = Int(spec[0]) {
                    start = a
                    if let b = Int(spec[1]) { end = min(end, b) }
                }
                partial = start <= end && start < size
                if !partial { start = 0; end = size - 1 }
            }
        }
        let body = size == 0 ? Data() : file.data.subdata(in: start..<(end + 1))
        var head = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: \(file.contentType)\r\nContent-Length: \(body.count)\r\n"
        if partial { head += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        head += "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        send(fd, Data(head.utf8) + (method == "HEAD" ? Data() : body))
    }

    private func send(_ fd: Int32, _ data: Data) {
        let bytes = [UInt8](data)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { return }
            sent += n
        }
    }
}
