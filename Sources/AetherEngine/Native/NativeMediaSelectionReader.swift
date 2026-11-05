import AVFoundation
import Foundation

/// A selection query is synchronous media-service IPC, even after the group loaded asynchronously.
final class NativeMediaSelectionReader: @unchecked Sendable {
    // AVMediaSelectionOption is an immutable selection descriptor, not a mutable player handle.
    struct Snapshot: @unchecked Sendable {
        let option: AVMediaSelectionOption?
    }
    private struct References: @unchecked Sendable {
        let item: AVPlayerItem
        let group: AVMediaSelectionGroup
    }

    static let shared = NativeMediaSelectionReader()
    static let maximumConcurrentReads = 2
    static let defaultTimeout: TimeInterval = 0.5
    private let lock = NSLock()
    private var running = 0
    private var loggedUnavailable = false

    @MainActor func read(
        item: AVPlayerItem, group: AVMediaSelectionGroup,
        timeout: TimeInterval = NativeMediaSelectionReader.defaultTimeout
    ) async -> Snapshot? {
        await read(References(item: item, group: group), timeout: timeout) {
            Snapshot(option: $0.item.currentMediaSelection.selectedMediaOption(in: $0.group))
        }
    }

    func read<Refs: Sendable>(
        _ refs: Refs, timeout: TimeInterval,
        query: @escaping @Sendable (Refs) -> Snapshot
    ) async -> Snapshot? {
        guard !Task.isCancelled else { return nil }
        let admitted = lock.withLock {
            guard running < Self.maximumConcurrentReads else { return false }
            running += 1
            return true
        }
        guard admitted else {
            logUnavailable()
            return nil
        }
        let result = await AVFoundationOffMain.read(refs, timeout: timeout) { [self] refs in
            // Timing out the waiter must not free a lane still blocked inside AVFoundation.
            defer { lock.withLock { running -= 1 } }
            return query(refs)
        }
        guard !Task.isCancelled else { return nil }
        if result == nil { logUnavailable() }
        return result
    }

    private func logUnavailable() {
        let shouldLog = lock.withLock {
            guard !loggedUnavailable else { return false }
            loggedUnavailable = true
            return true
        }
        if shouldLog {
            EngineLog.emit(
                "[AetherEngine] Native media selection unavailable: read timed out or both reader lanes are occupied.",
                category: .engine)
        }
    }
}
