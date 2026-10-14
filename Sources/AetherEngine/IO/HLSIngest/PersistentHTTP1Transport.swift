import Foundation

/// AE#732: the HLS VOD ingest's transport under `LoadOptions.heldSourceConnection`.
///
/// Some origins answer an HLS segment reliably only over one persistent HTTP/1.1 connection: h2 and
/// freshly opened HTTP/1.1 connections are refused (403) while consecutive requests on one keep-alive
/// connection are served. Forcing the protocol per request is therefore not enough, the connection has
/// to outlive the segment, which is what this pool is for. It is the HLS sibling of
/// `HeldSourceConnection` (#377) and shares its wire format: HTTP/1.1 written by the engine over a
/// `URLSessionStreamTask`, TLS through `EngineTLS`, no ALPN and so never h2, no system proxy.
///
/// Requests run one after another over the idle connection of their origin (scheme, host, port). A
/// connection goes back to the pool only after a complete response it can be reused for: HTTP/1.1,
/// no `Connection: close`, and a body with a known end. Everything else, an error, a cancellation
/// mid-body or a body cut off at its limit, closes it, and the next request opens a fresh one.
/// Concurrent callers each get their own connection; the ingest issues one request at a time on this
/// path, so that only happens for the moment a seek takes to retire the previous producer.
final class PersistentHTTP1Transport: @unchecked Sendable {
    static let maxRedirects = 3
    /// Idle connections kept, one per origin. A segment redirected to a CDN host keeps both the
    /// playlist origin and the CDN connection warm.
    private static let maxIdleOrigins = 2

    struct Response {
        let body: Data
        let response: HTTPURLResponse
    }

    private let label: String
    private let lock = NSLock()
    private var idle: [Origin: PersistentHTTP1Connection] = [:]
    private var closed = false
    private var nextConnectionID = 0

    init(label: String) {
        self.label = label
    }

    /// GET `url` with `headers`, redirects followed under the #126 header policy. A non-2xx answer
    /// comes back with its status and whatever body it had, read to its end so the connection stays
    /// usable. Throws `BoundedFetch.Exceeded` for a 2xx body over `limit`.
    func get(_ url: URL, headers: [String: String], limit: Int) async throws -> Response {
        var target = url
        var hops = 0
        while true {
            let hopHeaders = RedirectHeaderPolicy.headersToReplay(
                extraHeaders: headers, originalURL: url, redirectURL: target)
            let (head, body) = try await exchange(target, headers: hopHeaders, limit: limit)
            if let location = HeldSourceConnection.redirectLocation(head) {
                guard hops < Self.maxRedirects else {
                    throw PersistentHTTP1Connection.ConnectionError.tooManyRedirects
                }
                guard let next = URL(string: location, relativeTo: target)?.absoluteURL else {
                    throw PersistentHTTP1Connection.ConnectionError.malformed("unresolvable Location: \(location)")
                }
                hops += 1
                target = next
                continue
            }
            guard let response = HeldSourceConnection.makeResponse(head, url: target) else {
                throw PersistentHTTP1Connection.ConnectionError.malformed("status \(head.status)")
            }
            return Response(body: body, response: response)
        }
    }

    /// Closes every idle connection and refuses further requests.
    func close() {
        lock.lock()
        closed = true
        let connections = Array(idle.values)
        idle.removeAll()
        lock.unlock()
        for connection in connections { connection.retire(reason: "transport closed") }
    }

    /// One request and its response on a pooled connection. A REUSED connection that fails before a
    /// response head is retried once on a fresh one: an origin may close an idle keep-alive connection
    /// at any time, and the request on it never reached anyone (RFC 9112 9.3.1).
    private func exchange(
        _ target: URL, headers: [String: String], limit: Int
    ) async throws -> (HeldSourceConnection.ResponseHead, Data) {
        guard let origin = Origin(target) else {
            throw PersistentHTTP1Connection.ConnectionError.unsupportedURL(target)
        }
        var connection = try checkOut(origin)
        do {
            return try await run(connection, target: target, headers: headers, limit: limit)
        } catch PersistentHTTP1Connection.ConnectionError.staleKeepAlive where connection.requestCount > 1 {
            try Task.checkCancellation()
            connection = try openFresh(origin)
            return try await run(connection, target: target, headers: headers, limit: limit)
        }
    }

