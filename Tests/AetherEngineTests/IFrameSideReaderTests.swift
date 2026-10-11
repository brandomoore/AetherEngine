// Tests/AetherEngineTests/IFrameSideReaderTests.swift
import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
}
private func fixtureExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: fixtureURL(name).path)
}

/// Every keyframe of the fixture's video stream as (pts-or-dts index timestamp, bytes), read
/// linearly on an independent demuxer: the reference the side reader is checked against.
private func referenceKeyframes(_ name: String) throws -> (index: [Int64], packets: [Int64: Data]) {
    let dem = Demuxer()
    try dem.open(url: fixtureURL(name))
    defer { dem.close() }
    let video = dem.videoStreamIndex
    var packets: [Int64: Data] = [:]
    while let pkt = try dem.readPacket() {
        var owned: UnsafeMutablePointer<AVPacket>? = pkt
        defer { av_packet_free(&owned) }
        guard pkt.pointee.stream_index == video, (pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0,
              let bytes = pkt.pointee.data else { continue }
        let data = Data(bytes: bytes, count: Int(pkt.pointee.size))
        packets[pkt.pointee.dts] = data
        packets[pkt.pointee.pts] = data
    }
    return (dem.indexedKeyframes(streamIndex: video).sorted(), packets)
}

@Suite("I-frame side reader", .serialized)
struct IFrameSideReaderTests {
    private func reader(_ name: String) -> IFrameSideReader {
        IFrameSideReader(open: { dem in
            try dem.open(url: fixtureURL(name), profile: .iFrameSideDemuxer)
        })
    }

    /// mp4 indexes its keyframes by DTS and Matroska by PTS (`PlanBoundaryAxis`), so both containers
    /// are read: the side reader must return the segment's own keyframe on either ladder.
    @Test("the payload at an indexed keyframe is that keyframe, in any request order",
          arguments: ["restart-witness-av.mp4", "restart-witness-subs.mkv"])
    func readsTheIndexedKeyframe(fixture: String) throws {
        guard fixtureExists(fixture) else { return }
        let ref = try referenceKeyframes(fixture)
        try #require(ref.index.count >= 2, "\(fixture) needs at least two indexed keyframes")
        let r = reader(fixture)
        defer { r.interrupt(); r.close() }
        for ts in ref.index.prefix(3).reversed() {
            let payload = try #require(r.payload(startPts: ts))
            #expect(payload == ref.packets[ts], "\(fixture): keyframe at \(ts) differs")
        }
    }

    @Test("a failed open is retried only after its cool-down, which grows with the second failure")
    func failedOpenIsRetriedAfterItsCoolDown() {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000); var opens = 0 }
        let clock = Clock()
        let r = IFrameSideReader(open: { _ in
            clock.opens += 1
            throw NSError(domain: "test", code: 1)
        }, now: { clock.now })
        defer { r.interrupt(); r.close() }
        #expect(r.payload(startPts: 0) == nil)
        #expect(r.payload(startPts: 100) == nil)
        #expect(clock.opens == 1, "five parallel requests must not each pay for an open")
        clock.now += 6
        #expect(r.payload(startPts: 0) == nil)
        #expect(clock.opens == 2)
        clock.now += 6
        #expect(r.payload(startPts: 0) == nil)
        #expect(clock.opens == 2, "the second failure in a row holds for 30 s")
        clock.now += 30
        #expect(r.payload(startPts: 0) == nil)
        #expect(clock.opens == 3)
    }

    @Test("a failed read cools down, then reopens a fresh demuxer and recovers",
          .enabled(if: fixtureExists("restart-witness-av.mp4")))
    func failedReadReopens() throws {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000); var opens = 0 }
        let clock = Clock()
        let ref = try referenceKeyframes("restart-witness-av.mp4")
        let r = IFrameSideReader(open: { dem in
            clock.opens += 1
            try dem.open(url: fixtureURL("restart-witness-av.mp4"), profile: .iFrameSideDemuxer)
        }, now: { clock.now })
        defer { r.interrupt(); r.close() }
        #expect(r.payload(startPts: ref.index[0]) != nil)
        // Far past the end: no keyframe to land on, which is what a dead connection looks like here.
        #expect(r.payload(startPts: Int64.max / 4) == nil)
        #expect(r.payload(startPts: ref.index[0]) == nil, "inside the cool-down the source is left alone")
        #expect(clock.opens == 1)
        clock.now += 6
        #expect(r.payload(startPts: ref.index[0]) == ref.packets[ref.index[0]])
        #expect(clock.opens == 2)
    }

    @Test("cleanup runs exactly once on close, opened or not")
    func cleanupRunsOnce() {
        final class Count: @unchecked Sendable { var n = 0 }
        let untouched = Count()
        let never = IFrameSideReader(open: { _ in }, cleanup: { untouched.n += 1 })
        never.interrupt(); never.close(); never.close()
        #expect(untouched.n == 1)
    }

    @Test("after interrupt every call answers nil",
          .enabled(if: fixtureExists("restart-witness-av.mp4")))
    func interruptEndsIt() throws {
        let ref = try referenceKeyframes("restart-witness-av.mp4")
        let r = reader("restart-witness-av.mp4")
        #expect(r.payload(startPts: ref.index[0]) != nil)
        r.interrupt()
        #expect(r.payload(startPts: ref.index[0]) == nil)
        r.close()
    }

    @Test("the I-frame side profile reads like the still extractor under its own log name")
    func profile() {
        let p = DemuxerOpenProfile.iFrameSideDemuxer
        #expect(p.readerLabel == "iframe")
        #expect(p.avioPrefetch == DemuxerOpenProfile.stillExtraction.avioPrefetch)
        #expect(p.probesize == DemuxerOpenProfile.stillExtraction.probesize)
        #expect(DemuxerOpenProfile.labelsWithoutCompositionRepair.contains("iframe"))
        #expect(DemuxerOpenProfile.labelsWithoutCompositionRepair.contains("extract"))
    }

    @Test("interrupt aborts an open that is still in flight", .timeLimit(.minutes(3)))
    func interruptAbortsAnOpenInFlight() {
        let parked = ProbeParkedReader(operation: .read)
        parked.mayReturn.open()
        let entered = DispatchSemaphore(value: 0)
        let r = IFrameSideReader(open: { dem in
            entered.signal()
            try dem.open(reader: parked, formatHint: "mp4", profile: .iFrameSideDemuxer)
        })
        let done = DispatchSemaphore(value: 0)
        // A thread of its own: a loaded runner starves the global pool for seconds.
        Thread.detachNewThread { _ = r.payload(startPts: 0); done.signal() }
        entered.wait()
        Thread.sleep(forTimeInterval: 0.2)
        r.interrupt()
        let returned = done.wait(timeout: .now() + 120) == .success
        #expect(returned, "payload() was still inside the open 120 seconds after interrupt()")
        parked.release()
        if !returned { done.wait() }
        r.close()
    }
}
