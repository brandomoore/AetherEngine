// Tests/AetherEngineTests/Issue684PumpJoinSpentTests.swift
// AE#684: "the join has nothing more to give" is a fact the reader states, and the seal on every
// ingest start hangs on it. Two ways it was wrong or untested:
//
// - It was read off the VIDEO reader alone. With a demuxed audio rendition the cutter merges two
//   readers on one thread and parks on whichever runs dry first. A rendition whose segments end 0.2 s
//   before the video's runs dry first every time, the video reader is never parked, and the fact never
//   became true: measured on a three-segment window as the full seal over a window that cannot hold it,
//   2.17 to 2.24 s to first picture under `.fastZap` and 10.4 to 10.7 s under `.standard`, against
//   0.18 to 0.20 s on 7.25.1.
// - It was only ever tested through a provider fake. These drive the reader itself against a loopback
//   origin whose responses the test releases by hand, so nothing here depends on how long a sleep is.
import XCTest
@testable import AetherEngine

/// Loopback origin: a master, a video and an audio media playlist of three 6 s segments each, and
/// TS-shaped segment bodies. A path named in `hold` is answered only once `release` names it.
private final class HeldSegmentOrigin: @unchecked Sendable {
    let port: UInt16
    private let listener: LoopbackListener
    private let lock = NSCondition()
    private var held: Set<String>
    private var stopped = false

    static let segmentBytes = 4 * 188

    init?(hold: Set<String>) {
        held = hold
        guard let listener = LoopbackListener(backlog: 16) else { return nil }
        self.listener = listener
        port = listener.port
        listener.start { [weak self] conn in
            guard let self else { close(conn); return false }
            Thread.detachNewThread { [weak self] in self?.serve(conn) }
            return true
        }
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(path)")! }

    func release(_ path: String) {
        lock.lock()
        held.remove(path)
        lock.broadcast()
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        held.removeAll()
        lock.broadcast()
        lock.unlock()
        listener.stop()
    }

    private func mediaPlaylist(prefix: String) -> Data {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:6", "#EXT-X-MEDIA-SEQUENCE:0"]
        for index in 0..<3 {
            lines.append("#EXTINF:6.000,")
            lines.append("\(prefix)\(index).ts")
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func segment(tag: UInt8) -> Data {
        var data = Data(capacity: Self.segmentBytes)
        for packet in 0..<4 {
            var ts = [UInt8](repeating: tag, count: 188)
            ts[0] = 0x47
            ts[1] = UInt8(packet)
            data.append(contentsOf: ts)
        }
        return data
    }

    private func serve(_ conn: Int32) {
        defer { close(conn) }
        var request = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = read(conn, &buf, buf.count)
            guard n > 0 else { return }
            request.append(contentsOf: buf[0..<n])
            if request.count > 64 * 1024 { return }
        }
        guard let head = String(data: request, encoding: .utf8),
              let line = head.components(separatedBy: "\r\n").first else { return }
        let parts = line.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        let path = String(parts[1].dropFirst())

        lock.lock()
        while held.contains(path), !stopped { lock.wait() }
        lock.unlock()

        let body: Data
        switch path {
        case "master.m3u8":
            body = Data("""
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="de",LANGUAGE="de",DEFAULT=YES,AUTOSELECT=YES,URI="a.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1800000,CODECS="avc1.4d401e,mp4a.40.2",RESOLUTION=720x576,AUDIO="a"
            v.m3u8

            """.utf8)
        case "v.m3u8": body = mediaPlaylist(prefix: "v")
        case "a.m3u8": body = mediaPlaylist(prefix: "a")
        default:
            guard path.hasSuffix(".ts"), let index = Int(path.dropFirst(1).dropLast(3)) else {
                let missing = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                _ = missing.withCString { write(conn, $0, strlen($0)) }
                return
            }
            body = segment(tag: UInt8(truncatingIfNeeded: (path.hasPrefix("a") ? 100 : 0) + index))
        }
        let header = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        _ = header.withCString { write(conn, $0, strlen($0)) }
        body.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(conn, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard n > 0 else { return }
                offset += n
            }
        }
    }
}

/// Reads a reader on a thread of its own, optionally stopping at a byte budget WITHOUT parking (a
/// consumer that holds what it has and asks for no more, like the cutter's lookahead).
private final class ReaderDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var _bytes = 0
    var bytes: Int { lock.lock(); defer { lock.unlock() }; return _bytes }

