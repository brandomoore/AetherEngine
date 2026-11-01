import Foundation
import Testing
@testable import AetherEngine

/// An empty read-ahead store is the end of the stream only when the source said so.
///
/// A seek that misses the cache empties the store while holding `operations`. A consumer read that
/// started inside the seek's window left its wait at once (its reader was not current), then waited
/// for `operations`; by the time it got the lock the seek had landed, its reader was current again,
/// and it found the store empty and returned nil, which the host takes for the end of the media.
/// Playback stopped at the landing (a DVD seek past the first cell: 7 of 8 runs).
@Suite("Software read-ahead end of stream", .offCooperativePool, .timeLimit(.minutes(1)))
struct SoftwarePacketReadAheadEndOfStreamTests {

    /// A reader that is not current on its first check and current on every later one: the
    /// seek's window closing between the read's wait and its admission check.
    private final class CurrentAfterFirstCheck: @unchecked Sendable {
        private let lock = NSLock()
        private var checks = 0
        func check() -> Bool { lock.lock(); defer { lock.unlock() }; checks += 1; return checks > 1 }
    }

    private static func readAhead(_ root: URL,
                                  source: @escaping @Sendable (@Sendable () -> Bool) throws -> SoftwareStoredPacket?
    ) throws -> SoftwarePacketReadAhead {
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 64 * 1024, retainConsumed: true,
                                              parentDirectory: root)
        return SoftwarePacketReadAhead(
            video: .init(index: 0, numerator: 1, denominator: 1000), audio: nil,
            byteBudget: 1 << 20, forwardSeconds: 10, initialSourceClock: 0, fifo: fifo,
            readSource: source)
    }

    private static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("readahead-eos-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func memorySource(
        beforeConsumerOperation: (@Sendable () -> Void)? = nil,
        read: @escaping @Sendable (@Sendable () -> Bool) throws -> SoftwareStoredPacket?
    ) -> SoftwarePacketReadAhead {
        SoftwarePacketReadAhead(
            video: .init(index: 0, numerator: 1, denominator: 1000), audio: nil,
            byteBudget: 1 << 20, forwardSeconds: 10, initialSourceClock: 0,
            fifo: SoftwarePacketMemoryFIFO(
                chunkTargetBytes: 16 << 10, historyCapBytes: 1 << 20, kernelMayPurge: false),
            beforeConsumerOperation: beforeConsumerOperation, readSource: read)
    }

    private static func packet(_ pts: Int64) -> SoftwareStoredPacket {
        .init(pts: pts, dts: pts, duration: 40, position: 0, streamIndex: 0, flags: 1,
              timeBaseNumerator: 1, timeBaseDenominator: 1000, bytes: Data([7]), sideData: [])
    }

    @Test("An empty store yields for service without becoming EOF")
    func emptyDeadlineYieldsForService() async throws {
        let source = Self.memorySource { _ in nil }
        defer { source.close() }
        let read = ProbeTestJob { try source.read(until: .distantPast) }
        let outcome = try await read.outcome()
        #expect(throws: SoftwarePacketReadAhead.ReadError.serviceDue) { try outcome.get() }
        #expect(!source.snapshot.sourceEnded)
    }

    @Test("An expired service deadline still returns queued packets in order, then genuine EOF")
    func deadlinePreservesPacketsAndEOF() async throws {
        let expected = [Self.packet(0), Self.packet(40)]
        let input = ProbeTestBox(expected)
        let source = Self.memorySource { _ in
            var next: SoftwareStoredPacket?
            input.update { if !$0.isEmpty { next = $0.removeFirst() } }
            return next
        }
        defer { source.close() }
        source.start()
        try await waitFor { source.snapshot.sourceEnded }
        let read = ProbeTestJob {
            var packets: [SoftwareStoredPacket] = []
            while let packet = try source.read(until: .distantPast) { packets.append(packet) }
            return packets
        }
        let outcome = try await read.outcome()
        #expect(try outcome.get() == expected)
    }

    private enum SourceFailure: Error { case unavailable }

    @Test("An expired service deadline does not hide the source failure after its queued packet")
    func deadlinePreservesSourceFailure() async throws {
        let packet = Self.packet(0)
        let first = ProbeTestBox(true)
        let source = Self.memorySource { _ in
            var deliver = false
            first.update { deliver = $0; $0 = false }
            if deliver { return packet }
            throw SourceFailure.unavailable
        }
        defer { source.close() }
        source.start()
        try await waitFor { source.producerParkedForTesting }
        let read = ProbeTestJob {
            #expect(try source.read(until: .distantPast) == packet)
            return try source.read(until: .distantPast)
        }
        let outcome = try await read.outcome()
        #expect(throws: SourceFailure.unavailable) { try outcome.get() }
        #expect(!source.snapshot.sourceEnded)
    }

    @Test("Host cancellation during an expired wait wins over a service wake")
    func deadlineRechecksHostAdmission() async throws {
        let source = Self.memorySource { _ in nil }
        defer { source.close() }
        let checks = ProbeTestBox(0)
        let read = ProbeTestJob {
            try source.read(until: .distantPast) {
                var current = false
                checks.update { current = $0 == 0; $0 += 1 }
                return current
            }
        }
        let outcome = try await read.outcome()
        #expect(throws: SoftwarePacketReadAhead.ReadError.interrupted) { try outcome.get() }
        #expect(!source.snapshot.sourceEnded)
    }

    enum PendingReadStop: CaseIterable, Sendable { case seek, close }

    @Test("Seek and close interrupt a service wait without waiting for source I/O",
          arguments: PendingReadStop.allCases)
    func serviceWaitCanBeInterrupted(_ stop: PendingReadStop) async throws {
        let sourceIO = ProbeTestGate()
        let source = Self.memorySource { _ in sourceIO.wait(); return nil }
        defer { source.close(); sourceIO.open() }
        source.start()
        let enteredRead = ProbeTestBox(false)
        let read = ProbeTestJob {
            try source.read(until: Date(timeIntervalSinceNow: 3600)) {
                enteredRead.update { $0 = true }
                return true
            }
        }
        try await waitFor { sourceIO.entered && enteredRead.value }
        switch stop {
        case .seek: source.beginSeek()
        case .close: source.close()
        }
        let outcome = try await read.outcome()
        let expected: SoftwarePacketReadAhead.ReadError = stop == .seek ? .interrupted : .closed
        #expect(throws: expected) { try outcome.get() }
        #expect(!sourceIO.isOpen)
        #expect(!source.snapshot.sourceEnded)
    }

    @Test("A delayed deadline read cannot steal a packet restored by a newer seek")
    func deadlineCannotConsumeNewSeekGeneration() async throws {
        let expected = [Self.packet(0), Self.packet(40)]
        let input = ProbeTestBox(expected)
        let consumerGate = ProbeTestGate()
        let source = Self.memorySource(beforeConsumerOperation: { consumerGate.wait() }) { _ in
            var next: SoftwareStoredPacket?
            input.update { if !$0.isEmpty { next = $0.removeFirst() } }
            return next
        }
        defer { source.close(); consumerGate.open() }
        source.start()
        try await waitFor { source.snapshot.sourceEnded }
        let oldRead = ProbeTestJob { try source.read(until: .distantPast) }
        try await waitFor { consumerGate.entered }
        let token = source.beginSeek(to: 0)
        let restore = ProbeTestJob { try source.prepareSeek(token, to: 0) }
        let restored = try await restore.outcome()
        try #require(try restored.get())
        source.endSeek(token, sourceClock: 0)
        consumerGate.open()
        let stale = try await oldRead.outcome()
        #expect(throws: SoftwarePacketReadAhead.ReadError.interrupted) { try stale.get() }
        #expect(source.snapshot.packetCount == expected.count)
        let currentRead = ProbeTestJob { try source.read(until: .distantPast) }
        let current = try await currentRead.outcome()
        #expect(try current.get() == expected.first)
    }

    @Test("an empty store whose reader becomes current again is not the end of the stream")
    func emptyStoreBeforeTheSourceEndsIsInterrupted() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Not started: nothing is read, the store stays empty, the source has not ended.
        let source = try Self.readAhead(root) { _ in nil }
        defer { source.close() }
        let reader = CurrentAfterFirstCheck()
        #expect(throws: SoftwarePacketReadAhead.ReadError.interrupted) {
            _ = try source.read(isCurrent: { reader.check() })
        }
    }

    @Test("the source's own end is the end of the stream")
    func sourceEndIsEndOfStream() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try Self.readAhead(root) { _ in nil }
        defer { source.close() }
        source.start()
        // The producer has to have seen the end before there is anything to measure.
        try await waitFor { source.snapshot.sourceEnded }
        #expect(try source.read() == nil)
    }
}
