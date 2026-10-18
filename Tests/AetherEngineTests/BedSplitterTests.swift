// Only with the TrueHDObjectAudio trait: the splitter is not built without it.
#if TrueHDObjectAudio
import Testing
import Foundation
@testable import AetherEngine

/// The TrueHD path takes every output from the stream's own channel presentation and only reads
/// where the objects' energy lies. These pin what that split has to get right: the timeline (output
/// frame i is input frame i, nothing lost at the end), where a bed channel's energy goes for an
/// element on the floor and one on the ceiling, a 5.1 bed covering a 7.1 layout, and the LFE.
@Suite("Bed splitter")
struct BedSplitterTests {

    static let bed71: [ObjectAudioRole] = [.bed(.left), .bed(.right), .bed(.center), .lfe,
                                           .bed(.sideLeft), .bed(.sideRight), .bed(.rearLeft), .bed(.rearRight)]
    static let bed51: [ObjectAudioRole] = [.bed(.left), .bed(.right), .bed(.center), .lfe,
                                           .bed(.sideLeft), .bed(.sideRight)]

    /// Deterministic noise, so every bin has energy.
    static func noise(_ count: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2000 - 1000) / 10_000
        }
    }

    /// Runs `frames` frames through a splitter in 40-frame blocks with one element at `position`
    /// whose signal is `element`, and returns every output channel, drained.
    static func run(layout: SpatialSpeakerLayout, bedRoles: [ObjectAudioRole], bed: [[Float]],
                    element: [Float]?, position: SIMD3<Float>, frames: Int) -> [[Float]] {
        let splitter = BedSplitter(layout: layout, bedRoles: bedRoles)
        var snapshot = ObjectAudioGainSnapshot()
        if element != nil {
            snapshot.resize(elements: 1, channels: layout.channelCount)
            var gains: [Float] = []
            AllocentricPanner(layout: layout).pointGains(position, into: &gains)
            snapshot.layoutGains = gains
            snapshot.positions = [position]
            snapshot.gains = [1]
            splitter.setGains(snapshot)
        }
        let out = (0..<layout.channelCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        defer { out.forEach { $0.deallocate() } }
        var written = 0
        var offset = 0
        while offset < frames {
            let n = min(40, frames - offset)
            let got = bed.withPointers { bedPlanes in
                (element ?? []).withUnsafeBufferPointer { e in
                    splitter.process(
                        elements: element == nil ? [] : [e.baseAddress! + offset],
                        bed: bedPlanes.map { $0 + offset }, frameCount: n,
                        output: out.map { $0 + written })
                }
            }
            written += got
            offset += n
        }
        written += splitter.drain(output: out.map { $0 + written })
        #expect(written == frames)
        return out.map { Array(UnsafeBufferPointer(start: $0, count: written)) }
    }

    static func energy(_ x: [Float]) -> Float { x.reduce(0) { $0 + $1 * $1 } }

    static func silent(_ count: Int) -> [Float] { [Float](repeating: 0, count: count) }

    @Test("output frame i is input frame i, and everything comes out by the end",
          arguments: [300, 2047, 2048, 2049, 9_000])
    func timeline(frames: Int) {
        let layout = SpatialSpeakerLayout.l714
        var left = Self.silent(frames)
        let at = frames / 2
        left[at] = 0.5
        var bed = Self.bed71.map { _ in Self.silent(frames) }
        bed[0] = left
        bed[3] = left
        let out = Self.run(layout: layout, bedRoles: Self.bed71, bed: bed, element: nil,
                           position: SIMD3(0, 0, 0), frames: frames)
        let peak = out[0].indices.max { abs(out[0][$0]) < abs(out[0][$1]) }!
        #expect(peak == at)
        // The LFE is a pure delay: exactly the bed's.
        let lfe = out[layout.lfeIndex]
        #expect(lfe == left, "LFE peak at \(lfe.indices.max { abs(lfe[$0]) < abs(lfe[$1]) }!), expected \(at)")
    }

    @Test("an element on the floor keeps its bed channel on its own speaker")
    func floorElement() {
        let layout = SpatialSpeakerLayout.l714, frames = 48_000
        let signal = Self.noise(frames, seed: 1)
        var bed = Self.bed71.map { _ in Self.silent(frames) }
        bed[0] = signal
        let out = Self.run(layout: layout, bedRoles: Self.bed71, bed: bed, element: signal,
                           position: SIMD3(0, 0, 0), frames: frames)
        let total = out.map(Self.energy).reduce(0, +)
        #expect(Self.energy(out[0]) / total > 0.99)
        #expect(abs(total / Self.energy(signal) - 1) < 0.05)
    }

    @Test("an element on the ceiling takes its bed channel's energy up to the heights")
    func ceilingElement() {
        let layout = SpatialSpeakerLayout.l714, frames = 48_000
        let signal = Self.noise(frames, seed: 2)
        var bed = Self.bed71.map { _ in Self.silent(frames) }
        bed[0] = signal
        let out = Self.run(layout: layout, bedRoles: Self.bed71, bed: bed, element: signal,
                           position: SIMD3(0, 0, 1), frames: frames)
        let topFrontLeft = layout.speakers.firstIndex(of: .topFrontLeft)!
        let total = out.map(Self.energy).reduce(0, +)
        #expect(Self.energy(out[topFrontLeft]) / total > 0.95)
        #expect(Self.energy(out[0]) / total < 0.05)
    }

    @Test("a 5.1 bed's surround covers a 7.1 layout's rear as well as its side")
    func fiveOneBedOnSevenOne() {
        let layout = SpatialSpeakerLayout.l714, frames = 48_000
        let signal = Self.noise(frames, seed: 3)
        var bed = Self.bed51.map { _ in Self.silent(frames) }
        bed[4] = signal
        let rearLeft = layout.speakers.firstIndex(of: .rearLeft)!
        let sideLeft = layout.speakers.firstIndex(of: .sideLeft)!
        let atRear = Self.run(layout: layout, bedRoles: Self.bed51, bed: bed, element: signal,
                              position: SIMD3(0, 1, 0), frames: frames)
        let total = atRear.map(Self.energy).reduce(0, +)
        #expect(Self.energy(atRear[rearLeft]) / total > 0.95)
        // The same channel with nothing to say where it belongs stays on the side, its primary output.
        let unexplained = Self.run(layout: layout, bedRoles: Self.bed51, bed: bed, element: nil,
                                   position: SIMD3(0, 1, 0), frames: frames)
        #expect(Self.energy(unexplained[sideLeft]) / unexplained.map(Self.energy).reduce(0, +) > 0.99)
    }

    @Test("a 7.1 bed's rears fold onto a 5.1 layout's surrounds")
    func sevenOneBedOnFiveOne() {
        let layout = SpatialSpeakerLayout.l514, frames = 24_000
        let signal = Self.noise(frames, seed: 4)
        var bed = Self.bed71.map { _ in Self.silent(frames) }
        bed[6] = signal
        let out = Self.run(layout: layout, bedRoles: Self.bed71, bed: bed, element: nil,
                           position: SIMD3(0, 1, 0), frames: frames)
        let surroundLeft = layout.speakers.firstIndex(of: .surroundLeft)!
        #expect(Self.energy(out[surroundLeft]) / out.map(Self.energy).reduce(0, +) > 0.99)
    }

    @Test("the element's own signal never reaches an output: a silent bed stays silent")
    func elementAloneIsSilent() {
        let layout = SpatialSpeakerLayout.l714, frames = 24_000
        let bed = Self.bed71.map { _ in Self.silent(frames) }
        let out = Self.run(layout: layout, bedRoles: Self.bed71, bed: bed, element: Self.noise(frames, seed: 5),
                           position: SIMD3(0.5, 0.5, 1), frames: frames)
        #expect(out.allSatisfy { $0.allSatisfy { $0 == 0 } })
    }
}

private extension Array where Element == [Float] {
    func withPointers<R>(_ body: ([UnsafePointer<Float>]) -> R) -> R {
        var pointers: [UnsafePointer<Float>] = []
        func recurse(_ i: Int) -> R {
            if i == count { return body(pointers) }
            return self[i].withUnsafeBufferPointer { buffer in
                pointers.append(buffer.baseAddress!)
                return recurse(i + 1)
            }
        }
        return recurse(0)
    }
}
#endif
