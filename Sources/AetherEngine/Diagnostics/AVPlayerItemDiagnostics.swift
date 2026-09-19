import AVFoundation
import Foundation

struct ItemDiagnosticRequest: OptionSet, Sendable {
    let rawValue: Int
    static let access = Self(rawValue: 1 << 0)
    static let error = Self(rawValue: 1 << 1)
    static let failure = Self(rawValue: 1 << 2)
    static let counters = Self(rawValue: 1 << 3)
}

struct ItemLogCounters: Sendable {
    var transferredBytes: Int64?
    var droppedFrames: Int?

    mutating func merge(_ other: Self) {
        if let bytes = other.transferredBytes {
            transferredBytes = max(transferredBytes ?? 0, bytes)
        }
        if let frames = other.droppedFrames {
            droppedFrames = max(droppedFrames ?? 0, frames)
        }
    }
}

/// Logs cross back as values, never AVFoundation's log/event objects. Failed-item track handles
/// are UI-actor-isolated by the SDK: fetch the array off-main, then use their async asset loaders.
struct ItemDiagnosticSnapshot: Sendable {
    struct Access: Sendable {
        var uri: String?
        var server: String?
        var bytes: Int64
        var requests: Int
        var stalls: Int
        var droppedFrames: Int
    }

    struct Error: Sendable {
        var code: Int
        var domain: String
        var comment: String?
        var uri: String?
        var server: String?
    }

    var access: [Access]?
    var errors: [Error]?
    var failureDetails: [String] = []
    var failedTracks: [AVPlayerItemTrack]?

    var counters: ItemLogCounters {
        ItemLogCounters(
            transferredBytes: access.flatMap {
                LiveTelemetrySampler.sessionTotal(perEntry: $0.map(\.bytes))
            },
            droppedFrames: access.flatMap {
                LiveTelemetrySampler.sessionTotal(perEntry: $0.map(\.droppedFrames))
            })
    }

    nonisolated static func read(_ item: AVPlayerItem, _ request: ItemDiagnosticRequest) -> Self {
        var snapshot = Self()
        if !request.intersection([.error, .failure]).isEmpty {
            snapshot.errors = item.errorLog()?.events.map {
                Error(code: $0.errorStatusCode, domain: $0.errorDomain, comment: $0.errorComment,
                      uri: $0.uri, server: $0.serverAddress)
            }
        }
        if !request.intersection([.access, .failure, .counters]).isEmpty {
            snapshot.access = item.accessLog()?.events.map {
                Access(uri: $0.uri, server: $0.serverAddress, bytes: $0.numberOfBytesTransferred,
                       requests: $0.numberOfMediaRequests, stalls: $0.numberOfStalls,
                       droppedFrames: $0.numberOfDroppedVideoFrames)
            }
        }
        if request.contains(.failure) {
            snapshot.failedTracks = item.tracks
            let duration = item.duration.seconds
            snapshot.failureDetails = [
                "item.presentationSize=\(item.presentationSize)",
                "item.seekableTimeRanges.count=\(item.seekableTimeRanges.count)",
                "item.loadedTimeRanges.count=\(item.loadedTimeRanges.count)",
                "item.canPlayFastForward=\(item.canPlayFastForward) canPlayFastReverse=\(item.canPlayFastReverse) canStepForward=\(item.canStepForward)",
                "item.duration=\(duration.isFinite ? String(format: "%.2f", duration) : "indef")",
                "item.appliesPerFrameHDRDisplayMetadata=\(item.appliesPerFrameHDRDisplayMetadata)",
            ]
        }
        return snapshot
    }
}

/// Process-wide admission, not a fresh queue/thread per load. Cancellation invalidates publication;
/// it cannot release a lane still inside a synchronous native getter. A second lane lets a new item
/// make progress past one stranded read. If both strand, diagnostics wait, never playback.
@MainActor
final class ItemDiagnosticReadPool {
    static let shared = ItemDiagnosticReadPool()
    nonisolated static let maximumConcurrentReads = 2
    private let queue = DispatchQueue(label: "engine.item-diagnostics", qos: .utility, attributes: .concurrent)
    private var pending: [AVPlayerItemDiagnostics] = []
    private(set) var runningCount = 0
    var pendingCount: Int { pending.count }

    fileprivate func schedule(_ reader: AVPlayerItemDiagnostics) {
        guard !reader.inFlight else { return }
        // Retirement may change the priority of a request that was already queued as current.
        pending.removeAll { $0 === reader }
        if reader.retired {
            pending.append(reader)
        } else {
            pending.insert(reader, at: pending.firstIndex(where: \.retired) ?? pending.endIndex)
        }
        drain()
        let retirements = pending.filter(\.retired)
        for retired in retirements.dropLast(AVPlayerItemDiagnostics.maximumPendingRetirements) {
            retired.finishRetirement(complete: false)
        }
    }

