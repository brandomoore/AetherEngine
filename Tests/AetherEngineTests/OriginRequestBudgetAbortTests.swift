import Testing
import Foundation
@testable import AetherEngine

/// Audit DMX-112: a pump parked in `OriginRequestBudget.acquire` ignored `markClosed()`, so a torn
/// down session stayed in the origin's FIFO and in the race for the next pacer token, and could take
/// the very slot the new session was waiting for. `shouldAbort` is polled once per slice in both
/// waits, and an aborted caller consumes nothing.
@Suite("Origin request budget abort", .serialized)
struct OriginRequestBudgetAbortTests {

    @Test("a strict metadata caller never overcommits a full origin on timeout")
    func strictSlotTimeout() {
        let budget = OriginRequestBudget()
        budget.setHostLimit(1, for: url)
        let held = budget.acquire(for: url, label: "holder", timeout: 1)
        defer { budget.release(held) }
        let refused = budget.acquire(for: url, label: "metadata", timeout: 0.01, allowOvercommit: false)
        #expect(refused == nil)
        #expect(budget.snapshot(for: url)?.inflight == 1)
        #expect(budget.snapshot(for: url)?.peakInflight == 1)
        #expect(budget.snapshot(for: url)?.waiting == 0)
    }

    private let url = URL(string: "https://abort.example.com:443/movie.mkv")!

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool { lock.withLock { _value } }
        func set() { lock.withLock { _value = true } }
    }

    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var _done = false
        private var _ticket: OriginRequestBudget.Ticket?
        var done: Bool { lock.withLock { _done } }
        var ticket: OriginRequestBudget.Ticket? { lock.withLock { _ticket } }
        func finish(_ ticket: OriginRequestBudget.Ticket?) { lock.withLock { _ticket = ticket; _done = true } }
    }

    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var nanoseconds: UInt64 = 1_000_000_000
        func now() -> DispatchTime { lock.withLock { DispatchTime(uptimeNanoseconds: nanoseconds) } }
        func advance(by seconds: TimeInterval) {
            lock.withLock { nanoseconds += UInt64((seconds * 1_000_000_000).rounded()) }
        }
    }

    @Test("a caller parked for a slot leaves on abort without taking or holding one",
          .timeLimit(.minutes(3)))
    func slotWaitAborts() async throws {
        let budget = OriginRequestBudget()
        budget.setHostLimit(1, for: url)
        let held = budget.acquire(for: url, label: "holder", timeout: 1)
        let abort = Flag()
        let outcome = Result()
        let target = url
        Thread.detachNewThread {
            // 120 s: the abort, not this budget, is what must end the wait.
            outcome.finish(budget.acquire(for: target, label: "pump", timeout: 120,
                                          shouldAbort: { abort.value }))
        }
        try await waitFor { budget.snapshot(for: url)?.waiting == 1 }

        abort.set()
        try await waitFor { outcome.done }
        #expect(outcome.ticket == nil, "an aborted acquire must not hand out a ticket")
        #expect(budget.snapshot(for: url)?.waiting == 0, "the aborted caller left the FIFO")
        #expect(budget.snapshot(for: url)?.inflight == 1, "only the holder is on the books")

        // The slot the holder gives back goes to the next caller, not to a waiter that left.
        budget.release(held)
        let next = budget.acquire(for: url, label: "next", timeout: 1)
        #expect(next?.granted == true)
        #expect(next?.waitedMs == 0)
        budget.release(next)
        #expect(budget.snapshot(for: url)?.inflight == 0)
    }

    @Test("a caller parked for the pacer leaves on abort and leaves the tokens alone",
          .timeLimit(.minutes(3)))
    func pacerWaitAborts() async throws {
        let clock = ManualClock()
        let budget = OriginRequestBudget(now: clock.now)
        budget.noteRefusal(for: url, status: 429)
        let abort = Flag()
        let outcome = Result()
        let target = url
        Thread.detachNewThread {
            outcome.finish(budget.acquire(for: target, label: "pump", timeout: 120,
                                          shouldAbort: { abort.value }))
        }
        try await waitFor { budget.snapshot(for: url)?.paced == true && budget.snapshot(for: url)?.inflight == 0 }

        abort.set()
        try await waitFor { outcome.done }
        #expect(outcome.ticket == nil)
        #expect(budget.snapshot(for: url)?.inflight == 0, "an aborted caller is not on the link")

        // The bucket holds its full burst of two once the quiet period has passed: the aborted
        // caller consumed none of it.
        clock.advance(by: 4)
        for _ in 0..<2 {
            let ticket = budget.tryAcquire(for: url, label: "next")
            #expect(ticket?.granted == true, "a token went to the caller that had left")
            budget.release(ticket)
        }
    }

    @Test("an abort that is already set returns before anything is taken")
    func abortBeforeTheWait() {
        let budget = OriginRequestBudget()
        #expect(budget.acquire(for: url, label: "pump", timeout: 1, shouldAbort: { true }) == nil)
        #expect(budget.snapshot(for: url) == nil, "nothing was counted for an aborted caller")
    }

    @Test("a caller that is never aborted waits and is granted as before")
    func noAbortKeepsTheOldBehaviour() async throws {
        let budget = OriginRequestBudget()
        budget.setHostLimit(1, for: url)
        let held = budget.acquire(for: url, label: "holder", timeout: 1)
        let outcome = Result()
        let target = url
        Thread.detachNewThread {
            outcome.finish(budget.acquire(for: target, label: "pump", timeout: 120,
                                          shouldAbort: { false }))
        }
        try await waitFor { budget.snapshot(for: url)?.waiting == 1 }
        budget.release(held)
        try await waitFor { outcome.done }
        #expect(outcome.ticket?.granted == true)
        budget.release(outcome.ticket)
        #expect(budget.snapshot(for: url)?.inflight == 0)
    }

    @Test("pacerOnly overcommit grants a free concurrency slot after pacer timeout")
    func pacerOnlyGrantsFreeConcurrencySlotAfterPacerTimeout() {
        let clock = ManualClock()
        let budget = OriginRequestBudget(now: clock.now)
        budget.noteRefusal(for: url, status: 429)

        let ticket = budget.acquire(for: url, label: "paced", timeout: 0.02, overcommit: .pacerOnly)
        #expect(ticket?.granted == true)
        #expect(budget.snapshot(for: url)?.inflight == 1)
        budget.release(ticket)
        #expect(budget.snapshot(for: url)?.inflight == 0)

        // Also verify when one slot is already held below a multi-slot limit.
        let multiBudget = OriginRequestBudget(now: clock.now)
        multiBudget.setHostLimit(2, for: url)
        let held = multiBudget.acquire(for: url, label: "holder", timeout: 1)
        defer { multiBudget.release(held) }
        multiBudget.noteRefusal(for: url, status: 429)

        let second = multiBudget.acquire(for: url, label: "second", timeout: 0.02, overcommit: .pacerOnly)
        #expect(second?.granted == true)
        #expect(multiBudget.snapshot(for: url)?.inflight == 2)
        #expect(multiBudget.snapshot(for: url)?.peakInflight == 2)
        multiBudget.release(second)
        #expect(multiBudget.snapshot(for: url)?.inflight == 1)
    }

    @Test("pacerOnly overcommit returns nil when concurrency limit is full")
    func pacerOnlyRefusesWhenConcurrencyLimitIsFull() {
        // Unpaced saturated origin.
        let unpaced = OriginRequestBudget()
        unpaced.setHostLimit(1, for: url)
        let unpacedHeld = unpaced.acquire(for: url, label: "holder", timeout: 1)
        defer { unpaced.release(unpacedHeld) }
        let unpacedRefused = unpaced.acquire(
            for: url, label: "caller", timeout: 0.02, overcommit: .pacerOnly
        )
        #expect(unpacedRefused == nil)
        #expect(unpaced.snapshot(for: url)?.inflight == 1)
        #expect(unpaced.snapshot(for: url)?.peakInflight == 1)
        #expect(unpaced.snapshot(for: url)?.waiting == 0)

        // Paced AND saturated origin.
        let clock = ManualClock()
        let paced = OriginRequestBudget(now: clock.now)
        paced.setHostLimit(1, for: url)
        let pacedHeld = paced.acquire(for: url, label: "holder", timeout: 1)
        defer { paced.release(pacedHeld) }
        paced.noteRefusal(for: url, status: 429)

        let pacedRefused = paced.acquire(
            for: url, label: "caller", timeout: 0.02, overcommit: .pacerOnly
        )
        #expect(pacedRefused == nil)
        #expect(paced.snapshot(for: url)?.inflight == 1)
        #expect(paced.snapshot(for: url)?.peakInflight == 1)
        #expect(paced.snapshot(for: url)?.waiting == 0)
    }

    @Test("AbortSignal wakes parked slot and pacer waits immediately without leaking slots",
          .timeLimit(.minutes(3)))
    func abortSignalWakesSlotAndPacerWaitsImmediately() async throws {
        let target = url

        // 1. Concurrency-slot wait with 120 s timeout wakes immediately on abortSignal.abort().
        let slotBudget = OriginRequestBudget()
        slotBudget.setHostLimit(1, for: target)
        let held = slotBudget.acquire(for: target, label: "holder", timeout: 1)
        let slotSignal = OriginRequestBudget.AbortSignal()
        let slotOutcome = Result()
        Thread.detachNewThread {
            slotOutcome.finish(slotBudget.acquire(
                for: target, label: "waiter", timeout: 120, abortSignal: slotSignal
            ))
        }
        try await waitFor { slotBudget.snapshot(for: target)?.waiting == 1 }

        slotSignal.abort()
        try await waitFor { slotOutcome.done }
        #expect(slotOutcome.ticket == nil)
        #expect(slotBudget.snapshot(for: target)?.waiting == 0)
        #expect(slotBudget.snapshot(for: target)?.inflight == 1)

        slotBudget.release(held)
        let next = slotBudget.acquire(for: target, label: "next", timeout: 1)
        #expect(next?.granted == true)
        #expect(next?.waitedMs == 0)
        slotBudget.release(next)
        #expect(slotBudget.snapshot(for: target)?.inflight == 0)

        // 2. Pacer wait with 120 s timeout wakes immediately on abortSignal.abort() without consuming tokens.
        let clock = ManualClock()
        let pacerBudget = OriginRequestBudget(now: clock.now)
        pacerBudget.noteRefusal(for: target, status: 429)
        let pacerSignal = OriginRequestBudget.AbortSignal()
        let pacerOutcome = Result()
        Thread.detachNewThread {
            pacerOutcome.finish(pacerBudget.acquire(
                for: target, label: "waiter", timeout: 120, abortSignal: pacerSignal
            ))
        }
        try await waitFor {
            pacerBudget.snapshot(for: target)?.paced == true
                && pacerBudget.snapshot(for: target)?.inflight == 0
        }

        pacerSignal.abort()
        try await waitFor { pacerOutcome.done }
        #expect(pacerOutcome.ticket == nil)
        #expect(pacerBudget.snapshot(for: target)?.inflight == 0)

        clock.advance(by: 4)
        for _ in 0..<2 {
            let tokenTicket = pacerBudget.tryAcquire(for: target, label: "next")
            #expect(tokenTicket?.granted == true)
            pacerBudget.release(tokenTicket)
        }

        // 3. Back-to-back release() and abort() returns the handed-off slot cleanly rather than leaking it.
        let raceBudget = OriginRequestBudget()
        raceBudget.setHostLimit(1, for: target)
        let raceHeld = raceBudget.acquire(for: target, label: "holder", timeout: 1)
        let raceSignal = OriginRequestBudget.AbortSignal()
        let raceOutcome = Result()
        Thread.detachNewThread {
            raceOutcome.finish(raceBudget.acquire(
                for: target, label: "waiter", timeout: 120, abortSignal: raceSignal
            ))
        }
        try await waitFor { raceBudget.snapshot(for: target)?.waiting == 1 }

        raceBudget.release(raceHeld)
        raceSignal.abort()
        try await waitFor { raceOutcome.done }
        #expect(raceOutcome.ticket == nil)
        #expect(raceBudget.snapshot(for: target)?.waiting == 0)
        #expect(raceBudget.snapshot(for: target)?.inflight == 0)

        let postRace = raceBudget.acquire(for: target, label: "post-race", timeout: 1)
        #expect(postRace?.granted == true)
        raceBudget.release(postRace)
        #expect(raceBudget.snapshot(for: target)?.inflight == 0)
    }
}
