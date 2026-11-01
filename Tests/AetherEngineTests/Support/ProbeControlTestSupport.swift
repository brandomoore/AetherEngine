import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

final class ProbeTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

/// Only detached test workers park here; the test executor observes arrivals with `waitFor`.
final class ProbeTestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var arrivals = 0

    var entered: Bool { condition.withLock { arrivals > 0 } }
    var isOpen: Bool { condition.withLock { released } }

    func wait(onArrival: @Sendable () -> Void = {}) {
        condition.lock()
        arrivals += 1
        condition.unlock()
        onArrival()
        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
    }

    func open() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

final class ProbeTestJob<Value: Sendable>: @unchecked Sendable {
    private let result = ProbeTestBox<Result<Value, any Error>?>(nil)

    init(_ body: @escaping @Sendable () throws -> Value) {
        let result = self.result
        Thread.detachNewThread {
            let outcome = autoreleasepool { Result(catching: body) }
            result.update { $0 = outcome }
        }
    }

    var isFinished: Bool { result.value != nil }

    func outcome() async throws -> Result<Value, any Error> {
        try await waitFor { self.isFinished }
        return try #require(result.value)
    }
}

final class ProbeRecordingReader: IOReader, @unchecked Sendable {
    struct Read: Sendable {
        let offset: Int64
        let requested: Int32
        let returned: Int32
    }

    struct Seek: Sendable {
        let offset: Int64
        let whence: Int32
    }

    private struct State {
        var position: Int64 = 0
        var reads: [Read] = []
        var seeks: [Seek] = []
        var cancellations = 0
        var closes = 0
    }

    private let state = ProbeTestBox(State())
    private let data: Data
    private let chunkSize: Int
    private let afterRead: (@Sendable () -> Void)?
    private let afterSeek: (@Sendable () -> Void)?
    private let afterCancel: (@Sendable () -> Void)?
    let discImageProbeEnabled: Bool

    init(
        data: Data,
        discImageProbeEnabled: Bool = false,
        chunkSize: Int = Int.max,
        afterRead: (@Sendable () -> Void)? = nil,
        afterSeek: (@Sendable () -> Void)? = nil,
        afterCancel: (@Sendable () -> Void)? = nil
    ) {
        self.data = data
        self.discImageProbeEnabled = discImageProbeEnabled
        self.chunkSize = chunkSize
        self.afterRead = afterRead
        self.afterSeek = afterSeek
        self.afterCancel = afterCancel
    }

    var reads: [Read] { state.value.reads }
    var seeks: [Seek] { state.value.seeks }
    var bytesRead: Int64 { reads.reduce(0) { $0 + Int64(max(0, $1.returned)) } }
    var cancelCount: Int { state.value.cancellations }
    var closeCount: Int { state.value.closes }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return 0 }
        var result: Int32 = 0
        state.update { state in
            let start = Int(min(state.position, Int64(data.count)))
            let count = min(Int(size), chunkSize, data.count - start)
            if count > 0 {
                data.copyBytes(
                    to: UnsafeMutableBufferPointer(start: buffer, count: count),
                    from: start..<(start + count))
            }
            result = Int32(count)
            state.reads.append(Read(offset: state.position, requested: size, returned: result))
            state.position += Int64(count)
        }
        // Deliberately outside the cursor lock: cancellation is allowed to reenter this reader.
        afterRead?()
        return result
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        var result: Int64 = -1
        state.update { state in
            state.seeks.append(Seek(offset: offset, whence: whence))
            if whence & 0x10000 != 0 {
                result = Int64(data.count)
                return
            }
            let target: Int64
            switch whence & ~0x20000 {
            case SEEK_SET: target = offset
            case SEEK_CUR: target = state.position + offset
            case SEEK_END: target = Int64(data.count) + offset
            default: return
            }
            guard target >= 0 else { return }
            state.position = target
            result = target
        }
        afterSeek?()
        return result
    }

    func cancel() {
        state.update { $0.cancellations += 1 }
        afterCancel?()
    }
    func close() { state.update { $0.closes += 1 } }
}

/// `cancel` wakes the operation without closing it. A second gate proves the synchronous probe
/// does not return until the host's callback has actually unwound.
final class ProbeParkedReader: IOReader, @unchecked Sendable {
    enum Operation: Sendable, CaseIterable, Equatable { case read, seek }

    let interrupted = ProbeTestGate()
    let mayReturn = ProbeTestGate()
    let beforePark: ProbeTestGate?
    let discImageProbeEnabled = false
    private let operation: Operation
    private let interruptOnCancel: Bool
    private let counts = ProbeTestBox((cancels: 0, closes: 0))

