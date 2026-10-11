import XCTest
@testable import AetherEngine

final class SoftwareDVRRetentionTests: XCTestCase {
    private func ring(cap: Int) throws -> PacketRingBuffer {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try PacketRingBuffer(windowSeconds: 300, scratch: directory, retention: .init(startupMaximumBytes: cap, playbackCushionBytes: 8 << 20, playbackCushionSeconds: 2))
    }

    func testDefaultSpoolDoesNotOptInToHostRetention() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ring = try PacketRingBuffer(windowSeconds: 300, scratch: directory)
        defer { ring.close() }
        XCTAssertFalse(ring.setLimits(.init(windowSeconds: nil, maximumBytes: 0, minimumFreeBytes: 0),
                                      availableBytes: nil))
        try ring.append(pts: 0, isKeyframe: true, isVideo: true, bytes: Data([1]))
        XCTAssertEqual(ring.retainedBytes, 1)
        XCTAssertEqual(ring.retainedWindowSeconds, 300)
    }

    func testActualPayloadEvictsWholeGOPsAndKeepsFeederAdvancing() throws {
        let ring = try ring(cap: 12)
        defer { ring.close() }
        for i in 0..<60 {
            try ring.append(pts: Double(i), isKeyframe: i.isMultiple(of: 3), isVideo: true,
                            bytes: Data(repeating: UInt8(i), count: 2))
            XCTAssertLessThanOrEqual(ring.retainedBytes, 12)
            let bounds = ring.seqBounds
            let first = try XCTUnwrap(ring.packet(atSeq: bounds.first))
            XCTAssertTrue(first.isKeyframe)
            XCTAssertEqual(ring.packet(atSeq: bounds.end - 1)?.pts, Double(i))
        }
        XCTAssertGreaterThan(ring.seqBounds.first, 0)
        XCTAssertEqual(ring.retainedBytes, 12)
    }

    func testOversizedGOPCannotEscapeCapAndNextKeyframeRecovers() throws {
        let ring = try ring(cap: 4)
        defer { ring.close() }
        try ring.append(pts: 0, isKeyframe: true, isVideo: true, bytes: Data([0, 0]))
        try ring.append(pts: 1, isKeyframe: false, isVideo: true, bytes: Data([1, 1, 1]))
        XCTAssertEqual(ring.retainedBytes, 0)
        try ring.append(pts: 2, isKeyframe: false, isVideo: true, bytes: Data([2]))
        XCTAssertEqual(ring.retainedBytes, 0)
        try ring.append(pts: 3, isKeyframe: true, isVideo: true, bytes: Data([3]))
        XCTAssertEqual(ring.packet(atSeq: ring.seqBounds.first)?.pts, 3)
        // A single oversized packet is rejected before it is written.
        try ring.append(pts: 4, isKeyframe: true, isVideo: true, bytes: Data(repeating: 4, count: 5))
        XCTAssertEqual(ring.retainedBytes, 0)
    }

    func testDeniedAndExpiredCapacityRemoveHistoryButKeepBoundedLiveFeeding() throws {
        for expired in [false, true] {
            let ring = try ring(cap: 32 * 1024 * 1024)
            defer { ring.close() }
            let packet = Data(repeating: 1, count: 1024 * 1024)
            for i in 0..<20 {
                try ring.append(pts: Double(i), isKeyframe: true, isVideo: true, bytes: packet)
            }
            XCTAssertEqual(ring.retainedBytes, 20 * packet.count)
            ring.setLimits(.init(windowSeconds: 300, maximumBytes: 32 * 1024 * 1024,
                                 minimumFreeBytes: 128 * 1024 * 1024,
                                 capacityValidUntil: expired ? -1 : nil),
                           availableBytes: expired ? 1024 * 1024 * 1024 : 0)
            for i in 20..<30 {
                try ring.append(pts: Double(i), isKeyframe: true, isVideo: true, bytes: packet)
                XCTAssertLessThanOrEqual(ring.retainedBytes, 8 << 20)
                XCTAssertEqual(ring.packet(atSeq: ring.seqBounds.end - 1)?.pts, Double(i))
            }
            XCTAssertNil(ring.retainedWindowSeconds)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(ring.oldestPts), 27)
        }
    }

    func testEvictionRemovesActualFilesNotJustAccounting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ring = try PacketRingBuffer(windowSeconds: 300, scratch: directory, retention: .init(startupMaximumBytes: 12, playbackCushionBytes: 8 << 20, playbackCushionSeconds: 2))
        defer { ring.close() }
        for i in 0..<40 {
            try ring.append(pts: Double(i), isKeyframe: i.isMultiple(of: 2), isVideo: true,
                            bytes: Data(repeating: 1, count: 2))
        }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let diskBytes = try urls.reduce(0) { sum, url in
            sum + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        XCTAssertEqual(diskBytes, ring.retainedBytes)
        XCTAssertLessThanOrEqual(diskBytes, 12)
    }

    func testClosedRingCannotBeResurrectedByLateAppend() throws {
        let ring = try ring(cap: 4)
        ring.close()
        try ring.append(pts: 0, isKeyframe: true, isVideo: true, bytes: Data([1]))
        XCTAssertEqual(ring.retainedBytes, 0)
        XCTAssertEqual(ring.seqBounds.first, ring.seqBounds.end)
    }
}
