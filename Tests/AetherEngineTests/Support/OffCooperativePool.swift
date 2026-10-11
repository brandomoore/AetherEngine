import Testing
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
