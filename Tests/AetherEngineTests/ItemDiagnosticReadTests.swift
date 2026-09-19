import AVFoundation
import Combine
import Foundation
import Testing
@testable import AetherEngine

private final class DiagnosticReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var blocked = true
    private var reads: [(ObjectIdentifier, ItemDiagnosticRequest)] = []
    private var mainThreadRead = false
    let snapshot: ItemDiagnosticSnapshot
    let onlyFirstItem: Bool

    init(snapshot: ItemDiagnosticSnapshot = .init(), onlyFirstItem: Bool = false) {
        self.snapshot = snapshot
        self.onlyFirstItem = onlyFirstItem
    }

    var count: Int { lock.withLock { reads.count } }
    var ranOnMain: Bool { lock.withLock { mainThreadRead } }
    var items: [ObjectIdentifier] { lock.withLock { reads.map(\.0) } }

    func read(_ item: AVPlayerItem, _ request: ItemDiagnosticRequest) -> ItemDiagnosticSnapshot {
        let (shouldBlock, suppliesSnapshot) = lock.withLock {
            let suppliesSnapshot = !onlyFirstItem
                || (reads.first.map { $0.0 == ObjectIdentifier(item) } ?? true)
            reads.append((ObjectIdentifier(item), request))
            mainThreadRead = mainThreadRead || Thread.isMainThread
            return (blocked && suppliesSnapshot, suppliesSnapshot)
        }
        if shouldBlock { release.wait() }
        return suppliesSnapshot ? snapshot : .init()
    }

    func unblock() {
        lock.withLock { blocked = false }
        // At most the pool's occupied lanes can have entered this getter.
        for _ in 0..<ItemDiagnosticReadPool.maximumConcurrentReads { release.signal() }
    }

    func releaseOne() { release.signal() }
}

@MainActor
@Suite(.timeLimit(.minutes(3)))
struct ItemDiagnosticReadTests {
    private func item() -> AVPlayerItem {
        AVPlayerItem(asset: AVMutableComposition())
    }

    private func access(_ bytes: Int64, _ dropped: Int = 0) -> ItemDiagnosticSnapshot.Access {
        .init(bytes: bytes, requests: 1, stalls: 0, droppedFrames: dropped)
    }

    @Test("blocking getters leave the main actor free and notification bursts coalesce")
    func coalescesWhileBlocked() async throws {
        let pool = ItemDiagnosticReadPool()
        let probe = DiagnosticReadProbe()
        defer { probe.unblock() }
        let reader = AVPlayerItemDiagnostics(item: item(), pool: pool, read: probe.read)
        defer { reader.cancel() }
        var delivered: [ItemDiagnosticRequest] = []
        reader.onSnapshot = { _, request in delivered.append(request) }
        reader.request(.access)
        try await waitFor { probe.count == 1 }

        for _ in 0..<100 {
            reader.request(.access)
            reader.request(.error)
            reader.request(.failure)
        }
        #expect(probe.count == 1)
        #expect(pool.runningCount == 1)
        #expect(pool.pendingCount == 0)
        #expect(delivered.isEmpty)
        probe.unblock()
        try await waitFor { delivered.count == 2 && pool.runningCount == 0 }
        #expect(delivered == [.access, [.access, .error, .failure]])
        #expect(probe.count == 2)
        #expect(!probe.ranOnMain)
    }

    @Test("cancellation does not release a blocked lane; a new item can use the other lane")
    func cancellationDoesNotPretendToDrain() async throws {
        let pool = ItemDiagnosticReadPool()
        let probe = DiagnosticReadProbe()
        defer { probe.unblock() }
        let old = AVPlayerItemDiagnostics(item: item(), pool: pool, read: probe.read)
        var stalePublished = false
        old.onSnapshot = { _, _ in stalePublished = true }
        old.request(.error)
        try await waitFor { probe.count == 1 }
        old.cancel()
        #expect(old.inFlight)
        #expect(pool.runningCount == 1)

        let replacement = AVPlayerItemDiagnostics(item: item(), pool: pool, read: { _, _ in .init() })
        defer { replacement.cancel() }
        var newPublished = false
        replacement.onSnapshot = { _, _ in newPublished = true }
        replacement.request(.error)
        try await waitFor { newPublished && pool.runningCount == 1 }
        #expect(!stalePublished)
        probe.unblock()
        try await waitFor { pool.runningCount == 0 }
        #expect(!old.inFlight)
        #expect(!stalePublished)
    }

