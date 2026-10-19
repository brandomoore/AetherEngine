// Tests/AetherEngineTests/CompositorPreviewPlanIndexTests.swift
import Foundation
import Testing
@testable import AetherEngine

/// The plan entry a source-keyframe scrub preview reads for a position outside the resident window.
struct CompositorPreviewPlanIndexTests {
    private let plan: [HLSVideoEngine.Segment] = [
        .init(startPts: 0, endPts: 4000, startSeconds: 0, durationSeconds: 4),
        .init(startPts: 4000, endPts: 10_000, startSeconds: 4, durationSeconds: 6),
        .init(startPts: 10_000, endPts: 12_000, startSeconds: 10, durationSeconds: 2),
    ]

    @Test("a position belongs to the entry it falls in, a boundary to the entry it opens",
          arguments: [(0.0, 0), (3.99, 0), (4.0, 1), (9.5, 1), (10.0, 2), (11.9, 2)])
    func containing(seconds: Double, expected: Int) {
        #expect(HLSVideoEngine.planIndex(containing: seconds, in: plan) == expected)
    }

    @Test("before the first entry is the first entry, past the last one's end is nothing")
    func edges() {
        #expect(HLSVideoEngine.planIndex(containing: -2, in: plan) == 0)
        #expect(HLSVideoEngine.planIndex(containing: 12.5, in: plan) == nil)
        #expect(HLSVideoEngine.planIndex(containing: .nan, in: plan) == nil)
        #expect(HLSVideoEngine.planIndex(containing: 1, in: []) == nil)
    }
}
