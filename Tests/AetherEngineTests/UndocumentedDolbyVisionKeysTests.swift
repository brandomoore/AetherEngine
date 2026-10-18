import XCTest
@testable import AetherEngine

/// The FEL route hands tvOS its per-frame Dolby Vision metadata under two attachment keys that are in
/// no public header. If a tvOS release stops honouring them there must be exactly one place to change,
/// so the literals may be spelled in `DoviDisplayMetadata.swift` and nowhere else in `Sources/`;
/// everything else goes through `DoviDisplayMetadata.rpuDataKey` / `.compatibilityIDKey`.
final class UndocumentedDolbyVisionKeysTests: XCTestCase {

    func testTheUndocumentedKeysAreSpelledInOneFileOnly() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let owner = "DoviDisplayMetadata.swift"
        let literals = ["\"DolbyVisionRPUData\"", "\"DolbyCompatibilityID\""]
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var ownerSpellsBoth = false
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let hits = literals.filter { text.contains($0) }
            if url.lastPathComponent == owner {
                ownerSpellsBoth = hits.count == literals.count
            } else if !hits.isEmpty {
                offenders.append("\(url.lastPathComponent): \(hits.joined(separator: ", "))")
            }
        }
        XCTAssertTrue(ownerSpellsBoth, "\(owner) should define both keys")
        XCTAssertEqual(offenders, [], "use DoviDisplayMetadata.rpuDataKey / .compatibilityIDKey instead")
    }
}