    @Test("two blocked lanes bound swap bursts, retain observed counters, and prioritize current errors")
    func saturationBoundsRetirement() async throws {
        let pool = ItemDiagnosticReadPool()
        let probe = DiagnosticReadProbe()
        defer { probe.unblock() }
        let blocked = (0..<2).map { _ in
            AVPlayerItemDiagnostics(item: item(), pool: pool, read: probe.read)
        }
        for reader in blocked { reader.request(.access) }
        try await waitFor { probe.count == 2 }
        for reader in blocked { reader.cancel() }

        var incomplete = 0
        var completed = 0
        var retiredBytes: Int64 = 0
        for _ in 0..<100 {
            let retiring = AVPlayerItemDiagnostics(item: item(), pool: pool, read: probe.read)
            retiring.recordCounters(.init(transferredBytes: 10, droppedFrames: 1))
            retiring.request(.access)
            retiring.retire { counters, complete in
                retiredBytes += counters.transferredBytes ?? 0
                if complete { completed += 1 } else { incomplete += 1 }
            }
            #expect(pool.pendingCount <= AVPlayerItemDiagnostics.maximumPendingRetirements)
            #expect(pool.runningCount == 2)
        }
        #expect(incomplete == 99)
        #expect(retiredBytes == 990)
        #expect(probe.count == 2)

        let currentItem = item()
        let current = AVPlayerItemDiagnostics(item: currentItem, pool: pool, read: probe.read)
        defer { current.cancel() }
        var currentPublished = false
        current.onSnapshot = { _, _ in currentPublished = true }
        for _ in 0..<100 { current.request(.error) }
        #expect(pool.pendingCount == 2)
        probe.releaseOne()
        try await waitFor { probe.count == 3 }
        #expect(probe.items[2] == ObjectIdentifier(currentItem))
        #expect(!currentPublished)
        probe.unblock()
        try await waitFor { currentPublished && completed == 1 && pool.runningCount == 0 }
        #expect(retiredBytes == 1_000)
        #expect(pool.pendingCount == 0)
    }

    @Test("retirement reconciles a post-detach final sample without losing a newer observed baseline")
    func retirementReconcilesCounters() async throws {
        let pool = ItemDiagnosticReadPool()
        let probe = DiagnosticReadProbe(snapshot: .init(access: [access(150, 7), access(-1, -1)]))
        defer { probe.unblock() }
        let reader = AVPlayerItemDiagnostics(item: item(), pool: pool, read: probe.read)
        reader.recordCounters(.init(transferredBytes: 100, droppedFrames: 5))
        reader.request(.access)
        try await waitFor { probe.count == 1 }
        var final: ItemLogCounters?
        reader.retire { counters, complete in
            #expect(complete)
            final = counters
        }
        #expect(final == nil)
        #expect(reader.counters.transferredBytes == 100)
        probe.unblock()
        try await waitFor { final != nil }
        #expect(probe.count == 2)
        #expect(final?.transferredBytes == 150)
        #expect(final?.droppedFrames == 7)
        #expect(ItemDiagnosticSnapshot().counters.transferredBytes == nil)
        #expect(ItemDiagnosticSnapshot(access: [access(-1, -1)]).counters.droppedFrames == nil)
    }

    @Test("coalesced logs retain loader poison before later errors and cap access output per item")
    func logSemantics() {
        let reader = AVPlayerItemDiagnostics(item: item())
        defer { reader.cancel() }
        let snapshot = ItemDiagnosticSnapshot(
            access: (0..<10).map { access(Int64($0), $0) },
            errors: [.init(code: -15628, domain: "CoreMediaErrorDomain"),
                     .init(code: 404, domain: "HTTP")])
        #expect(reader.newErrors(in: snapshot).map(\.code) == [-15628, 404])
        #expect(reader.newErrors(in: snapshot).isEmpty)
        #expect(reader.newAccessEntries(in: snapshot).count == 5)
        #expect(reader.newAccessEntries(in: snapshot).isEmpty)
        #expect(reader.accessLogCount == AVPlayerItemDiagnostics.accessLogLimit)
        #expect(snapshot.counters.transferredBytes == 45)
        #expect(snapshot.counters.droppedFrames == 45)
        let replacement = AVPlayerItemDiagnostics(item: item())
        #expect(replacement.newAccessEntries(in: snapshot).count == 5)
        replacement.cancel()
    }

