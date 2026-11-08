import Foundation
import Testing
@testable import AetherEngine

@MainActor
struct NativeMediaSelectionReaderTests {
    @Test("an empty selection is a successful off-main read", .timeLimit(.minutes(1)))
    func emptySelection() async {
        let reader = NativeMediaSelectionReader()
        let offMain = AtomicBool(false)
        let result = await reader.read((), timeout: 5) { _ in
            offMain.set(!Thread.isMainThread && withUnsafeCurrentTask { $0 == nil })
            return .init(option: nil)
        }
        #expect(offMain.get())
        #expect(result != nil)
        #expect(result?.option == nil)
    }

    @Test("timeouts keep blocked lanes occupied and late results cannot replace timeout", .timeLimit(.minutes(1)))
    func blockedReadsStayBounded() async throws {
        let reader = NativeMediaSelectionReader()
        let release = DispatchSemaphore(value: 0)
        let entered = AtomicBool(false)
        let returned = AtomicBool(false)
        defer { release.signal(); release.signal() }
        let first = Task {
            await reader.read((), timeout: 0.1) { _ in
                entered.set(true)
                release.wait()
                returned.set(true)
                return .init(option: nil)
            }
        }
        try await waitFor { entered.get() }
        #expect(await first.value == nil)
        #expect(!returned.get(), "The UI waiter returned while the native getter was still blocked.")
        let second = await reader.read((), timeout: 0.1) { _ in
            release.wait()
            return .init(option: nil)
        }
        #expect(second == nil)
        let admitted = AtomicBool(false)
        for _ in 0..<10 {
            let result = await reader.read((), timeout: 0.1) { _ in
                admitted.set(true)
                return .init(option: nil)
            }
            #expect(result == nil)
        }
        #expect(!admitted.get(), "A timeout cannot admit another parked thread.")
        release.signal()
        release.signal()
        try await waitFor { returned.get() }
        try await waitFor {
            await reader.read((), timeout: 5) { _ in .init(option: nil) } != nil
        }
    }

    @Test("cancelled callers neither query nor consume a late result", .timeLimit(.minutes(1)))
    func cancelledRead() async throws {
        let reader = NativeMediaSelectionReader()
        let entered = AtomicBool(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let task = Task {
            await reader.read((), timeout: 5) { _ in
                entered.set(true)
                release.wait()
                return .init(option: nil)
            }
        }
        try await waitFor { entered.get() }
        task.cancel()
        release.signal()
        #expect(await task.value == nil)
        let queried = AtomicBool(false)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await reader.read((), timeout: 5) { _ in
                queried.set(true)
                return .init(option: nil)
            }
        }
        #expect(await cancelled.value == nil)
        #expect(!queried.get())
    }

    @Test("the documented selection limits match the reader")
    func documentedBounds() {
        #expect(NativeMediaSelectionReader.maximumConcurrentReads == 2)
        #expect(NativeMediaSelectionReader.defaultTimeout == 0.5)
    }
}
