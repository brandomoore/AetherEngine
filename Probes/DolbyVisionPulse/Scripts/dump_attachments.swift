// dump_attachments.swift - what does VideoToolbox attach to a decoded Dolby Vision frame?
//
// Decodes a Profile 8.1 clip with AVAssetReader (i.e. VideoToolbox's own decoder) and, for the chosen
// frames, prints every attachment on the CVPixelBuffer plus the sample-buffer attachment keys. For all
// frames it records a short SHA-256 of the "DolbyVisionRPUData" attachment and finishes with a summary
// of how many frames share each hash.
//
// What it proves: the RPU payload (its size and bytes) that VideoToolbox itself attaches to the pixel
// buffer, so the payload an engine attaches can be compared byte-for-byte with it. On the pulse clip the
// hash must differ between an A-phase and a B-phase frame (the RPU changes with the pulse). Expect two
// hashes per phase: keyframes carry a slightly different payload from the frames between them.
//
// Usage: swift dump_attachments.swift <clip.mp4> [frame indices...]
//   e.g. swift dump_attachments.swift pulse_l2.mp4 0 200
import AVFoundation
import CryptoKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: swift dump_attachments.swift <clip.mp4> [frames...]\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: args[1])
let want = Set(args.dropFirst(2).compactMap(Int.init))
let asset = AVURLAsset(url: url)
let sem = DispatchSemaphore(value: 0)
Task {
  do {
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let fds = try await track.load(.formatDescriptions)
    if let fd = fds.first {
        print("codec:", String(fourCC: CMFormatDescriptionGetMediaSubType(fd)))
        print("format extensions:", (CMFormatDescriptionGetExtensions(fd) as? [String: Any])?.keys.sorted() ?? [])
    }
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
    reader.add(out)
    reader.startReading()
    var i = 0
    var hashes: [String: [Int]] = [:]
    while let sb = out.copyNextSampleBuffer() {
        defer { i += 1 }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
        let atts = CVBufferCopyAttachments(pb, .shouldPropagate) as? [String: Any] ?? [:]
        let rpu = atts["DolbyVisionRPUData"] as? Data
        let h = rpu.map { SHA256.hash(data: $0).prefix(4).map { String(format: "%02x", $0) }.joined() } ?? "none"
        hashes[h, default: []].append(i)
        if want.contains(i) {
            print("frame \(i): rpu=\(rpu?.count ?? 0)B hash=\(h) compat=\(atts["DolbyCompatibilityID"] ?? "nil")")
            print("  keys:", atts.keys.sorted())
            let sa = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[String: Any]]
            print("  sample attachments:", sa?.first?.keys.sorted() ?? [])
        }
    }
    print("frames decoded:", i)
    for (h, frames) in hashes.sorted(by: { $0.value.first! < $1.value.first! }) {
        print("rpu \(h): \(frames.count) frames, first \(frames.first!), last \(frames.last!)")
    }
  } catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
  }
  sem.signal()
}
sem.wait()

extension String {
    init(fourCC v: FourCharCode) {
        self = String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "\(v)"
    }
}
