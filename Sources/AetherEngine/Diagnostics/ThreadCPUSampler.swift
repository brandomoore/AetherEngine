import Foundation
import Darwin.Mach

/// CPU time per thread between two samples, grouped by thread name.
///
/// The memprobe says how much memory a session holds and where, and nothing about where the time
/// goes. A field report of "4K stutters on an A10X while Infuse plays it" could only be answered with
/// Instruments on a box we own, and the box that stutters is never that box. This turns every log a
/// reporter sends into a coarse profile: which threads burned how much of a core over the window.
///
/// **It reports consumed CPU TIME, not the scheduler's instantaneous `cpu_usage`.** That figure is a
/// decaying estimate of the last moments, so a 30 s cadence would sample noise. The deltas here are
/// exact: the task's total includes threads that ended inside the window (`MACH_TASK_BASIC_INFO`
/// carries their time), and whatever the live threads do not account for is printed as `(ended)`.
///
/// Percentages are of ONE core, so a figure above 100 means more than one core was busy. Thread
/// names come from `pthread_setname_np` / dispatch queue labels; unnamed workqueue threads collapse
/// into `(unnamed)`, and a trailing counter (`conn.31`) is folded so a pool reads as one group.
public final class ThreadCPUSampler: @unchecked Sendable {

    public struct Group: Sendable, Equatable {
        public let name: String
        public let threads: Int
        /// Share of one core over the interval.
        public let percent: Double
    }

    public struct Report: Sendable {
        public let intervalSeconds: Double
        /// Whole process, including threads that ended inside the window.
        public let totalPercent: Double
        public let mainPercent: Double
        public let threadCount: Int
        /// Descending by `percent`. The main thread is not in here, it has its own field.
        public let groups: [Group]

        /// `cpu=87% main=6% threads=42 top=HLSSegmentProducer.pump:29 (unnamed)[18]:52 ...`
        public func logFragment(limit: Int = 6) -> String {
            let top = groups.prefix(limit).map { group in
                let count = group.threads > 1 ? "[\(group.threads)]" : ""
                return "\(group.name)\(count):\(Self.format(group.percent))"
            }
            return "cpu=\(Self.format(totalPercent))% main=\(Self.format(mainPercent))% "
                + "threads=\(threadCount) top=\(top.joined(separator: " "))"
        }

        static func format(_ percent: Double) -> String {
            percent >= 10 ? String(format: "%.0f", percent) : String(format: "%.1f", percent)
        }
    }

    struct ThreadTime {
        let id: UInt64
        let name: String
        let nanoseconds: UInt64
    }

    private let lock = NSLock()
    private var previous: (uptime: UInt64, ended: UInt64, perThread: [UInt64: UInt64])?
    private let mainThreadID: UInt64

    /// Main-actor bound because that is how it learns which thread is the main one.
    @MainActor public init() {
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        mainThreadID = id
    }

    /// The first call only primes the baseline and returns nil.
    public func sample() -> Report? {
        guard let ended = Self.endedThreadsNanoseconds(),
              let threads = Self.liveThreads() else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        defer {
            previous = (now, ended, threads.reduce(into: [:]) { $0[$1.id] = $1.nanoseconds })
        }
        guard let previous, now > previous.uptime else { return nil }
        return Self.report(
            threads: threads, ended: ended, now: now,
            previous: previous, mainThreadID: mainThreadID)
    }

    static func report(threads: [ThreadTime], ended: UInt64, now: UInt64,
                       previous: (uptime: UInt64, ended: UInt64, perThread: [UInt64: UInt64]),
                       mainThreadID: UInt64) -> Report {
        let interval = Double(now - previous.uptime)
        func percent(_ ns: UInt64) -> Double { Double(ns) / interval * 100 }

        var liveDelta: UInt64 = 0
        var mainDelta: UInt64 = 0
        var buckets: [String: (threads: Int, ns: UInt64)] = [:]
        for thread in threads {
            let before = previous.perThread[thread.id] ?? 0
            let delta = thread.nanoseconds >= before ? thread.nanoseconds - before : 0
            liveDelta += delta
            if thread.id == mainThreadID {
                mainDelta = delta
                continue
            }
            let key = groupName(thread.name)
            let bucket = buckets[key] ?? (0, 0)
            buckets[key] = (bucket.threads + 1, bucket.ns + delta)
        }
        let previousLive = previous.perThread.values.reduce(0, +)
        let liveNow = threads.reduce(UInt64(0)) { $0 + $1.nanoseconds }
        let totalNow = liveNow + ended
        let totalBefore = previousLive + previous.ended
        let total = totalNow > totalBefore ? totalNow - totalBefore : 0
        if total > liveDelta { buckets["(ended)"] = (0, total - liveDelta) }
        let groups = buckets
            .map { Group(name: $0.key, threads: $0.value.threads, percent: percent($0.value.ns)) }
            .sorted { $0.percent != $1.percent ? $0.percent > $1.percent : $0.name < $1.name }
        return Report(
            intervalSeconds: interval / 1e9,
            totalPercent: percent(total),
            mainPercent: percent(mainDelta),
            threadCount: threads.count,
            groups: groups)
    }

    /// Folds a pool's trailing counter (`com.aetherengine.hls.conn.31`, `av:hevc:df1`) so its
    /// threads read as one group.
    static func groupName(_ name: String) -> String {
        guard !name.isEmpty else { return "(unnamed)" }
        var trimmed = Substring(name)
        while let last = trimmed.last, last.isNumber { trimmed.removeLast() }
        if trimmed.count < name.count, let last = trimmed.last, last == "." || last == " " || last == "-" {
            trimmed.removeLast()
        }
        return trimmed.isEmpty ? name : String(trimmed)
    }

    /// User + system time of threads that have already terminated, in nanoseconds.
    static func endedThreadsNanoseconds() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return nanoseconds(info.user_time) + nanoseconds(info.system_time)
    }

    static func liveThreads() -> [ThreadTime]? {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return nil }
        defer {
            for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[index]) }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var result: [ThreadTime] = []
        result.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            if let thread = threadTime(list[index]) { result.append(thread) }
        }
        return result
    }

    private static func threadTime(_ port: thread_act_t) -> ThreadTime? {
        var identifier = thread_identifier_info_data_t()
        var identifierCount = mach_msg_type_number_t(
            MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<integer_t>.size)
        let idResult = withUnsafeMutablePointer(to: &identifier) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(identifierCount)) {
                thread_info(port, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identifierCount)
            }
        }
        var extended = thread_extended_info_data_t()
        var extendedCount = mach_msg_type_number_t(
            MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<integer_t>.size)
        let extResult = withUnsafeMutablePointer(to: &extended) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(extendedCount)) {
                thread_info(port, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &extendedCount)
            }
        }
        guard idResult == KERN_SUCCESS, extResult == KERN_SUCCESS else { return nil }
        let name = withUnsafeBytes(of: extended.pth_name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return ThreadTime(
            id: identifier.thread_id, name: name,
            nanoseconds: extended.pth_user_time + extended.pth_system_time)
    }

    private static func nanoseconds(_ time: time_value_t) -> UInt64 {
        UInt64(time.seconds) * 1_000_000_000 + UInt64(time.microseconds) * 1_000
    }
}