    init(_ reader: IOReader, stopAfter budget: Int? = nil) {
        Thread.detachNewThread { [self] in
            var buf = [UInt8](repeating: 0, count: 64)
            while true {
                if let budget, bytes >= budget { return }
                let want = budget.map { min(buf.count, $0 - bytes) } ?? buf.count
                let n = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: Int32(want)) }
                if n <= 0 { return }
                lock.lock()
                _bytes += Int(n)
                lock.unlock()
            }
        }
    }
}

final class Issue684PumpJoinSpentTests: XCTestCase {

    private func waitUntil(_ what: String, timeout: TimeInterval = 300, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return XCTFail("timed out waiting for: \(what)") }
            usleep(2_000)
        }
    }

    // MARK: - The rule

    func testVideoOnlyIsTheVideoReaderParkedOnACommittedJoin() {
        XCTAssertTrue(HLSLiveIngestReader.pumpJoinIsSpent(main: (true, true), companion: nil))
        XCTAssertFalse(HLSLiveIngestReader.pumpJoinIsSpent(main: (true, false), companion: nil))
        XCTAssertFalse(HLSLiveIngestReader.pumpJoinIsSpent(main: (false, true), companion: nil),
                       "parked between two segments of a join still arriving")
    }

    /// The reported shape: the audio rendition ends before the video does, so the cutter parks on
    /// the AUDIO reader while video bytes are still queued. That is a spent join.
    func testShortAudioParksTheCutterOnTheCompanion() {
        XCTAssertTrue(HLSLiveIngestReader.pumpJoinIsSpent(
            main: (committed: true, parked: false), companion: (started: true, committed: true, parked: true)))
    }

    /// The audio playlist publishes a little after the video one, so at the join the companion's
    /// batch is still arriving while the cutter already sits on an empty reader.
    func testAudioPublishedLaterIsNotSpentUntilItsOwnJoinIsCommitted() {
        XCTAssertFalse(HLSLiveIngestReader.pumpJoinIsSpent(
            main: (true, true), companion: (started: true, committed: false, parked: false)))
        XCTAssertFalse(HLSLiveIngestReader.pumpJoinIsSpent(
            main: (true, false), companion: (started: true, committed: false, parked: true)),
            "parked on the companion between two of its join segments")
        XCTAssertTrue(HLSLiveIngestReader.pumpJoinIsSpent(
            main: (true, true), companion: (started: true, committed: true, parked: false)))
    }

    func testACompanionNobodyReadsDoesNotCount() {
        XCTAssertTrue(HLSLiveIngestReader.pumpJoinIsSpent(
            main: (true, true), companion: (started: false, committed: false, parked: false)))
    }

    func testBothCommittedAndNeitherParkedIsACutterStillWorking() {
        XCTAssertFalse(HLSLiveIngestReader.pumpJoinIsSpent(
            main: (true, false), companion: (started: true, committed: true, parked: false)))
    }

    // MARK: - The reader itself

    /// A consumer parked on an empty reader is not a spent join while the join batch is still being
    /// fetched: the third segment is held at the origin, the reader has drained the first two and
    /// waits, and the fact has to stay false until that segment is committed and drained too.
    func testReaderIsNotSpentWhileItsJoinBatchIsStillArriving() throws {
        let origin = try XCTUnwrap(HeldSegmentOrigin(hold: ["v2.ts"]))
        defer { origin.stop() }
        let reader = HLSLiveIngestReader(playlistURL: origin.url("v.m3u8"))
        defer { reader.close() }
        XCTAssertFalse(reader.joinIsSpent, "nothing has been read")

        let drain = ReaderDrain(reader)
        let two = 2 * HeldSegmentOrigin.segmentBytes
        waitUntil("two segments drained and the consumer parked") {
            drain.bytes == two && reader.pumpJoinState.parked
        }
        XCTAssertFalse(reader.pumpJoinState.committed)
        XCTAssertFalse(reader.joinIsSpent, "empty and parked, but the join is not all here")

        origin.release("v2.ts")
        waitUntil("the join to be spent") { reader.joinIsSpent }
        XCTAssertEqual(drain.bytes, 3 * HeldSegmentOrigin.segmentBytes)
        XCTAssertTrue(reader.pumpJoinState.committed)
    }

    /// Demuxed audio, the reported shape: the cutter holds video it cannot place and waits on the
    /// audio reader. The video reader is never parked.
    func testReaderWithACompanionIsSpentWhenTheCutterParksOnTheAudio() throws {
        let origin = try XCTUnwrap(HeldSegmentOrigin(hold: []))
        defer { origin.stop() }
        let reader = HLSLiveIngestReader(playlistURL: origin.url("master.m3u8"))
        defer { reader.close() }

        // The video side takes one segment and asks for no more: two stay queued, nobody is parked.
        let video = ReaderDrain(reader, stopAfter: HeldSegmentOrigin.segmentBytes)
        waitUntil("the companion to be installed") { reader.companionAudioReader != nil }
        waitUntil("the video join to be committed") { reader.pumpJoinState.committed }
        waitUntil("the video side to stop") { video.bytes == HeldSegmentOrigin.segmentBytes }
        XCTAssertFalse(reader.pumpJoinState.parked)
        XCTAssertFalse(reader.joinIsSpent, "video queued, nobody waiting, audio not yet read")

        let companion = try XCTUnwrap(reader.companionAudioReader)
        let audio = ReaderDrain(companion)
        waitUntil("the join to be spent on the audio side") { reader.joinIsSpent }
        XCTAssertEqual(audio.bytes, 3 * HeldSegmentOrigin.segmentBytes)
        XCTAssertFalse(reader.pumpJoinState.parked, "the video reader never parked, and it did not have to")
    }

    /// Audio published a moment after video: the cutter has drained the video and parked on it
    /// while the audio rendition's last join segment is still at the origin.
    func testReaderWithACompanionWaitsForTheAudioJoinToBeCommitted() throws {
        let origin = try XCTUnwrap(HeldSegmentOrigin(hold: ["a2.ts"]))
        defer { origin.stop() }
        let reader = HLSLiveIngestReader(playlistURL: origin.url("master.m3u8"))
        defer { reader.close() }

        let video = ReaderDrain(reader)
        waitUntil("the companion to be installed") { reader.companionAudioReader != nil }
        let companion = try XCTUnwrap(reader.companionAudioReader)
        let audio = ReaderDrain(companion)
        let three = 3 * HeldSegmentOrigin.segmentBytes
        waitUntil("the video drained and parked, the audio parked two segments in") {
            video.bytes == three && reader.pumpJoinState.parked
                && audio.bytes == 2 * HeldSegmentOrigin.segmentBytes
        }
        XCTAssertFalse(reader.joinIsSpent, "the audio rendition's join is not all here")

        origin.release("a2.ts")
        waitUntil("the join to be spent") { reader.joinIsSpent }
        XCTAssertEqual(audio.bytes, three)
    }

    // MARK: - The gate asks in the right order

    /// The fact is monotone, so a snapshot taken AFTER it read true holds everything the join will
    /// cut. Taken before, the cutter can append its last segment and park between the two reads and
    /// the seal is paid from the sum without it. A race two reads wide is not something a policy
    /// test can stage, so this reads the site, as `Issue588RefusalLatchLifetimeTests` does.
    func testTheGateAsksSpentBeforeItTakesTheSnapshot() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine/Video/VideoSegmentProvider.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let gateStart = try XCTUnwrap(text.range(of: "func waitForFirstLiveSegment(timeout: TimeInterval) -> Bool {"))
        let gateEnd = try XCTUnwrap(text.range(of: "private func accountForFirstServe(",
                                               range: gateStart.upperBound..<text.endIndex))
        let lines = text[gateStart.upperBound..<gateEnd.lowerBound]
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let snapshots = lines.indices.filter { lines[$0].contains("= liveCushionSnapshot()") }
        XCTAssertEqual(snapshots.count, 2, "the loop's read and the timed-out re-read")
        for index in snapshots {
            XCTAssertTrue(lines[index - 1].contains("liveCadencePolicy?.joinIsSpent"),
                          "snapshot at gate line \(index) is not preceded by the spent read: \(lines[index - 1])")
        }
    }
}