    private func run(
        _ connection: PersistentHTTP1Connection,
        target: URL, headers: [String: String], limit: Int
    ) async throws -> (HeldSourceConnection.ResponseHead, Data) {
        let outcome: PersistentHTTP1Connection.Outcome
        do {
            outcome = try await connection.send(target: target, headers: headers, limit: limit)
        } catch {
            connection.retire(reason: Task.isCancelled ? "cancelled" : EngineLog.summary(of: error))
            throw error
        }
        if let reason = outcome.notReusableBecause {
            connection.retire(reason: reason)
        } else {
            checkIn(connection)
        }
        return (outcome.head, outcome.body)
    }

    private func checkOut(_ origin: Origin) throws -> PersistentHTTP1Connection {
        lock.lock()
        if closed {
            lock.unlock()
            throw CancellationError()
        }
        if let pooled = idle.removeValue(forKey: origin) {
            lock.unlock()
            return pooled
        }
        lock.unlock()
        return try openFresh(origin)
    }

    private func openFresh(_ origin: Origin) throws -> PersistentHTTP1Connection {
        lock.lock()
        if closed {
            lock.unlock()
            throw CancellationError()
        }
        nextConnectionID += 1
        let id = nextConnectionID
        lock.unlock()
        return PersistentHTTP1Connection(origin: origin, label: "\(label)#\(id)")
    }

    private func checkIn(_ connection: PersistentHTTP1Connection) {
        lock.lock()
        if closed {
            lock.unlock()
            connection.retire(reason: "transport closed")
            return
        }
        var evicted: [PersistentHTTP1Connection] = []
        if let previous = idle[connection.origin] { evicted.append(previous) }
        idle[connection.origin] = connection
        if idle.count > Self.maxIdleOrigins,
           let oldest = idle.filter({ $0.key != connection.origin })
            .min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            idle.removeValue(forKey: oldest.key)
            evicted.append(oldest.value)
        }
        lock.unlock()
        for stale in evicted { stale.retire(reason: "origin change") }
    }

    struct Origin: Hashable, CustomStringConvertible {
        let secure: Bool
        let host: String
        let port: Int

        init?(_ url: URL) {
            guard let host = url.host?.lowercased(), !host.isEmpty,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            secure = scheme == "https"
            self.host = host
            port = url.port ?? (secure ? 443 : 80)
        }

        var description: String { "\(secure ? "https" : "http")://\(host):\(port)" }
    }
}

/// One HTTP/1.1 keep-alive connection: request, response head, body, and the next request on the
/// same socket. Not safe for concurrent requests; the pool hands it to one caller at a time.
final class PersistentHTTP1Connection: @unchecked Sendable {
    private static let readTimeout: TimeInterval = 30
    private static let writeTimeout: TimeInterval = 20
    /// Wall-clock ceiling of one exchange, the same as the ingest session's resource timeout.
    private static let exchangeDeadline: TimeInterval = 45
    private static let maxHeadBytes = 128 * 1024
    private static let maxReadBytes = 1 * 1024 * 1024
    /// A refused or redirecting answer is read to its end so the connection survives it; one with a
    /// larger body than this is not worth the bytes, and closes the connection instead.
    private static let maxDiscardedBodyBytes = 64 * 1024

    enum ConnectionError: LocalizedError {
        case malformed(String)
        case tooManyRedirects
        case unsupportedURL(URL)
        /// The origin closed a reused connection before answering; the request is safe to repeat.
        case staleKeepAlive
        case deadlineExceeded

        var errorDescription: String? {
            switch self {
            case .malformed(let detail): return "malformed HTTP response: \(detail)"
            case .tooManyRedirects: return "too many redirects"
            case .unsupportedURL(let url): return "unsupported URL for a persistent connection: \(url)"
            case .staleKeepAlive: return "keep-alive connection closed by the origin"
            case .deadlineExceeded: return "response not complete within \(Int(PersistentHTTP1Connection.exchangeDeadline)) s"
            }
        }
    }

    struct Outcome {
        let head: HeldSourceConnection.ResponseHead
        let body: Data
        /// nil when the connection may carry the next request.
        let notReusableBecause: String?
    }

