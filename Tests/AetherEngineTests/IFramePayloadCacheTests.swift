// Tests/AetherEngineTests/IFramePayloadCacheTests.swift
import Foundation
import Testing
@testable import AetherEngine

struct IFramePayloadCacheTests {
    private func makeCache(limit: Int) throws -> (IFramePayloadCache, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iframe-cache-\(UUID().uuidString)", isDirectory: true)
        return (IFramePayloadCache(directory: dir, byteLimit: limit), dir)
    }

    @Test("a stored payload comes back byte for byte")
    func roundTrip() throws {
        let (cache, dir) = try makeCache(limit: 1000)
        defer { try? FileManager.default.removeItem(at: dir) }
        cache.store(Data([1, 2, 3]), for: 5)
        #expect(cache.payload(for: 5) == Data([1, 2, 3]))
        #expect(cache.payload(for: 6) == nil)
    }

    @Test("the least recently used payload goes first once the cap is passed")
    func evictsLeastRecentlyUsed() throws {
        let (cache, dir) = try makeCache(limit: 250)
        defer { try? FileManager.default.removeItem(at: dir) }
        cache.store(Data(count: 100), for: 0)
        cache.store(Data(count: 100), for: 1)
        _ = cache.payload(for: 0)
        cache.store(Data(count: 100), for: 2)
        #expect(cache.payload(for: 1) == nil)
        #expect(cache.payload(for: 0) != nil)
        #expect(cache.payload(for: 2) != nil)
    }

    @Test("a payload larger than the cap is kept alone rather than evicted into a miss")
    func oversizedPayloadIsKeptAlone() throws {
        let (cache, dir) = try makeCache(limit: 100)
        defer { try? FileManager.default.removeItem(at: dir) }
        cache.store(Data(count: 60), for: 0)
        cache.store(Data(count: 500), for: 1)
        #expect(cache.payload(for: 1)?.count == 500)
        #expect(cache.payload(for: 0) == nil)
    }

    @Test("nearest prefers the closest index and the lower one on a tie")
    func nearest() throws {
        let (cache, dir) = try makeCache(limit: 1000)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(cache.nearestIndex(to: 10) == nil)
        cache.store(Data([1]), for: 4)
        cache.store(Data([1]), for: 20)
        #expect(cache.nearestIndex(to: 10) == 4)
        #expect(cache.nearestIndex(to: 13) == 20)
        #expect(cache.nearestIndex(to: 12) == 4)
    }

    @Test("removeAll forgets everything and deletes the directory")
    func removeAll() throws {
        let (cache, dir) = try makeCache(limit: 1000)
        cache.store(Data([1]), for: 0)
        cache.removeAll()
        #expect(cache.payload(for: 0) == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("a payload whose file vanished is a miss, not a crash")
    func missingFileIsAMiss() throws {
        let (cache, dir) = try makeCache(limit: 1000)
        defer { try? FileManager.default.removeItem(at: dir) }
        cache.store(Data([1]), for: 3)
        try FileManager.default.removeItem(at: dir)
        #expect(cache.payload(for: 3) == nil)
        #expect(cache.nearestIndex(to: 3) == nil)
    }
}
