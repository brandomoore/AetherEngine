import Darwin
import Foundation
import Testing
@testable import AetherEngine

@Suite("Live startup fast path", .offCooperativePool, .timeLimit(.minutes(3)))
struct LiveStartupFastPathTests {

    // MARK: - Loopback helper

    /// Minimal HTTP/1.1 loopback origin for live open tests. Can either deliver a finite body and
    /// close, or deliver an initial prefix and hold the socket open until `stop()` so `AVIOReader`
    /// only sees the exact leading chunk during `open()`.
    private final class LivePrefixOrigin: @unchecked Sendable {
        struct Response: Sendable {
            var status: Int = 200
            var contentType: String = "video/mp2t"
            var body: Data
            var includeContentLength: Bool = true
            var holdOpenAfterBody: Bool = false
        }

        let port: UInt16
        private let listener: LoopbackListener
        private let respond: @Sendable (_ path: String) -> Response
        private let lock = NSLock()
        private var stopped = false
        private var connections: Set<Int32> = []
        private var holdSemaphores: [DispatchSemaphore] = []

        init?(respond: @escaping @Sendable (_ path: String) -> Response) {
            self.respond = respond
            guard let listener = LoopbackListener(backlog: 16) else { return nil }
            self.listener = listener
            self.port = listener.port
            listener.start { [self] fd in admit(fd) }
        }

        func url(_ path: String) throws -> URL {
            try #require(URL(string: "http://127.0.0.1:\(port)\(path)"))
        }

        func stop() {
            lock.lock()
            let alreadyStopped = stopped
            stopped = true
            let held = holdSemaphores
            holdSemaphores.removeAll()
            let active = connections
            lock.unlock()
            for sem in held { sem.signal() }
            for fd in active { shutdown(fd, SHUT_RDWR) }
            guard !alreadyStopped else { return }
            listener.stop()
        }

        private func admit(_ fd: Int32) -> Bool {
            lock.lock()
            if stopped {
                lock.unlock()
                close(fd)
                return false
            }
            connections.insert(fd)
            lock.unlock()
            Thread.detachNewThread { [self] in serve(fd) }
            return true
        }

        private func serve(_ fd: Int32) {
            defer {
                lock.lock()
                connections.remove(fd)
                close(fd)
                lock.unlock()
            }
            var request = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while request.range(of: Data("\r\n\r\n".utf8)) == nil {
                let n = recv(fd, &buf, buf.count, 0)
                guard n > 0, request.count < 64 * 1024 else { return }
                request.append(buf, count: n)
            }
            let firstLine = String(decoding: request, as: UTF8.self)
                .components(separatedBy: "\r\n").first ?? ""
            let target = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = String(target.split(separator: "?", maxSplits: 1).first ?? "/")
            let response = respond(path)

            var header = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Status")\r\n"
            header += "Content-Type: \(response.contentType)\r\n"
            if response.includeContentLength {
                header += "Content-Length: \(response.body.count)\r\n"
            }
            header += "Connection: close\r\n\r\n"
            guard writeAll(fd, Data(header.utf8)), writeAll(fd, response.body) else { return }

            if response.holdOpenAfterBody {
                let sem = DispatchSemaphore(value: 0)
                let shouldWait: Bool = lock.withLock {
                    guard !stopped else { return false }
                    holdSemaphores.append(sem)
                    return true
                }
                if shouldWait { sem.wait() }
            }
        }