    private enum Framing {
        case identity(remaining: Int64)
        case chunked(ChunkedBodyDecoder)
        case untilClose
        case empty
    }

    let origin: PersistentHTTP1Transport.Origin
    private let label: String
    private let stateLock = NSLock()
    private var session: URLSession?
    private var task: URLSessionStreamTask?
    private var retired = false
    private var pending = Data()
    private var _requestCount = 0
    private var _lastUsed = Date.distantPast

    init(origin: PersistentHTTP1Transport.Origin, label: String) {
        self.origin = origin
        self.label = label
    }

    var requestCount: Int { stateLock.withLock { _requestCount } }
    var lastUsed: Date { stateLock.withLock { _lastUsed } }

    func send(target: URL, headers: [String: String], limit: Int) async throws -> Outcome {
        let task = try connectIfNeeded()
        let reused = stateLock.withLock { () -> Bool in
            _requestCount += 1
            _lastUsed = Date()
            return _requestCount > 1
        }
        let deadline = Date().addingTimeInterval(Self.exchangeDeadline)
        return try await withTaskCancellationHandler {
            let request = try HeldSourceConnection.requestBytes(
                target: target, host: origin.host, port: origin.port, secure: origin.secure,
                offset: nil, extraHeaders: headers, userAgent: nil)
            do {
                try await task.write(request, timeout: Self.writeTimeout)
            } catch {
                if reused, !Task.isCancelled { throw ConnectionError.staleKeepAlive }
                throw error
            }
            let head: HeldSourceConnection.ResponseHead
            do {
                head = try await readHead(task, reused: reused, deadline: deadline)
            } catch let error as ConnectionError {
                throw error
            } catch {
                if reused, !Task.isCancelled { throw ConnectionError.staleKeepAlive }
                throw error
            }
            return try await readBody(task, head: head, limit: limit, deadline: deadline)
        } onCancel: {
            self.retire(reason: "cancelled")
        }
    }

    /// Closes the socket. Idempotent; the first reason is the one logged.
    func retire(reason: String) {
        stateLock.lock()
        if retired {
            stateLock.unlock()
            return
        }
        retired = true
        let task = self.task
        let session = self.session
        let count = _requestCount
        self.task = nil
        self.session = nil
        pending = Data()
        stateLock.unlock()
        task?.closeRead()
        task?.closeWrite()
        session?.invalidateAndCancel()
        guard task != nil else { return }
        EngineLog.emit(
            "[HLSVODIngest] AE#732 connection \(label) \(origin) closed after \(count) "
                + "request\(count == 1 ? "" : "s") reason=\(reason)",
            category: .engine)
    }

    // MARK: - Wire

