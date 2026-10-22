import Darwin
import Foundation

/// The software VOD packet store in purgeable memory instead of session files: tvOS's store, the
/// way AVPlayer keeps its progressive-download cache in memory there.
///
/// On an Apple TV 4K (A12) the disk store's appends took 100 to 600 ms while a download ran, and the
/// consumer's reads stalled for up to a second behind them, on the demux thread: video it already had
/// parked reached the decoder late and the layer dropped it. Here every operation is a copy under a
/// lock.
///
/// Records use the disk layout (8-byte length, then payload) in chunks of purgeable VM. A chunk the
/// consumer has finished with is history: it is made volatile, so it no longer counts against the
/// footprint and the kernel may take it back under memory pressure. Moving the reader back onto
/// history (a cached seek, a still walk) makes those chunks non-volatile again; one the kernel
/// emptied is evicted together with everything older, so the read-ahead sees a cache miss and
/// refetches. Unread data is never volatile.
///
/// `snapshot.diskByteCount` reports only non-volatile bytes, which is what the read-ahead's byte
/// budget bounds (the forward window). History is bounded separately by `historyCapBytes`.
final class SoftwarePacketMemoryFIFO: @unchecked Sendable {
    private final class Chunk {
        let id: UInt64
        let base: UnsafeMutableRawPointer
        let capacity: Int
        let kernelMayPurge: Bool
        var used = 0
        private(set) var isVolatile = false

        init(id: UInt64, capacity: Int, kernelMayPurge: Bool) throws {
            var address: vm_address_t = 0
            let size = vm_size_t(capacity)
            let kr = vm_allocate(mach_task_self_, &address, size, VM_FLAGS_ANYWHERE | VM_FLAGS_PURGABLE)
            guard kr == KERN_SUCCESS, let base = UnsafeMutableRawPointer(bitPattern: UInt(address)) else {
                throw SoftwarePacketDiskFIFO.Failure.capacityExceeded
            }
            self.id = id
            self.base = base
            self.capacity = capacity
            self.kernelMayPurge = kernelMayPurge
        }