        private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return true }
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, base.advanced(by: offset), raw.count - offset)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { return false }
                    offset += n
                }
                return true
            }
        }
    }

    private static func makeTSPackets(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0x00, count: count * 188)
        for packet in 0..<count {
            bytes[packet * 188] = 0x47
        }
        return bytes
    }

    private static func makeM2TSPackets(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0x00, count: count * 192)
        for packet in 0..<count {
            bytes[packet * 192 + 4] = 0x47
        }
        return bytes
    }

    private static func wrapAsM2TS(_ ts: Data) -> Data {
        let packetCount = ts.count / 188
        var out = Data(capacity: packetCount * 192)
        let arrivalHeader: [UInt8] = [0x00, 0x00, 0x00, 0x00]
        for packet in 0..<packetCount {
            let start = packet * 188
            out.append(contentsOf: arrivalHeader)
            out.append(ts[start..<(start + 188)])
        }
        return out
    }

    // MARK: - Sync-byte prefix verification unit tests

    @Test("bodyBeginsWithMPEGTS accepts aligned 188-byte TS and 192-byte M2TS prefixes")
    func mpegtsPrefixAcceptsAlignedTSAndM2TS() {
        // 188-byte TS: minimum 2 sync markers (189 bytes) and 2 full packets (376 bytes).
        var minTS = [UInt8](repeating: 0x11, count: 189)
        minTS[0] = 0x47
        minTS[188] = 0x47
        #expect(AVIOReader.bodyBeginsWithMPEGTS(minTS))
        #expect(AVIOReader.bodyBeginsWithMPEGTS(Self.makeTSPackets(count: 2)))

        // 188-byte TS: 3 sync markers (exact 377 bytes, 7-packet UDP/TS chunk, and real fixture).
        var threeSyncTS = [UInt8](repeating: 0x22, count: 377)
        threeSyncTS[0] = 0x47
        threeSyncTS[188] = 0x47
        threeSyncTS[376] = 0x47
        #expect(AVIOReader.bodyBeginsWithMPEGTS(threeSyncTS))
        #expect(AVIOReader.bodyBeginsWithMPEGTS(Self.makeTSPackets(count: 7)))
        #expect(AVIOReader.bodyBeginsWithMPEGTS(Array(TinyTransportStreamFixture.data.prefix(AVIOReader.openSniffBytes))))

        // 192-byte M2TS: minimum 2 sync markers (197 bytes) and 2 full packets (384 bytes).
        var minM2TS = [UInt8](repeating: 0x33, count: 197)
        minM2TS[4] = 0x47
        minM2TS[196] = 0x47
        #expect(AVIOReader.bodyBeginsWithMPEGTS(minM2TS))
        #expect(AVIOReader.bodyBeginsWithMPEGTS(Self.makeM2TSPackets(count: 2)))

        // 192-byte M2TS: 3 sync markers (exact 389 bytes and 3 full packets).
        var threeSyncM2TS = [UInt8](repeating: 0x44, count: 389)
        threeSyncM2TS[4] = 0x47
        threeSyncM2TS[196] = 0x47
        threeSyncM2TS[388] = 0x47
        #expect(AVIOReader.bodyBeginsWithMPEGTS(threeSyncM2TS))
        #expect(AVIOReader.bodyBeginsWithMPEGTS(Self.makeM2TSPackets(count: 3)))
    }

    @Test("bodyBeginsWithMPEGTS rejects short, misaligned, corrupted, and non-TS prefixes")
    func mpegtsPrefixRejectsInvalidOrNonTSBytes() {
        // Short buffers (< 189 for TS, < 197 for M2TS).
        #expect(!AVIOReader.bodyBeginsWithMPEGTS([]))
        #expect(!AVIOReader.bodyBeginsWithMPEGTS(Self.makeTSPackets(count: 1)))
        var shortM2TS = [UInt8](repeating: 0x00, count: 196)
        shortM2TS[4] = 0x47
        #expect(!AVIOReader.bodyBeginsWithMPEGTS(shortM2TS))

        // Single 0x47 without a matching stride.
        var singleTS = [UInt8](repeating: 0x00, count: 376)
        singleTS[0] = 0x47
        #expect(!AVIOReader.bodyBeginsWithMPEGTS(singleTS))
        var singleM2TS = [UInt8](repeating: 0x00, count: 384)
        singleM2TS[4] = 0x47
        #expect(!AVIOReader.bodyBeginsWithMPEGTS(singleM2TS))

        // Corrupted 3rd sync byte when prefix reaches 377 (TS) or 389 (M2TS).
        var badThirdTS = Self.makeTSPackets(count: 3)
        badThirdTS[376] = 0x00
        #expect(!AVIOReader.bodyBeginsWithMPEGTS(badThirdTS))
        var badThirdM2TS = Self.makeM2TSPackets(count: 3)
        badThirdM2TS[388] = 0x00
        #expect(!AVIOReader.bodyBeginsWithMPEGTS(badThirdM2TS))

        // Unaligned TS bytes (shifted by 1 or 2 bytes).
        let unaligned1 = [UInt8(0x00)] + Self.makeTSPackets(count: 3)
        let unaligned2 = [UInt8(0x00), UInt8(0x00)] + Self.makeTSPackets(count: 3)
        #expect(!AVIOReader.bodyBeginsWithMPEGTS(unaligned1))
        #expect(!AVIOReader.bodyBeginsWithMPEGTS(unaligned2))

        // Non-TS payloads: HLS playlist, MP4 ftyp, Matroska EBML, JSON, HTML.
        let hls = Array("#EXTM3U\n#EXT-X-VERSION:3\n".utf8) + [UInt8](repeating: 0x20, count: 512)
        let mp4 = [UInt8]([0x00, 0x00, 0x00, 0x18]) + Array("ftypisom".utf8) + [UInt8](repeating: 0x00, count: 512)
        let mkv = [UInt8]([0x1A, 0x45, 0xDF, 0xA3]) + [UInt8](repeating: 0x00, count: 512)
        let json = Array("{\"error\":\"channel offline\"}".utf8) + [UInt8](repeating: 0x20, count: 512)
        let html = Array("<!doctype html><html><body>offline</body></html>".utf8) + [UInt8](repeating: 0x20, count: 512)
        #expect(!AVIOReader.bodyBeginsWithMPEGTS(hls))
        #expect(!AVIOReader.bodyBeginsWithMPEGTS(mp4))
        #expect(!AVIOReader.bodyBeginsWithMPEGTS(mkv))
        #expect(!AVIOReader.bodyBeginsWithMPEGTS(json))
        #expect(!AVIOReader.bodyBeginsWithMPEGTS(html))
    }

    // MARK: - Live HTTP open and Demuxer integration tests

    @Test("live HTTP open detects MPEG-TS from a small initial chunk on .ts and extensionless URLs")
    func liveOpenDetectsSmallChunkMPEGTSPrefix() throws {
        // Two TS packets (376 bytes): well below FFmpeg's 2,048-byte probe buffer.
        let twoPackets = Data(TinyTransportStreamFixture.data.prefix(376))
        let origin = try #require(LivePrefixOrigin { _ in
            .init(body: twoPackets, includeContentLength: false, holdOpenAfterBody: true)
        })
        defer { origin.stop() }

        for path in ["/live/user/pass/12345.ts", "/live/12345"] {
            let reader = AVIOReader(url: try origin.url(path), label: "live", prefetchEnabled: true, isLive: true)
            defer { reader.markClosed(); reader.close() }
            try reader.open()
            #expect(reader.openedLiveMPEGTSPrefix, "expected MPEG-TS prefix detection for \(path)")
        }
    }

    @Test("Demuxer opens live TS and M2TS streams on .ts and extensionless URLs as mpegts")
    func demuxerOpensLiveTSAndM2TSAsMPEGTS() throws {
        let tsBody = TinyTransportStreamFixture.data
        let m2tsBody = Self.wrapAsM2TS(tsBody)
        let origin = try #require(LivePrefixOrigin { path in
            if path.hasSuffix(".m2ts") {
                return .init(body: m2tsBody)
            }
            return .init(body: tsBody)
        })
        defer { origin.stop() }

        for path in ["/live/user/pass/12345.ts", "/live/12345", "/live/channel.m2ts"] {
            let demuxer = Demuxer()
            defer { demuxer.close() }
            try demuxer.open(url: try origin.url(path), isLive: true)
            #expect(demuxer.containerFormatName == "mpegts")
            #expect(demuxer.videoStreamIndex >= 0)
        }
    }

    @Test("VOD MPEG-TS open leaves openedLiveMPEGTSPrefix false")
    func vodOpenDoesNotSetLiveMPEGTSPrefix() throws {
        let origin = try #require(KeepAliveRangeOrigin(data: TinyTransportStreamFixture.data, contentType: "video/mp2t"))
        defer { origin.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/vod/clip.ts"))
        let reader = AVIOReader(url: url, label: "vod", prefetchEnabled: true, isLive: false)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        #expect(!reader.openedLiveMPEGTSPrefix)
    }

    @Test("live .ts URL returning #EXTM3U still throws hlsPlaylistOnRawLivePath")
    func liveTSURLReturningHLSStillThrows() throws {
        let playlist = Data("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nseg1.ts\n".utf8)
        let origin = try #require(LivePrefixOrigin { _ in
            .init(contentType: "application/vnd.apple.mpegurl", body: playlist)
        })
        defer { origin.stop() }

        let reader = AVIOReader(url: try origin.url("/live/channel.ts"), label: "live", prefetchEnabled: true, isLive: true)
        defer { reader.markClosed(); reader.close() }
        let failure = #expect(throws: AVIOReaderError.self) { try reader.open() }
        #expect(failure == .hlsPlaylistOnRawLivePath)
        #expect(!reader.openedLiveMPEGTSPrefix)
    }

    @Test("live .ts URL returning JSON or MP4 bytes leaves openedLiveMPEGTSPrefix false")
    func liveTSURLReturningNonTSDoesNotForceMPEGTS() throws {
        let jsonBody = Data((Array("{\"status\":\"offline\"}".utf8) + [UInt8](repeating: 0x20, count: 512)))
        let mp4Body = Data([UInt8]([0x00, 0x00, 0x00, 0x18]) + Array("ftypisom".utf8) + [UInt8](repeating: 0x00, count: 512))
        let origin = try #require(LivePrefixOrigin { path in
            if path == "/mp4.ts" {
                return .init(contentType: "video/mp4", body: mp4Body, includeContentLength: false, holdOpenAfterBody: true)
            }
            return .init(contentType: "application/json", body: jsonBody, includeContentLength: false, holdOpenAfterBody: true)
        })
        defer { origin.stop() }

        for path in ["/json.ts", "/mp4.ts"] {
            let reader = AVIOReader(url: try origin.url(path), label: "live", prefetchEnabled: true, isLive: true)
            defer { reader.markClosed(); reader.close() }
            try reader.open()
            #expect(!reader.openedLiveMPEGTSPrefix, "non-TS payload on \(path) must not set openedLiveMPEGTSPrefix")
        }
    }

    // MARK: - Live HLS ingest session pooling

    @Test("HLSLiveIngestReader pools an ephemeral stateless URLSession across tunes")
    func liveIngestReadersReuseSharedEphemeralSession() throws {
        let urlA = try #require(URL(string: "http://127.0.0.1:9/channelA.m3u8"))
        let urlB = try #require(URL(string: "http://127.0.0.1:9/channelB.m3u8"))
        let readerA = HLSLiveIngestReader(playlistURL: urlA)
        let readerB = HLSLiveIngestReader(playlistURL: urlB)

        #expect(readerA.session === readerB.session)
        #expect(readerA.session.configuration.urlCache == nil)
        #expect(readerA.session.configuration.httpCookieStorage == nil)
        #expect(readerA.session.configuration.httpShouldSetCookies == false)
        #expect(readerA.session.configuration.urlCredentialStorage == nil)

        // Closing one reader must not invalidate the pooled session used by subsequent tunes.
        readerA.close()
        let task = readerB.session.dataTask(with: urlB)
        task.cancel()
        readerB.close()
        #expect(task.state == .canceling || task.state == .completed)
    }
}