    private func connectIfNeeded() throws -> URLSessionStreamTask {
        stateLock.lock()
        if retired {
            stateLock.unlock()
            throw CancellationError()
        }
        if let task {
            stateLock.unlock()
            return task
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.readTimeout
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        let session = URLSession(
            configuration: configuration, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
        let task = session.streamTask(withHostName: origin.host, port: origin.port)
        self.session = session
        self.task = task
        stateLock.unlock()
        task.resume()
        if origin.secure { task.startSecureConnection() }
        EngineLog.emit(
            "[HLSVODIngest] AE#732 connection \(label) open \(origin) protocol=http/1.1",
            category: .engine)
        return task
    }

    private func readHead(
        _ task: URLSessionStreamTask, reused: Bool, deadline: Date
    ) async throws -> HeldSourceConnection.ResponseHead {
        let separator = Data("\r\n\r\n".utf8)
        var head = takePending()
        while head.range(of: separator) == nil {
            let (chunk, eof) = try await read(task, maxLength: 64 * 1024, deadline: deadline)
            if chunk.isEmpty && eof {
                if reused, head.isEmpty { throw ConnectionError.staleKeepAlive }
                throw ConnectionError.malformed("connection closed before a response head")
            }
            head.append(chunk)
            if head.count > Self.maxHeadBytes {
                throw ConnectionError.malformed("no head terminator in \(Self.maxHeadBytes) bytes")
            }
        }
        guard let split = head.range(of: separator) else {
            throw ConnectionError.malformed("head terminator vanished")
        }
        stateLock.withLock { pending = Data(head[split.upperBound...]) }
        return try HeldSourceConnection.ResponseHead(rawHead: head[..<split.lowerBound])
    }

    private func readBody(
        _ task: URLSessionStreamTask,
        head: HeldSourceConnection.ResponseHead,
        limit: Int,
        deadline: Date
    ) async throws -> Outcome {
        let success = (200..<300).contains(head.status)
        let cap = success ? limit : Self.maxDiscardedBodyBytes
        var framing = Self.framing(for: head)
        if case .identity(let length) = framing, length > Int64(cap) {
            if success { throw BoundedFetch.Exceeded(limit: limit) }
            return Outcome(head: head, body: Data(), notReusableBecause: "status \(head.status) body not drained")
        }
        var body = Data()
        loop: while true {
            switch framing {
            case .empty:
                break loop
            case .identity(let remaining):
                if remaining <= 0 { break loop }
                let data = try await nextBytes(task, upTo: Int(min(remaining, Int64(Self.maxReadBytes))), deadline: deadline)
                guard let data else {
                    throw ConnectionError.malformed("connection closed \(remaining) bytes before the end of the body")
                }
                body.append(data)
                framing = .identity(remaining: remaining - Int64(data.count))
            case .chunked(let decoder):
                if let out = try decoder.take(upTo: Self.maxReadBytes) {
                    body.append(out)
                } else if decoder.isComplete {
                    break loop
                } else {
                    guard let data = try await nextBytes(task, upTo: Self.maxReadBytes, deadline: deadline) else {
                        throw ConnectionError.malformed("connection closed inside a chunked body")
                    }
                    decoder.feed(data)
                }
            case .untilClose:
                guard let data = try await nextBytes(task, upTo: Self.maxReadBytes, deadline: deadline) else {
                    break loop
                }
                body.append(data)
            }
            if body.count > cap {
                if success { throw BoundedFetch.Exceeded(limit: limit) }
                return Outcome(head: head, body: Data(), notReusableBecause: "status \(head.status) body not drained")
            }
        }
        return Outcome(head: head, body: success ? body : Data(), notReusableBecause: Self.reuseRefusal(head, framing))
    }

    /// Why the connection cannot carry another request after this response, nil when it can.
    private static func reuseRefusal(_ head: HeldSourceConnection.ResponseHead, _ framing: Framing) -> String? {
        if case .untilClose = framing { return "body framed by close" }
        let connection = head.headers["connection"]?.lowercased() ?? ""
        if connection.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "close" }) {
            return "server close"
        }
        if !head.statusLine.hasPrefix("HTTP/1.1") { return "not HTTP/1.1 (\(head.statusLine.prefix(8)))" }
        return nil
    }

    private static func framing(for head: HeldSourceConnection.ResponseHead) -> Framing {
        if (100..<200).contains(head.status) || head.status == 204 || head.status == 304 { return .empty }
        if head.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return .chunked(ChunkedBodyDecoder())
        }
        if let raw = head.headers["content-length"], let length = Int64(raw), length >= 0 {
            return .identity(remaining: length)
        }
        return .untilClose
    }

    /// Bytes left over from the head read first, then the socket. nil is EOF.
    private func nextBytes(_ task: URLSessionStreamTask, upTo limit: Int, deadline: Date) async throws -> Data? {
        let buffered = stateLock.withLock { () -> Data in
            let slice = pending.prefix(limit)
            pending.removeFirst(slice.count)
            return Data(slice)
        }
        if !buffered.isEmpty { return buffered }
        let (data, eof) = try await read(task, maxLength: limit, deadline: deadline)
        if data.isEmpty && eof { return nil }
        return data
    }

    private func takePending() -> Data {
        stateLock.withLock {
            let data = pending
            pending = Data()
            return data
        }
    }

    private func read(
        _ task: URLSessionStreamTask, maxLength: Int, deadline: Date
    ) async throws -> (Data, Bool) {
        try Task.checkCancellation()
        let left = deadline.timeIntervalSinceNow
        guard left > 0 else { throw ConnectionError.deadlineExceeded }
        let (data, eof) = try await task.readData(
            ofMinLength: 1, maxLength: max(1, maxLength), timeout: min(Self.readTimeout, left))
        return (data ?? Data(), eof)
    }
}
