import Foundation

/// Bounds for opt-in preparation of a downloaded text sidecar; ordinary selection is unchanged.
public struct ExternalSubtitlePreparationPolicy: Sendable, Equatable {
    public var maximumFileBytes: Int
    public var maximumCueCount: Int
    public var maximumCueBytes: Int
    public var maximumTextBytes: Int

    public init(maximumFileBytes: Int = 4 * 1024 * 1024, maximumCueCount: Int = 50_000,
                maximumCueBytes: Int = 8192, maximumTextBytes: Int = 8 * 1024 * 1024) {
        self.maximumFileBytes = maximumFileBytes
        self.maximumCueCount = maximumCueCount
        self.maximumCueBytes = maximumCueBytes
        self.maximumTextBytes = maximumTextBytes
    }

    /// Called only on the blocking decode worker, never by the MainActor preparation entry point.
    func validateFile(_ url: URL) throws {
        guard url.isFileURL else { throw ExternalSubtitlePreparationError.unsupportedFormat }
        guard maximumFileBytes > 0, maximumCueCount > 0, maximumCueBytes > 0,
              maximumTextBytes > 0 else { throw ExternalSubtitlePreparationError.resourceLimit }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximumFileBytes else {
            throw ExternalSubtitlePreparationError.resourceLimit
        }
    }
}