        deinit {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: base)), vm_size_t(capacity))
        }

        /// `vm_purgable_control` operations; the header macros carry a cast and do not import.
        private static let setState: vm_purgable_t = 0

        /// Returns false when making the chunk non-volatile found it already emptied by the kernel.
        /// A chunk that cannot be made volatile simply stays resident.
        @discardableResult
        func setVolatile(_ volatile: Bool) -> Bool {
            guard volatile != isVolatile else { return true }
            if volatile, !kernelMayPurge { isVolatile = true; return true }
            var state: Int32 = volatile ? VM_PURGABLE_VOLATILE : VM_PURGABLE_NONVOLATILE
            let kr = vm_purgable_control(mach_task_self_, vm_address_t(UInt(bitPattern: base)),
                                         Self.setState, &state)
            if volatile {
                if kr == KERN_SUCCESS { isVolatile = true }
                return true
            }
            isVolatile = false
            // SET_STATE hands back the previous state.
            return kr == KERN_SUCCESS && state != VM_PURGABLE_EMPTY
        }

        private static let getState: vm_purgable_t = 1

        /// A query only: the chunk stays volatile either way.
        var isEmptied: Bool {
            guard isVolatile else { return false }
            var state: Int32 = 0
            let kr = vm_purgable_control(mach_task_self_, vm_address_t(UInt(bitPattern: base)),
                                         Self.getState, &state)
            return kr == KERN_SUCCESS && state == VM_PURGABLE_EMPTY
        }

        /// Empties the chunk now, as the kernel may once it is volatile. Works on a non-volatile
        /// region too, so it also reaches a chunk whose kernel state was kept resident. Tests only.
        func purgeForTesting() {
            var state: Int32 = VM_PURGABLE_EMPTY
            vm_purgable_control(mach_task_self_, vm_address_t(UInt(bitPattern: base)), Self.setState, &state)
        }
    }

    private let chunkTargetBytes: Int
    private let historyCapBytes: Int
    private let kernelMayPurge: Bool
    var retainsConsumedPackets: Bool { historyCapBytes > 0 }
    private let lock = NSLock()
    /// Contiguous ids, oldest first. `chunks[i].id == oldestChunkID + i`.
    private var chunks: [Chunk] = []
    private var generation = UUID()
    private var oldestChunkID: UInt64 = 0
    private var headID: UInt64 = 0
    private var headOffset = 0
    private var recordCount = 0
    private var payloadBytes = 0
    private var writtenRecordCount = 0
    private var writtenPayloadBytes = 0
    private var isClosed = false
    private var failure: (any Error)?
    /// History chunks found emptied by the kernel. Diagnostics and tests.
    private(set) var purgedChunks = 0

    /// `kernelMayPurge: false` keeps history resident at the kernel level while every count and
    /// state transition still treats it as volatile, so only `purgeHistoryForTesting` empties it.
    /// Tests that re-read history use it; otherwise memory pressure from the rest of the suite can
    /// purge that history first.
    init(chunkTargetBytes: Int = 4 << 20, historyCapBytes: Int, kernelMayPurge: Bool = true) {
        let page = Int(getpagesize())
        self.chunkTargetBytes = max(page, (chunkTargetBytes + page - 1) / page * page)
        self.historyCapBytes = max(0, historyCapBytes)
        self.kernelMayPurge = kernelMayPurge
    }

    var snapshot: SoftwarePacketDiskFIFO.Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return SoftwarePacketDiskFIFO.Snapshot(
            count: recordCount, byteCount: payloadBytes, diskByteCount: nonVolatileBytesLocked(),
            chunkCount: chunks.count, oldestRetainedChunkID: chunks.isEmpty ? nil : oldestChunkID,
            isClosed: isClosed, hasFailure: failure != nil)
    }

    @discardableResult
    func append(_ data: Data) throws -> SoftwarePacketDiskFIFO.Cursor {
        lock.lock()
        defer { lock.unlock() }
        try requireUsable()
        let recordBytes = data.count + 8
        do {
            if chunks.isEmpty || chunks[chunks.count - 1].capacity - chunks[chunks.count - 1].used < recordBytes {
                let page = Int(getpagesize())
                let capacity = max(chunkTargetBytes, (recordBytes + page - 1) / page * page)
                let id = chunks.isEmpty ? oldestChunkID : chunks[chunks.count - 1].id + 1
                if chunks.isEmpty { headID = id; headOffset = 0 }
                chunks.append(try Chunk(id: id, capacity: capacity, kernelMayPurge: kernelMayPurge))
            }
        } catch {
            failure = error
            throw error
        }
        let tail = chunks[chunks.count - 1]
        let cursor = SoftwarePacketDiskFIFO.Cursor(
            chunkID: tail.id, generation: generation, offset: UInt64(tail.used),
            recordIndex: writtenRecordCount, payloadPrefix: writtenPayloadBytes)
        var length = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &length) { tail.base.advanced(by: tail.used).copyMemory(from: $0.baseAddress!, byteCount: 8) }
        data.withUnsafeBytes { raw in
            if let src = raw.baseAddress { tail.base.advanced(by: tail.used + 8).copyMemory(from: src, byteCount: data.count) }
        }
        tail.used += recordBytes
        recordCount += 1
        payloadBytes += data.count
        writtenRecordCount += 1
        writtenPayloadBytes += data.count
        return cursor
    }

    func pop() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        try requireUsable()
        guard recordCount > 0 else { return nil }
        var head = try chunkLocked(headID)
        if headOffset == head.used, headID < tailIDLocked {
            head.setVolatile(true)
            headID += 1
            headOffset = 0
            head = try chunkLocked(headID)
        }
        guard head.used - headOffset >= 8 else { throw fail(.corruptRecord) }
        var length: UInt64 = 0
        withUnsafeMutableBytes(of: &length) { $0.copyMemory(from: UnsafeRawBufferPointer(start: head.base.advanced(by: headOffset), count: 8)) }
        length = UInt64(littleEndian: length)
        guard length <= UInt64(payloadBytes), Int(length) <= head.used - headOffset - 8 else {
            throw fail(.corruptRecord)
        }
        let data = Data(bytes: head.base.advanced(by: headOffset + 8), count: Int(length))
        headOffset += 8 + Int(length)
        recordCount -= 1
        payloadBytes -= Int(length)
        if headOffset == head.used, headID < tailIDLocked {
            head.setVolatile(true)
            headID += 1
            headOffset = 0
        }
        return data
    }

    /// Moves only the consumer cursor. History between the cursor and the old head becomes unread
    /// again and is made non-volatile; if the kernel emptied any of it the cursor is refused
    /// (`invalidCursor`) and the read-ahead takes its normal uncached path.
    func restore(to cursor: SoftwarePacketDiskFIFO.Cursor) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireUsable()
        try validateLocked(cursor)
        // Checked before any chunk changes state: a refused cursor must not leave unread chunks
        // volatile in front of the reader.
        guard Int(cursor.offset) + 8 <= (try chunkLocked(cursor.chunkID)).used else {
            throw SoftwarePacketDiskFIFO.Failure.invalidCursor
        }
        if cursor.chunkID < headID {
            try reclaimLocked(from: cursor.chunkID, through: headID - 1)
        } else {
            // Forward within stored data: what the reader skips becomes history.
            var id = headID
            while id < cursor.chunkID { try chunkLocked(id).setVolatile(true); id += 1 }
        }
        headID = cursor.chunkID
        headOffset = Int(cursor.offset)
        recordCount = writtenRecordCount - cursor.recordIndex
        payloadBytes = writtenPayloadBytes - cursor.payloadPrefix
    }

    /// AE#605 still walk. Copies one chunk's records at a time under the lock and visits them
    /// outside it; a walk that raced a reset or an eviction throws `invalidCursor` after visiting,
    /// like the disk store.
    func readHistory(from cursor: SoftwarePacketDiskFIFO.Cursor, visit: (Data) throws -> Bool) throws {
        lock.lock()
        do {
            try requireUsable()
            try validateLocked(cursor)
        } catch { lock.unlock(); throw error }
        let walkGeneration = generation
        lock.unlock()

        var id = cursor.chunkID
        var offset = Int(cursor.offset)
        walk: while true {
            lock.lock()
            guard generation == walkGeneration, !isClosed, id >= oldestChunkID, id <= tailIDLocked else {
                lock.unlock()
                throw SoftwarePacketDiskFIFO.Failure.invalidCursor
            }
            let isLast = id == tailIDLocked
            var records: [Data] = []
            do {
                let chunk = try chunkLocked(id)
                let wasVolatile = chunk.isVolatile
                if wasVolatile, !chunk.setVolatile(false) {
                    // The catch below releases the lock.
                    evictPurgedLocked(through: id)
                    throw SoftwarePacketDiskFIFO.Failure.invalidCursor
                }
                while chunk.used - offset >= 8 {
                    var length: UInt64 = 0
                    withUnsafeMutableBytes(of: &length) { $0.copyMemory(from: UnsafeRawBufferPointer(start: chunk.base.advanced(by: offset), count: 8)) }
                    length = UInt64(littleEndian: length)
                    guard Int(length) <= chunk.used - offset - 8 else { throw SoftwarePacketDiskFIFO.Failure.corruptRecord }
                    records.append(Data(bytes: chunk.base.advanced(by: offset + 8), count: Int(length)))
                    offset += 8 + Int(length)
                }
                if wasVolatile, id < headID { chunk.setVolatile(true) }
            } catch { lock.unlock(); throw error }
            lock.unlock()
            for record in records where try !visit(record) { break walk }
            if isLast { break }
            id += 1
            offset = 0
        }
        lock.lock()
        let stillValid = generation == walkGeneration && !isClosed
        lock.unlock()
        guard stillValid else { throw SoftwarePacketDiskFIFO.Failure.invalidCursor }
    }

    /// History beyond `historyCapBytes` is dropped, oldest first. The argument (the disk store's
    /// residency budget) does not apply: in memory the read-ahead's budget bounds the non-volatile
    /// forward window through `snapshot`. History the kernel emptied is not looked for here, since
    /// this runs on every read and it costs nothing while it waits: `restore` and `readHistory`
    /// find it when they reclaim a chunk, and the cap retires it in turn.
    func trimConsumed(toByteBudget budget: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireUsable()
        var history = chunks.reduce(0) { $0 + ($1.id < headID ? $1.used : 0) }
        while history > historyCapBytes, let oldest = chunks.first, oldest.id < headID {
            chunks.removeFirst()
            oldestChunkID = oldest.id + 1
            history -= oldest.used
        }
    }

    /// Evicts history the kernel has emptied, up to the newest emptied chunk. Without it the store
    /// learns of a purge only when a restore walks into it, and published residency (#759) would
    /// keep claiming history that is already gone. Returns whether anything was evicted.
    func evictPurgedHistory() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let newest = chunks.last(where: { $0.id < headID && $0.isEmptied })?.id else { return false }
        evictPurgedLocked(through: newest)
        return true
    }

    /// Empties every volatile history chunk now, as the kernel may under memory pressure. Tests only.
    func purgeHistoryForTesting() {
        lock.lock()
        defer { lock.unlock() }
        for chunk in chunks where chunk.isVolatile { chunk.purgeForTesting() }
    }

    func reset() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { throw SoftwarePacketDiskFIFO.Failure.closed }
        clearLocked()
        failure = nil
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        isClosed = true
        chunks.removeAll()
    }

    // MARK: - Private

    private var tailIDLocked: UInt64 { chunks.last?.id ?? oldestChunkID }

    private func chunkLocked(_ id: UInt64) throws -> Chunk {
        guard id >= oldestChunkID, Int(id - oldestChunkID) < chunks.count else {
            throw fail(.corruptRecord)
        }
        return chunks[Int(id - oldestChunkID)]
    }

    private func validateLocked(_ cursor: SoftwarePacketDiskFIFO.Cursor) throws {
        guard cursor.generation == generation, !chunks.isEmpty,
              cursor.chunkID >= oldestChunkID, cursor.chunkID <= tailIDLocked,
              cursor.recordIndex >= 0, cursor.recordIndex < writtenRecordCount,
              cursor.payloadPrefix >= 0, cursor.payloadPrefix <= writtenPayloadBytes else {
            throw SoftwarePacketDiskFIFO.Failure.invalidCursor
        }
    }

    /// Makes history chunks `first...last` non-volatile for re-reading. If the kernel emptied any,
    /// everything up to the newest emptied one is evicted and the cursor is refused.
    private func reclaimLocked(from first: UInt64, through last: UInt64) throws {
        var newestPurged: UInt64?
        var id = first
        while id <= last {
            if !(try chunkLocked(id).setVolatile(false)) { newestPurged = id }
            id += 1
        }
        guard let newestPurged else { return }
        evictPurgedLocked(through: newestPurged)
        // What survived stays history until a later restore succeeds.
        for chunk in chunks where chunk.id < headID { chunk.setVolatile(true) }
        throw SoftwarePacketDiskFIFO.Failure.invalidCursor
    }

    /// Never evicts the reader's chunk or anything after it.
    private func evictPurgedLocked(through id: UInt64) {
        while let oldest = chunks.first, oldest.id <= id, oldest.id < headID {
            chunks.removeFirst()
            oldestChunkID = oldest.id + 1
            purgedChunks += 1
        }
    }

    private func nonVolatileBytesLocked() -> Int {
        chunks.reduce(0) { $0 + ($1.isVolatile ? 0 : $1.used) }
    }

    private func requireUsable() throws {
        guard !isClosed else { throw SoftwarePacketDiskFIFO.Failure.closed }
        if let failure { throw failure }
    }

    private func fail(_ error: SoftwarePacketDiskFIFO.Failure) -> SoftwarePacketDiskFIFO.Failure {
        failure = error
        return error
    }

    private func clearLocked() {
        chunks.removeAll()
        generation = UUID()
        oldestChunkID = 0
        headID = 0
        headOffset = 0
        recordCount = 0
        payloadBytes = 0
        writtenRecordCount = 0
        writtenPayloadBytes = 0
    }
}

extension SoftwarePacketMemoryFIFO: SoftwarePacketStore {}
