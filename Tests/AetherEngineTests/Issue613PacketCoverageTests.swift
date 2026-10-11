import Foundation
import AetherLibavcodec
import Testing
@testable import AetherEngine

/// #613, found while answering #592: the software VOD read-ahead's packet coverage broke in two
/// ways that both leave the frontier describing less than the store holds.
///
/// HEVC kept the strict `pts + duration` model, and a Matroska file muxed with 41 ms durations
/// against 41/42 ms deltas opens a one-tick hole at every 42 ms step: 0.70 islands a frame,
/// `bufferedPosition` stuck at the end of the current island. And a coverage that reached its range
/// cap stopped describing new packets (plain) or invalidated itself (successor model) instead of
/// forgetting the history behind the playhead.
@Suite("Software VOD packet coverage (#613)")
struct Issue613PacketCoverageTests {

    private static let tickRate: Int32 = 1000

    /// 23.976 fps on a 1/1000 time base, the fixture's own timestamps: PTS rounded to the
    /// millisecond, every duration 41, so each 42 ms delta leaves a one-tick hole.
    private static func fragmentedPTS(_ index: Int) -> Int64 {
        Int64((Double(index) * 1000 * 1001 / 24000).rounded())
    }

    private static func packet(pts: Int64, duration: Int64 = 41) -> SoftwareStoredPacket {
        SoftwareStoredPacket(pts: pts, dts: pts, duration: duration, position: 0,
                             streamIndex: 0, flags: 0x1, timeBaseNumerator: 1,
                             timeBaseDenominator: Self.tickRate,
                             bytes: Data(repeating: 7, count: 100), sideData: [])
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    }

    private func makeReadAhead(
        root: URL, reorderDepth: Int?, forwardSeconds: Double, rangeCap: Int = 4096,
        pts: @escaping @Sendable (Int) -> Int64
    ) throws -> SoftwarePacketReadAhead {
        let counter = Counter()
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 64 * 1024, retainConsumed: true,
                                              parentDirectory: root)
        return SoftwarePacketReadAhead(
            video: .init(index: 0, numerator: 1, denominator: Self.tickRate), audio: nil,
            byteBudget: 50_000_000, forwardSeconds: forwardSeconds, initialSourceClock: 0,
            fifo: fifo, videoReorderDepth: reorderDepth, coverageRangeCap: rangeCap
        ) { _ in Self.packet(pts: pts(counter.next() - 1)) }
    }

    private func withRoot<T>(_ body: (URL) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue613-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(root)
    }

    /// Waits for the producer to park, read as a packet count that stops moving.
    private func waitForPark(_ source: SoftwarePacketReadAhead) {
        let deadline = Date().addingTimeInterval(10)
        var previous = -1
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            let now = source.snapshot.packetCount
            if now == previous, now > 0 { return }
            previous = now
        }
    }

    // MARK: - 1. HEVC gets the successor model

    /// The bound that lets HEVC in: FFmpeg rejects more than 15 reorder pictures, inside the
    /// 32-timestamp queue. Codecs without an established bound keep the strict model.
    @Test("H.264 and HEVC take the successor model, other codecs keep the duration model")
    func reorderDepthByCodec() {
        #expect(SoftwarePlaybackHost.presentationReorderDepth(
            codecID: AV_CODEC_ID_H264.rawValue) == 32)
        #expect(SoftwarePlaybackHost.presentationReorderDepth(
            codecID: AV_CODEC_ID_HEVC.rawValue) == 32)
        for other in [AV_CODEC_ID_AV1, AV_CODEC_ID_VP9, AV_CODEC_ID_MPEG2VIDEO, AV_CODEC_ID_VC1] {
            #expect(SoftwarePlaybackHost.presentationReorderDepth(codecID: other.rawValue) == nil)
        }
    }

    /// The reported shape. On the duration model the frontier ends at the first rounding hole, 41 ms
    /// in; on the successor model it reaches what the producer stored before it parked.
    @Test("Rounded durations do not fragment the successor model")
    func roundedDurationsStayOneIsland() throws {
        try withRoot { root in
            let strict = try makeReadAhead(root: root, reorderDepth: nil, forwardSeconds: 10,
                                           pts: Self.fragmentedPTS)
            strict.start()
            waitForPark(strict)
            let strictFrontier = strict.snapshot.frontier
            strict.close()

            let successor = try makeReadAhead(root: root, reorderDepth: 32, forwardSeconds: 10,
                                              pts: Self.fragmentedPTS)
            successor.start()
            waitForPark(successor)
            let successorFrontier = successor.snapshot.frontier
            successor.close()

            #expect((strictFrontier ?? 0) < 0.05, "the premise: the duration model splits at 41 ms")
            // Ten seconds stored, less the 32 timestamps the reorder queue holds back (1.33 s).
            #expect((successorFrontier ?? 0) > 8, "the frontier must reach the store, not the first hole")
        }
    }

    // MARK: - 2. A full coverage forgets history instead of freezing

    /// Consumes `count` packets, moving the playhead onto each, and answers the frontier at the end.
    /// Every read waits for 40 stored packets first, the way a real consumer trails the producer:
    /// the successor model describes a picture only once 32 later timestamps have arrived, so a
    /// consumer that drains the store as fast as it fills sees no coverage at all.
    private func frontierAfterConsuming(_ count: Int, source: SoftwarePacketReadAhead) throws -> Double? {
        source.start()
        for _ in 0..<count {
            let deadline = Date().addingTimeInterval(5)
            while source.snapshot.packetCount < 40, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            guard let packet = try source.read() else { break }
            source.updatePlayhead(Double(packet.pts) / Double(Self.tickRate))
        }
        return source.snapshot.frontier
    }

    /// Duration model at a cap of 64 ranges: 400 fragmented packets are about 280 islands. Before
    /// the fix the coverage stopped at the sixty-fourth and the playhead left it behind. The cap has
    /// to hold what lies AHEAD of the playhead, about 34 islands in a two-second window here, as
    /// 4096 holds a forty-second one in a session.
    @Test("A full duration-model coverage keeps describing new packets")
    func fullDurationCoverageKeepsUp() throws {
        try withRoot { root in
            let source = try makeReadAhead(root: root, reorderDepth: nil, forwardSeconds: 2,
                                           rangeCap: 64, pts: Self.fragmentedPTS)
            defer { source.close() }
            #expect(try frontierAfterConsuming(400, source: source) != nil)
        }
    }

    /// Successor model at a cap of 16: a two-second jump every fifth picture is a real
    /// discontinuity and opens an island each time. Before the fix the seventeenth one invalidated
    /// the whole model until the next seek. 403 packets leave the playhead on the third picture of
    /// a group: the fifth one's hold ends at the jump and is deliberately uncovered.
    @Test("A full successor-model coverage keeps describing new packets")
    func fullSuccessorCoverageKeepsUp() throws {
        try withRoot { root in
            let source = try makeReadAhead(root: root, reorderDepth: 32, forwardSeconds: 30,
                                           rangeCap: 16) { index in
                Int64(index) * 40 + Int64(index / 5) * 2000
            }
            defer { source.close() }
            #expect(try frontierAfterConsuming(403, source: source) != nil)
        }
    }
}