    @Test("native notification reads are item-bound and a late old poison cannot affect a fresh load")
    func nativeNotificationWiring() async throws {
        let pool = ItemDiagnosticReadPool()
        let oldProbe = DiagnosticReadProbe(snapshot: .init(
            errors: [.init(code: -15628, domain: "CoreMediaErrorDomain")]), onlyFirstItem: true)
        defer { oldProbe.unblock() }
        let host = NativeAVPlayerHost(diagnosticPool: pool, diagnosticRead: oldProbe.read)
        defer { host.tearDown() }
        let url = URL(fileURLWithPath: "/nonexistent-diagnostic-test.m3u8")
        host.load(url: url, startPosition: nil, contract: .init())
        let oldItem = try #require(host.avPlayer.currentItem)
        NotificationCenter.default.post(name: AVPlayerItem.newErrorLogEntryNotification, object: oldItem)
        try await waitFor { oldProbe.count == 1 }
        let stalls = host.stallCount
        host.tearDown()
        host.load(url: url, startPosition: nil, contract: .init())
        let newItem = try #require(host.avPlayer.currentItem)
        NotificationCenter.default.post(name: AVPlayerItem.newErrorLogEntryNotification, object: newItem)
        try await waitFor { oldProbe.items.contains(ObjectIdentifier(newItem)) && pool.runningCount == 1 }
        #expect(host.avPlayer.currentItem === newItem)
        oldProbe.unblock()
        try await waitFor { pool.runningCount == 0 }
        #expect(host.stallCount == stalls)
        #expect(oldProbe.items.filter { $0 == ObjectIdentifier(oldItem) }.count == 1)
        #expect(oldItem !== newItem)
    }

    @Test("native swaps fold cached counters immediately, reconcile once, and reset on a new session")
    func nativeCounterHandover() async throws {
        let pool = ItemDiagnosticReadPool()
        let probe = DiagnosticReadProbe(snapshot: .init(access: [access(150, 7)]))
        defer { probe.unblock() }
        let host = NativeAVPlayerHost(diagnosticPool: pool, diagnosticRead: probe.read)
        defer { host.tearDown() }
        let url = URL(fileURLWithPath: "/nonexistent-counter-test.m3u8")
        host.load(url: url, startPosition: nil, contract: .init())
        let outgoing = try #require(host.avPlayer.currentItem)
        host.recordItemCounters(.init(transferredBytes: 100, droppedFrames: 5), item: outgoing)
        host.swapItem(url: url, startPosition: nil)
        #expect(host.retiredItemTransferredBytes == 100)
        #expect(host.retiredItemDroppedFrames == 5)
        probe.unblock()
        try await waitFor { host.retiredItemTransferredBytes == 150 }
        #expect(host.retiredItemDroppedFrames == 7)
        host.prepareForItemHandover()
        #expect(host.retiredItemTransferredBytes == 0)
        #expect(host.retiredItemDroppedFrames == 0)
    }

    @Test("a blocked retirement cannot reconcile counters into an unrelated new load")
    func lateCounterReconciliationIsDiscarded() async throws {
        let pool = ItemDiagnosticReadPool()
        let probe = DiagnosticReadProbe(snapshot: .init(access: [access(999, 99)]))
        defer { probe.unblock() }
        let host = NativeAVPlayerHost(diagnosticPool: pool, diagnosticRead: probe.read)
        defer { host.tearDown() }
        let url = URL(fileURLWithPath: "/nonexistent-retirement-test.m3u8")
        host.load(url: url, startPosition: nil, contract: .init())
        let outgoing = try #require(host.avPlayer.currentItem)
        host.recordItemCounters(.init(transferredBytes: 100, droppedFrames: 5), item: outgoing)
        host.swapItem(url: url, startPosition: nil)
        try await waitFor { probe.count >= 1 }
        #expect(host.retiredItemTransferredBytes == 100)
        host.load(url: url, startPosition: nil, contract: .init())
        #expect(host.retiredItemTransferredBytes == 0)
        host.tearDown()
        probe.unblock()
        try await waitFor { pool.runningCount == 0 }
        #expect(host.retiredItemTransferredBytes == 0)
        #expect(host.retiredItemDroppedFrames == 0)
    }

