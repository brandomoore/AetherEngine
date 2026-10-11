import Foundation

/// One file-size discovery, including its delayed workers and requests. All mutable state is
/// condition-guarded. Workers run on owned threads because the demuxer's open API is synchronous.
/// A result cancels sibling requests; join waits for their tickets to be returned before playback
/// can start another request. The monotonic deadline covers both slot and response waits.
final class SourceSizeProbeScope: @unchecked Sendable {
    private let condition = NSCondition()
    private let deadline: DispatchTime
    private var stopped = false
    private var size: Int64 = -1
    private var workers = 0
    private var tasks: [ObjectIdentifier: URLSessionTask] = [:]

    init(timeout: TimeInterval) { deadline = .now() + timeout }

    var remaining: TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        return deadline.uptimeNanoseconds > now
            ? Double(deadline.uptimeNanoseconds - now) / 1_000_000_000 : 0
    }

    var isStopped: Bool { condition.withLock { stopped } || remaining <= 0 }

    func addWorker() { condition.withLock { workers += 1 } }

    func finishWorker() {
        condition.lock()
        workers -= 1
        condition.broadcast()
        condition.unlock()
    }

    func waitToStart(after delay: TimeInterval) -> Bool {
        let until = Date(timeIntervalSinceNow: min(delay, remaining))
        condition.lock()
        defer { condition.unlock() }
        while !stopped && Date() < until { condition.wait(until: until) }
        return !stopped && remaining > 0
    }

    func resume(_ task: URLSessionTask) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !stopped, remaining > 0 else { return false }
        tasks[ObjectIdentifier(task)] = task
        task.resume()
        return true
    }

    func remove(_ task: URLSessionTask) {
        _ = condition.withLock { tasks.removeValue(forKey: ObjectIdentifier(task)) }
    }

    func resolve(_ candidate: Int64) {
        guard candidate > 0 else { return }
        condition.lock()
        guard !stopped, remaining > 0 else { condition.unlock(); return }
        size = candidate
        stopped = true
        let pending = Array(tasks.values)
        condition.broadcast()
        condition.unlock()
        pending.forEach { $0.cancel() }
    }

    func cancel() {
        condition.lock()
        stopped = true
        let pending = Array(tasks.values)
        condition.broadcast()
        condition.unlock()
        pending.forEach { $0.cancel() }
    }

    func join(shouldAbort: () -> Bool) -> Int64 {
        condition.lock()
        while workers > 0 {
            condition.unlock()
            if shouldAbort() || remaining <= 0 { cancel() }
            condition.lock()
            if workers > 0 { condition.wait(until: Date(timeIntervalSinceNow: 0.05)) }
        }
        let result = size
        condition.unlock()
        return shouldAbort() ? -1 : result
    }
}
