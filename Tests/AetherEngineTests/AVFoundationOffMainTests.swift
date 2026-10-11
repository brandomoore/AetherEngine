import Foundation
import Testing
import AVFoundation
@testable import AetherEngine

/// #134: shared hop that runs batched synchronous AVFoundation property reads on a
/// caller-owned serial queue instead of the main actor.
@MainActor
struct AVFoundationOffMainTests {

    @Test("body runs off the main thread and the value round-trips")
    func bodyRunsOffMain() async {
        let queue = DispatchQueue(label: "test.avfread")
        let player = AVPlayer()
        let wasOffMain = await AVFoundationOffMain.read(player, on: queue) { player -> Bool in
            _ = player.rate
            return !Thread.isMainThread
        }
        #expect(wasOffMain)
    }

    @Test("a blocked body must not block the main actor", .timeLimit(.minutes(3)))
    func blockedBodyKeepsMainActorResponsive() async {
        let queue = DispatchQueue(label: "test.avfread.stall")
        let release = DispatchSemaphore(value: 0)
        let player = AVPlayer()
        let finished = AtomicBool(false)
        // Barrier, not a measurement: the body may only end at the signal below, which the main
        // actor can only send if this read left it free. A wall-clock cap here would release the
        // body on its own under CI starvation and answer the question the test is asking (see
        // Issue254OffMainRepositionTests); a genuinely blocked main actor never signals at any size,
        // so the honest report of that regression is the trait's time limit. The defer covers an
        // early exit.
        defer { release.signal() }
        let read = Task { @MainActor in
            _ = await AVFoundationOffMain.read(player, on: queue) { _ -> Bool in
                release.wait()
                return true
            }
            finished.set(true)
        }
        for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(finished.get() == false)

        release.signal()
        await read.value
        #expect(finished.get())
    }

    /// The queue-less carrier is for callers that bound their own admission. It must not hand the
    /// body to GCD or to the cooperative pool: a concurrent queue stops starting work once the
    /// global pool is saturated, and the cooperative pool is capped at the core count and never
    /// overcommits, so either one turns a stranded media server into a stalled process. Asserted on
    /// the carrier rather than on the clock, because a saturation test would have to saturate the
    /// pool for every other test running beside it.
    @Test("the queue-less read runs on a thread of its own, not on a pool")
    func threadCarrierLeavesBothPoolsFree() async {
        let player = AVPlayer()
        let carrier = await AVFoundationOffMain.read(player) { player -> (Bool, Bool, String) in
            _ = player.rate
            return (Thread.isMainThread,
                    withUnsafeCurrentTask { $0 != nil },
                    Thread.current.name ?? "")
        }
        #expect(!carrier.0, "a figplayer read must never run on the main thread")
        #expect(!carrier.1, "a blocking read must not occupy a cooperative worker")
        #expect(carrier.2 == "com.aetherengine.avfoundation.read",
                "the body ran on a pool worker instead of its own thread: \(carrier.2)")
    }

    /// Two lanes, so at most two threads, and each lane on a thread of its own. The lane bound is
    /// asserted together with the carrier on purpose: the pool counting its own admission is the
    /// whole reason it may skip the queue, so a change that put these reads back on a shared
    /// concurrent queue has to fail here rather than pass on an unrelated carrier test.
    @Test("the diagnostics pool reads on two lanes, each on its own thread", .timeLimit(.minutes(3)))
    func poolAdmitsTwoLanesOffThePool() async throws {
        let pool = ItemDiagnosticReadPool.withoutReadTimeout()
        let counter = LaneCounter()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var readers: [AVPlayerItemDiagnostics] = []
        for _ in 0..<4 {
            let reader = AVPlayerItemDiagnostics(item: AVPlayerItem(url: URL(string: "https://example.invalid/a.m3u8")!),
                                                 pool: pool) { _, _ in
                counter.begin(on: Thread.current.name ?? "")
                defer { counter.end() }
                release.wait()
                return ItemDiagnosticSnapshot()
            }
            readers.append(reader)
            reader.request(.counters)
        }
        try await waitFor { counter.active == ItemDiagnosticReadPool.maximumConcurrentReads }
        #expect(counter.maximum == ItemDiagnosticReadPool.maximumConcurrentReads)
        for _ in 0..<8 { release.signal() }
        try await waitFor { counter.finished == 4 }
        #expect(counter.maximum == ItemDiagnosticReadPool.maximumConcurrentReads,
                "the lane bound is the bound on parked threads")
        #expect(counter.carriers == ["com.aetherengine.avfoundation.read"],
                "a lane ran on a pool worker instead of its own thread: \(counter.carriers)")
        readers.removeAll()
    }
}

private final class LaneCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private var highWater = 0
    private var done = 0
    private var seen: Set<String> = []

    func begin(on carrier: String) {
        lock.lock()
        running += 1
        highWater = max(highWater, running)
        seen.insert(carrier)
        lock.unlock()
    }

    func end() {
        lock.lock()
        running -= 1
        done += 1
        lock.unlock()
    }

    var active: Int { lock.lock(); defer { lock.unlock() }; return running }
    var maximum: Int { lock.lock(); defer { lock.unlock() }; return highWater }
    var finished: Int { lock.lock(); defer { lock.unlock() }; return done }
    var carriers: Set<String> { lock.lock(); defer { lock.unlock() }; return seen }
}

/// #134 follow-up: seekable-end mapping used by the host's KVO mirror of
/// `seekableTimeRanges`, replacing per-call synchronous reads at clock-tick cadence.
struct NativeAVPlayerHostSeekableEndTests {

    @Test("empty ranges map to 0")
    func emptyRanges() {
        #expect(NativeAVPlayerHost.seekableEnd(from: []) == 0)
    }

    @Test("end of the last range wins")
    func lastRangeEnd() {
        let ranges = [
            NSValue(timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 1))),
            NSValue(timeRange: CMTimeRange(start: CMTime(value: 20, timescale: 1),
                                           duration: CMTime(value: 15, timescale: 1))),
        ]
        #expect(NativeAVPlayerHost.seekableEnd(from: ranges) == 35)
    }

    @Test("non-finite end maps to 0")
    func nonFiniteEnd() {
        let ranges = [NSValue(timeRange: CMTimeRange(start: .zero, duration: .indefinite))]
        #expect(NativeAVPlayerHost.seekableEnd(from: ranges) == 0)
    }
}