    @Test("native coalesced error notifications still publish startup loader poison once")
    func nativeLoaderPoison() async throws {
        let pool = ItemDiagnosticReadPool()
        let probe = DiagnosticReadProbe(snapshot: .init(
            errors: [.init(code: -15628, domain: "CoreMediaErrorDomain"),
                     .init(code: 404, domain: "HTTP")]))
        defer { probe.unblock() }
        let host = NativeAVPlayerHost(diagnosticPool: pool, diagnosticRead: probe.read)
        defer { host.tearDown() }
        host.load(url: URL(fileURLWithPath: "/nonexistent-loader-test.m3u8"),
                  startPosition: nil, contract: .init())
        let current = try #require(host.avPlayer.currentItem)
        NotificationCenter.default.post(name: AVPlayerItem.newErrorLogEntryNotification, object: current)
        try await waitFor { probe.count == 1 }
        let stalls = host.stallCount
        for _ in 0..<100 {
            NotificationCenter.default.post(name: AVPlayerItem.newErrorLogEntryNotification, object: current)
        }
        probe.unblock()
        try await waitFor { host.stallCount == stalls + 1 && pool.runningCount == 0 }
        #expect(host.stallCount == stalls + 1)
    }

    @Test("a synchronous stall subscriber replacing the item rejects the rest of the old batch",
          arguments: [false, true])
    func replacementDuringDelivery(inPlace: Bool) async throws {
        let pool = ItemDiagnosticReadPool()
        let probe = DiagnosticReadProbe(snapshot: .init(
            errors: [.init(code: -15628, domain: "CoreMediaErrorDomain"),
                     .init(code: -15628, domain: "CoreMediaErrorDomain")]), onlyFirstItem: true)
        defer { probe.unblock() }
        let host = NativeAVPlayerHost(diagnosticPool: pool, diagnosticRead: probe.read)
        defer { host.tearDown() }
        let url = URL(fileURLWithPath: "/nonexistent-reentrant-diagnostic.m3u8")
        host.load(url: url, startPosition: nil, contract: .init())
        let outgoing = try #require(host.avPlayer.currentItem)
        NotificationCenter.default.post(name: AVPlayerItem.newErrorLogEntryNotification, object: outgoing)
        try await waitFor { probe.count == 1 }
        let stalls = host.stallCount
        var publications: [Int] = []
        var replacement: AVPlayerItem?
        let subscription = host.$stallCount.dropFirst().sink { value in
            publications.append(value)
            guard replacement == nil else { return }
            if inPlace {
                host.swapItem(url: url, startPosition: nil)
            } else {
                host.load(url: url, startPosition: nil, contract: .init())
            }
            replacement = host.avPlayer.currentItem
        }
        defer { subscription.cancel() }
        probe.unblock()
        try await waitFor { replacement != nil && pool.runningCount == 0 }
        #expect(replacement !== outgoing)
        #expect(publications == [stalls + 1])
        #expect(host.stallCount == stalls + 1)
    }

    @Test("audio error notifications leave the callback free and stop rejects the late snapshot")
    func audioNotificationWiring() async throws {
        let pool = ItemDiagnosticReadPool()
        let probe = DiagnosticReadProbe()
        defer { probe.unblock() }
        let host = AudioAVPlayerHost(diagnosticPool: pool, diagnosticRead: probe.read)
        defer { host.stop() }
        try await host.load(url: URL(fileURLWithPath: "/nonexistent-audio-diagnostic.m4a"),
                            startPosition: nil, httpHeaders: [:])
        let outgoing = try #require(host.avPlayer.currentItem)
        NotificationCenter.default.post(name: AVPlayerItem.newErrorLogEntryNotification, object: outgoing)
        try await waitFor { probe.count == 1 }
        for _ in 0..<100 {
            NotificationCenter.default.post(name: AVPlayerItem.newErrorLogEntryNotification, object: outgoing)
        }
        #expect(probe.count == 1)
        host.stop()
        #expect(pool.runningCount == 1)
        probe.unblock()
        try await waitFor { pool.runningCount == 0 }
        #expect(probe.count == 1)
        #expect(!probe.ranOnMain)
    }

    @Test("real idle AVFoundation log getters produce missing rather than fabricated counters")
    func idleNativeRead() async throws {
        let pool = ItemDiagnosticReadPool()
        let reader = AVPlayerItemDiagnostics(item: item(), pool: pool)
        defer { reader.cancel() }
        var result: ItemDiagnosticSnapshot?
        reader.onSnapshot = { snapshot, _ in result = snapshot }
        reader.request([.access, .error, .failure])
        try await waitFor { result != nil }
        #expect(result?.counters.transferredBytes == nil)
        #expect(result?.counters.droppedFrames == nil)
        #expect(result?.failureDetails.isEmpty == false)
    }
}
