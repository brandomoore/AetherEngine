import Foundation
import XCTest
@testable import AetherEngine

final class PrivacyManifestTests: XCTestCase {
    func testRequiredReasonsAreIncludedInThePackageResources() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let manifest = try XCTUnwrap(value as? [String: Any])
        let entries = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: Set<String>] = [:]
        for entry in entries {
            let category = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)
            XCTAssertNil(reasons[category], "Duplicate API category")
            reasons[category] = Set(try XCTUnwrap(entry["NSPrivacyAccessedAPITypeReasons"] as? [String]))
        }
        XCTAssertEqual(reasons, [
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
            "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
            "NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"],
        ])
    }
}
