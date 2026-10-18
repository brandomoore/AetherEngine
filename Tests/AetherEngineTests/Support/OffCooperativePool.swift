import Testing
import Foundation
@testable import AetherEngine

/// Runs a test's body on `BlockingExecutor` instead of the Swift cooperative pool.
///
/// For tests that block their thread on purpose: they drive a synchronous engine API (an
/// `AVIOReader` open or read, a gate that parks, a FIFO), or park on a server of their own. On the
/// pool each of those holds one of only as many threads as there are cores, and on a 3-core CI
/// runner a handful of them at once starved every other test, the time-limit watchdogs included.
/// A sync test runs where its caller runs, so preferring the executor here moves the whole body.
struct OffCooperativePoolTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { return try await function() }
        if #available(visionOS 2, *) {
            try await withTaskExecutorPreference(BlockingExecutor.shared) { try await function() }
        } else {
            try await function()
        }
    }
}

extension Trait where Self == OffCooperativePoolTrait {
    static var offCooperativePool: Self { Self() }
}

/// `.offCooperativePool`, and one test case at a time across every suite that carries it.
///
/// For suites whose cases are long CPU or GPU loops rather than parked threads (the Dolby Vision
/// composer and fuzz suites). Off the pool they no longer starve the one-thread CI job, but
/// `BlockingExecutor` adds a thread per blocked job, so on their own they all ran at once and
/// took the 3-core runner from the timing tests beside them. One lane keeps them to one core.
/// The time a case waits for the lane counts against its `.timeLimit`, so a suite of short
/// deadlock watchdogs (`DoviComposeAsyncTests`) takes the plain trait instead, and a suite that
/// carries this one sets no `.timeLimit` under five minutes: on CI a one-line test waited 71 s here.
struct OneLaneOffCooperativePoolTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { return try await function() }
        await OneLane.shared.acquire()
        defer { OneLane.shared.release() }
        try await OffCooperativePoolTrait().provideScope(for: test, testCase: testCase, performing: function)
    }
}

extension Trait where Self == OneLaneOffCooperativePoolTrait {
    static var offCooperativePoolOneLane: Self { Self() }
}

private final class OneLane: @unchecked Sendable {
    static let shared = OneLane()
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { (turn: CheckedContinuation<Void, Never>) in
            lock.lock()
            if busy {
                waiters.append(turn)
                lock.unlock()
            } else {
                busy = true
                lock.unlock()
                turn.resume()
            }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            busy = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}
