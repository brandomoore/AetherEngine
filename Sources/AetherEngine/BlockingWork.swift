import Foundation

/// Where engine work that blocks its thread runs: a demuxer open, a packet read, a FIFO write
/// under backpressure, a `close()` that joins a pump, a `waitForFinish`.
///
/// `Task.detached` is no background thread. It runs on the Swift cooperative pool, which has one
/// thread per core and never grows, so every blocked job takes a core's worth of async work out
/// of the whole process, the host app's included. On a 3-core CI runner the test suite parked
/// all three for half a minute at a time (a 120 s time limit fired at 151 s, because the
/// watchdog is a task on the same pool), and an Apple TV has few more cores than that.
///
/// A task created here prefers `BlockingExecutor`, which runs its jobs on GCD's global queues.
/// Those add a thread when one blocks in the kernel, which is the whole difference. The task is
/// otherwise an ordinary one: it awaits, hops to the main actor and back, and is cancelled like
/// any other.
enum BlockingWork {
    @discardableResult
    static func detached<Success: Sendable>(
        priority: TaskPriority? = nil,
        operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never> {
        if #available(visionOS 2, *) {
            return Task.detached(executorPreference: BlockingExecutor.shared, priority: priority, operation: operation)
        }
        return Task.detached(priority: priority, operation: operation)
    }

    @discardableResult
    static func detached<Success: Sendable>(
        priority: TaskPriority? = nil,
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) -> Task<Success, any Error> {
        if #available(visionOS 2, *) {
            return Task.detached(executorPreference: BlockingExecutor.shared, priority: priority, operation: operation)
        }
        return Task.detached(priority: priority, operation: operation)
    }
}

/// Runs each job on the GCD global queue that matches its priority. Stateless and shared, so a
/// task's preference never outlives what it points at.
@available(visionOS 2, *)
final class BlockingExecutor: TaskExecutor {
    static let shared = BlockingExecutor()

    func enqueue(_ job: consuming ExecutorJob) {
        let qos = Self.qos(for: job.priority)
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        DispatchQueue.global(qos: qos).async {
            job.runSynchronously(on: executor)
        }
    }

    static func qos(for priority: JobPriority) -> DispatchQoS.QoSClass {
        switch TaskPriority(rawValue: priority.rawValue) {
        case .high: return .userInitiated
        case .medium: return .default
        case .low: return .utility
        case .background: return .background
        default: return priority.rawValue > TaskPriority.high.rawValue ? .userInteractive : .default
        }
    }
}