    fileprivate func remove(_ reader: AVPlayerItemDiagnostics) {
        pending.removeAll { $0 === reader }
    }

    private func drain() {
        while runningCount < Self.maximumConcurrentReads, !pending.isEmpty {
            let reader = pending.removeFirst()
            guard let request = reader.takeRequest() else { continue }
            runningCount += 1
            let item = reader.item
            let read = reader.read
            Task { @MainActor in
                let snapshot = await AVFoundationOffMain.read(item, on: queue) { item in
                    read(item, request)
                }
                runningCount -= 1
                reader.complete(snapshot, request: request)
                drain()
            }
        }
    }
}

/// One item, one in-flight batch and one union of pending reasons. Notification callbacks only
/// request a read; neither the callback nor a teardown waits for it.
@MainActor
final class AVPlayerItemDiagnostics {
    typealias Read = @Sendable (AVPlayerItem, ItemDiagnosticRequest) -> ItemDiagnosticSnapshot
    static let accessLogLimit = 5
    static let maximumPendingRetirements = 1

    fileprivate let item: AVPlayerItem
    fileprivate let read: Read
    private let pool: ItemDiagnosticReadPool
    private var pending: ItemDiagnosticRequest = []
    private var active = true
    fileprivate var retired = false
    private(set) var inFlight = false
    private(set) var counters = ItemLogCounters()
    private var seenErrors = 0
    private var seenAccessEntries = 0
    private(set) var accessLogCount = 0
    var onSnapshot: ((ItemDiagnosticSnapshot, ItemDiagnosticRequest) -> Void)?
    private var onRetired: ((ItemLogCounters, Bool) -> Void)?

    init(item: AVPlayerItem, pool: ItemDiagnosticReadPool = .shared,
         read: @escaping Read = ItemDiagnosticSnapshot.read) {
        self.item = item
        self.pool = pool
        self.read = read
    }

    func request(_ reason: ItemDiagnosticRequest) {
        guard active, !retired else { return }
        pending.formUnion(reason)
        pool.schedule(self)
    }

    func recordCounters(_ value: ItemLogCounters) {
        counters.merge(value)
    }

    func retire(_ completion: @escaping (ItemLogCounters, Bool) -> Void) {
        guard active else { return }
        retired = true
        onSnapshot = nil
        onRetired = completion
        // Always obtain a post-detach reading; an already-running batch may have sampled before
        // the handover. Its result still raises the cached lower bound, but does not finish retirement.
        pending = .counters
        pool.schedule(self)
    }

    func cancel() {
        active = false
        pending = []
        onSnapshot = nil
        onRetired = nil
        pool.remove(self)
        // Do not clear inFlight: only the returning native read can do that.
    }

    fileprivate func finishRetirement(complete: Bool) {
        let completion = onRetired
        cancel()
        completion?(counters, complete)
    }

    fileprivate func takeRequest() -> ItemDiagnosticRequest? {
        guard active, !inFlight, !pending.isEmpty else { return nil }
        let request = pending
        pending = []
        inFlight = true
        return request
    }

    fileprivate func complete(_ snapshot: ItemDiagnosticSnapshot, request: ItemDiagnosticRequest) {
        inFlight = false
        guard active else { return }
        counters.merge(snapshot.counters)
        if retired {
            if request == .counters {
                finishRetirement(complete: true)
                return
            }
        } else {
            onSnapshot?(snapshot, request)
        }
        if !pending.isEmpty { pool.schedule(self) }
    }

    /// A coalesced error read must inspect ALL unseen entries, not just the last: a later HTTP
    /// error must not hide the -15628 startup loader-poison signal.
    func newErrors(in snapshot: ItemDiagnosticSnapshot) -> [ItemDiagnosticSnapshot.Error] {
        guard let errors = snapshot.errors else { return [] }
        let result = Array(errors.dropFirst(seenErrors))
        seenErrors = errors.count
        return result
    }

    func newAccessEntries(in snapshot: ItemDiagnosticSnapshot) -> [ItemDiagnosticSnapshot.Access] {
        guard let entries = snapshot.access else { return [] }
        let result = Array(entries.dropFirst(seenAccessEntries).prefix(Self.accessLogLimit - accessLogCount))
        seenAccessEntries = entries.count
        accessLogCount += result.count
        return result
    }
}
