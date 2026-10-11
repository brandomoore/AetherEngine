import Foundation

/// The accounting seam is below disc recognition/adaptation, so sparse reads and rereads count too.
final class ProbeIOReader: IOReader, @unchecked Sendable {
    private let reader: IOReader
    private let control: ProbeControl

    init(reader: IOReader, control: ProbeControl) {
        self.reader = reader
        self.control = control
        control.interrupt { reader.cancel() }
    }

    var discImageProbeEnabled: Bool { reader.discImageProbeEnabled }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        do {
            let allowed = try control.inputAllowance(size)
            let count = autoreleasepool { reader.read(buffer, size: allowed) }
            try control.consumedInput(count, requested: allowed)
            return count
        } catch {
            // The orchestrator rethrows the control's typed failure after the native call unwinds.
            return -1
        }
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        guard !control.isStopped else { return -1 }
        let result = autoreleasepool { reader.seek(offset: offset, whence: whence) }
        return control.isStopped ? -1 : result
    }

    // A synchronous probe has no in-flight read at normal teardown, and never owns a host reader.
    func cancel() {}
    func close() {}
}

/// Reuses the engine HTTP transport with speculation disabled; no playback transport policy changes.
/// Its AVIO allocation stays owned here, separate from the bridge FFmpeg uses for the counted input.
final class ProbeHTTPReader: IOReader, @unchecked Sendable {
    private let reader: AVIOReader
    let discImageProbeEnabled: Bool

    init(url: URL, headers: [String: String], control: ProbeControl) {
        discImageProbeEnabled = Demuxer.isDiscImageURL(url)
        reader = AVIOReader(
            url: url, extraHeaders: headers, label: "probe",
            chunkSize: 64 * 1024, prefetchEnabled: false,
            chunkRequestTimeout: 2, chunkMaxRetries: 1, probeControl: control)
    }

    func open() throws { try reader.open() }
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer else { return -1 }
        let count = reader.read(into: buffer, size: size)
        return count == FFmpegErr.eof ? 0 : count
    }
    func seek(offset: Int64, whence: Int32) -> Int64 { reader.seek(offset: offset, whence: whence) }
    func cancel() { reader.markClosed() }
    func close() {
        reader.markClosed()
        reader.finishProbeTransfers()
        reader.close()
    }
}