    init(operation: Operation, pauseBeforeParking: Bool = false, interruptOnCancel: Bool = true) {
        self.operation = operation
        self.interruptOnCancel = interruptOnCancel
        beforePark = pauseBeforeParking ? ProbeTestGate() : nil
    }
    var cancelCount: Int { counts.value.cancels }
    var closeCount: Int { counts.value.closes }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard operation == .read else { return -1 }
        beforePark?.wait()
        interrupted.wait()
        mayReturn.wait()
        return -1
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        guard operation == .seek else { return whence == 0x10000 ? 1024 : 0 }
        beforePark?.wait()
        interrupted.wait()
        mayReturn.wait()
        return -1
    }

    func cancel() {
        counts.update { $0.cancels += 1 }
        if interruptOnCancel { interrupted.open() }
    }

    func close() { counts.update { $0.closes += 1 } }

    func release() {
        beforePark?.open()
        interrupted.open()
        mayReturn.open()
    }
}

enum ProbeTestFixtures {
    static func decode(_ base64: String) throws -> Data {
        try #require(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
    }

    static func hdr10Plus() throws -> Data {
        try decode(HDR10PlusProbeIntegrationTests.hdr10PlusBase64)
    }

    static func eac3() throws -> Data {
        try decode(AtmosDetectionProbeIntegrationTests.eac3PlainBase64)
    }

    /// Scratch fixtures live in the temporary directory: one written into the working directory is left
    /// in the checkout when the process dies inside the body (audit OPS-109).
    static func withFile<T>(_ data: Data, _ body: (URL) throws -> T) throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(".probe-control-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        return try body(url)
    }

    /// Remux the existing synthetic fixtures in memory; no CLI, downloaded media or global hooks.
    static func combined(audioCopies: Int = 1) throws -> Data {
        let video = Demuxer()
        let audio = Demuxer()
        defer { video.close(); audio.close() }
        try video.open(reader: DataIOReader(data: hdr10Plus()), formatHint: "mp4")
        try audio.open(reader: DataIOReader(data: eac3()), formatHint: "mp4")
        let videoStream = try #require(video.stream(at: video.videoStreamIndex))
        let audioStream = try #require(audio.stream(at: audio.audioStreamIndex))

        var output: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_alloc_output_context2(&output, nil, "mp4", nil) >= 0)
        let context = try #require(output)
        defer { avformat_free_context(context) }

        var io: UnsafeMutablePointer<AVIOContext>?
        try #require(avio_open_dyn_buf(&io) >= 0)
        let buffer = try #require(io)
        context.pointee.pb = buffer
        var bytes: UnsafeMutablePointer<UInt8>?
        var bufferClosed = false
        defer {
            if !bufferClosed { _ = avio_close_dyn_buf(buffer, &bytes) }
            av_free(bytes)
        }

        let streams = [(video, videoStream)] + Array(repeating: (audio, audioStream), count: audioCopies)
        for (_, source) in streams {
            let target = try #require(avformat_new_stream(context, nil))
            try #require(avcodec_parameters_copy(target.pointee.codecpar, source.pointee.codecpar) >= 0)
            target.pointee.time_base = source.pointee.time_base
        }
        try #require(avformat_write_header(context, nil) >= 0)
        for (index, pair) in streams.enumerated() {
            let (demuxer, source) = pair
            if index > 1 { demuxer.seek(to: 0) }
            let target = try #require(context.pointee.streams[index])
            while let packet = try demuxer.readPacket() {
                var owned: UnsafeMutablePointer<AVPacket>? = packet
                defer { trackedPacketFree(&owned) }
                av_packet_rescale_ts(packet, source.pointee.time_base, target.pointee.time_base)
                packet.pointee.stream_index = Int32(index)
                packet.pointee.pos = -1
                try #require(av_interleaved_write_frame(context, packet) >= 0)
            }
        }
        try #require(av_write_trailer(context) >= 0)
        let count = avio_close_dyn_buf(buffer, &bytes)
        bufferClosed = true
        context.pointee.pb = nil
        try #require(count > 0)
        return Data(bytes: try #require(bytes), count: Int(count))
    }

    /// Include queued foreign packets, rather than assuming a particular MP4 interleave order.
    static func firstVideoBudget(_ data: Data) throws -> (packets: Int, bytes: Int) {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mp4", profile: .stillExtraction)
        demuxer.discardAllStreamsExcept([demuxer.videoStreamIndex])
        var count = 0
        while let packet = try demuxer.readPacket() {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&owned) }
            count += 1
            if packet.pointee.stream_index == demuxer.videoStreamIndex {
                return (count, Int(packet.pointee.size))
            }
        }
        throw CocoaError(.fileReadCorruptFile)
    }
}
