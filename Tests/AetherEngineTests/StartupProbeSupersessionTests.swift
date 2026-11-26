import Foundation
import Testing
@testable import AetherEngine

/// Regression coverage for early supersession of the overlapped startup probe.
/// When `probe.open(...)` finishes while `awaitAudioSessionCategoryConfigured()` is still suspended,
/// `probeTask` drops its reference to `probe`, leaving the open `Demuxer` owned solely on `MainActor`.
/// Superseding the load before `checkLoadCurrent(gen)` must detach `probe.close()` after `probeTask`
/// finishes unwinding instead of letting `Demuxer.deinit` close synchronously on the main thread.
@Suite("Early supersession closes the startup probe off the main thread", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct StartupProbeSupersessionTests {

    @MainActor
    private final class AsyncGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var isWaiting = false

        func wait() async {
            if released { return }
            isWaiting = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func release() {
            released = true
            let pending = continuation
            continuation = nil
            pending?.resume()
        }
    }

    private final class ProbeCloseRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _probeTaskCompleted = false
        private var _closeCount = 0
        private var _closedOnMainThread: Bool? = nil
        private var _readExitedBeforeClose = false

        var probeTaskCompleted: Bool { lock.withLock { _probeTaskCompleted } }
        var closeCount: Int { lock.withLock { _closeCount } }
        var closedOnMainThread: Bool? { lock.withLock { _closedOnMainThread } }
        var readExitedBeforeClose: Bool { lock.withLock { _readExitedBeforeClose } }

        func noteProbeTaskCompleted() {
            lock.withLock { _probeTaskCompleted = true }
        }

        func noteProbeClosed(readExited: Bool = false) {
            let onMain = Thread.isMainThread
            lock.withLock {
                _closeCount += 1
                _closedOnMainThread = onMain
                _readExitedBeforeClose = readExited
            }
        }
    }

    /// Parks `read()` until `testRelease()` is called so the test can verify that `probe.close()`
    /// waits for `probeTask` to unwind off-main without blocking `MainActor`.
    private final class HeldOpenReader: IOReader, @unchecked Sendable {
        private let condition = NSCondition()
        private var arrivals = 0
        private var released = false
        private var exited = false

        var entered: Bool { condition.withLock { arrivals > 0 } }
        var hasExitedRead: Bool { condition.withLock { exited } }

        func testRelease() {
            condition.withLock {
                released = true
                condition.broadcast()
            }
        }

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            condition.lock()
            defer {
                exited = true
                condition.unlock()
            }
            arrivals += 1
            let deadline = Date().addingTimeInterval(60)
            while !released, condition.wait(until: deadline) {}
            return -1
        }

        func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
        func close() {}
        func cancel() {}
        func makeIndependentReader() -> IOReader? { nil }
        var discImageProbeEnabled: Bool { false }
    }

    @Test("Stopping after probe.open finishes during audio session setup closes the probe off-main")
    func stoppedAfterProbeOpensClosesOffMain() async throws {
        let fixture = try ProbeTestFixtures.hdr10Plus()
        let engine = try AetherEngine()
        let gate = AsyncGate()
        let recorder = ProbeCloseRecorder()
        defer {
            gate.release()
            engine.audioSessionCategoryWaitForTesting = nil
            engine.probeTaskCompletedForTesting = nil
            engine.earlySupersededProbeCloseObserverForTesting = nil
            engine.stop()
        }

        engine.audioSessionCategoryWaitForTesting = { await gate.wait() }
        engine.probeTaskCompletedForTesting = { recorder.noteProbeTaskCompleted() }
        engine.earlySupersededProbeCloseObserverForTesting = { recorder.noteProbeClosed() }

        let loadTask = Task { @MainActor in
            _ = try await engine.load(source: .custom(DataIOReader(data: fixture), formatHint: "mp4"))
        }

        // Wait until the load is suspended on audio-session setup and probeTask has already returned.
        try await waitFor { gate.isWaiting && recorder.probeTaskCompleted }
        weak var weakProbe = engine.inFlightProbeDemuxer
        #expect(weakProbe != nil)
        #expect((weakProbe?.videoStreamIndex ?? -1) >= 0)

        engine.stop()
        gate.release()

        await #expect(throws: CancellationError.self) { try await loadTask.value }
        try await waitFor { recorder.closeCount == 1 && weakProbe == nil }

        #expect(recorder.closedOnMainThread == false)
        #expect(engine.inFlightProbeDemuxer == nil)
        #expect(engine.state == .idle)
        #expect(engine.errorInfo == nil)
    }

    @Test("Superseding with a second load after probe.open finishes closes the stale probe off-main")
    func supersededBySecondLoadAfterProbeOpensClosesOffMain() async throws {
        let fixture = try ProbeTestFixtures.hdr10Plus()
        let engine = try AetherEngine()
        let gate = AsyncGate()
        let recorder = ProbeCloseRecorder()
        defer {
            gate.release()
            engine.audioSessionCategoryWaitForTesting = nil
            engine.probeTaskCompletedForTesting = nil
            engine.earlySupersededProbeCloseObserverForTesting = nil
            engine.stop()
        }

        engine.audioSessionCategoryWaitForTesting = { await gate.wait() }
        engine.probeTaskCompletedForTesting = { recorder.noteProbeTaskCompleted() }
        engine.earlySupersededProbeCloseObserverForTesting = { recorder.noteProbeClosed() }

        let firstLoad = Task { @MainActor in
            _ = try await engine.load(source: .custom(DataIOReader(data: fixture), formatHint: "mp4"))
        }

        try await waitFor { gate.isWaiting && recorder.probeTaskCompleted }
        weak var weakProbe = engine.inFlightProbeDemuxer
        #expect(weakProbe != nil)
        #expect((weakProbe?.videoStreamIndex ?? -1) >= 0)

        // Let the superseding load run normally while the first load stays parked on category setup.
        engine.audioSessionCategoryWaitForTesting = nil
        engine.probeTaskCompletedForTesting = nil
        let secondProbe = try await engine.load(source: .custom(DataIOReader(data: fixture), formatHint: "mp4"))
        #expect(secondProbe != nil)

        gate.release()

        await #expect(throws: CancellationError.self) { try await firstLoad.value }
        try await waitFor { recorder.closeCount == 1 && weakProbe == nil }

        #expect(recorder.closedOnMainThread == false)
        #expect(engine.loadedURL != nil)
        #expect(engine.state != .idle)
        #expect(engine.errorInfo == nil)
    }

    @Test("Early supersession while probe.open is still blocked awaits probeTask before closing off-main")
    func supersededWhileProbeBlockedWaitsForProbeTaskBeforeClosingOffMain() async throws {
        let engine = try AetherEngine()
        let gate = AsyncGate()
        let reader = HeldOpenReader()
        let recorder = ProbeCloseRecorder()
        defer {
            reader.testRelease()
            gate.release()
            engine.audioSessionCategoryWaitForTesting = nil
            engine.earlySupersededProbeCloseObserverForTesting = nil
            engine.stop()
        }

        engine.audioSessionCategoryWaitForTesting = { await gate.wait() }
        engine.earlySupersededProbeCloseObserverForTesting = {
            recorder.noteProbeClosed(readExited: reader.hasExitedRead)
        }

        let loadTask = Task { @MainActor in
            _ = try await engine.load(source: .custom(reader, formatHint: "mpegts"))
        }

        try await waitFor { gate.isWaiting && reader.entered }
        weak var weakProbe = engine.inFlightProbeDemuxer
        #expect(weakProbe != nil)

        engine.stop()
        gate.release()

        // MainActor unwinds immediately with CancellationError while the detached close awaits probeTask.
        await #expect(throws: CancellationError.self) { try await loadTask.value }
        #expect(recorder.closeCount == 0)

        reader.testRelease()
        try await waitFor { recorder.closeCount == 1 && weakProbe == nil }

        #expect(recorder.closedOnMainThread == false)
        #expect(recorder.readExitedBeforeClose)
        #expect(engine.inFlightProbeDemuxer == nil)
        #expect(engine.state == .idle)
        #expect(engine.errorInfo == nil)
    }
}
