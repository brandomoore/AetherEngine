import Foundation

/// A tiny file logger: every line the harness and the engine print also lands in
/// `Library/Caches/pulse-log.txt`, which `devicectl device copy from` can pull after a run, including
/// after a crash that took the console with it. Truncated at launch.
final class PulseLog: @unchecked Sendable {
    static let shared = PulseLog()

    private let queue = DispatchQueue(label: "pulse.log")
    private let url: URL
    private var handle: FileHandle?

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        url = caches.appendingPathComponent("pulse-log.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func note(_ line: String) {
        queue.async { [self] in
            guard let data = (line + "\n").data(using: .utf8) else { return }
            try? handle?.write(contentsOf: data)
        }
    }
}
