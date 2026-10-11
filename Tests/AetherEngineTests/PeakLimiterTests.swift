import Testing
import Foundation
@testable import AetherEngine

/// The APAC encoder carries samples over full scale through unchanged (#731), so the bridge limits
/// the rendered bed itself. These pin what that must and must not do to the programme.
@Suite("Rendered bed peak limiter")
struct PeakLimiterTests {

    private func run(_ limiter: inout PeakLimiter, _ channels: [[Float]]) -> [[Float]] {
        let frames = channels[0].count
        let planes = channels.map { c -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            p.initialize(from: c, count: frames)
            return p
        }
        defer { planes.forEach { $0.deallocate() } }
        limiter.process(planes, frameCount: frames)
        return planes.map { Array(UnsafeBufferPointer(start: $0, count: frames)) }
    }

    private func tone(_ amplitude: Float, frames: Int, hz: Float = 1000) -> [Float] {
        (0..<frames).map { amplitude * sin(Float($0) * 2 * .pi * hz / 48_000) }
    }

    @Test("a bed under the threshold passes bit for bit")
    func transparentBelowThreshold() {
        var limiter = PeakLimiter(sampleRate: 48_000)
        let input = [tone(0.9, frames: 4800), tone(0.5, frames: 4800, hz: 300)]
        #expect(run(&limiter, input) == input)
        #expect(limiter.takeLimitedFrames().frames == 0)
    }

    @Test("no sample leaves above the threshold, however loud the input")
    func neverAboveThreshold() {
        var limiter = PeakLimiter(sampleRate: 48_000)
        let out = run(&limiter, [tone(4, frames: 9600), tone(1.5, frames: 9600, hz: 70)])
        let peak = out.flatMap { $0 }.map(abs).max()!
        #expect(peak <= PeakLimiter.threshold + 1e-6)
        let taken = limiter.takeLimitedFrames()
        #expect(taken.frames > 0)
        #expect(taken.deepestDB < -12, "a 4.0 peak needs about -12.2 dB")
        #expect(limiter.takeLimitedFrames().frames == 0, "the count starts over once taken")
    }

    @Test("one gain for every channel, so an object between two speakers stays where it is")
    func linkedAcrossChannels() {
        var limiter = PeakLimiter(sampleRate: 48_000)
        let left = tone(2, frames: 4800)
        let right = left.map { $0 * 0.5 }
        let out = run(&limiter, [left, right])
        for i in stride(from: 0, to: 4800, by: 37) where abs(out[0][i]) > 1e-4 {
            #expect(abs(out[1][i] / out[0][i] - 0.5) < 1e-4, "frame \(i)")
        }
    }

    @Test("after a loud burst the gain recovers instead of staying down")
    func releases() {
        var limiter = PeakLimiter(sampleRate: 48_000)
        _ = run(&limiter, [tone(3, frames: 2400)])
        // Two seconds of quiet programme: eight release time constants later it passes untouched.
        let quiet = tone(0.5, frames: 96_000)
        let out = run(&limiter, [quiet])
        #expect(abs(out[0][95_000...].map(abs).max()! - 0.5) < 1e-3)
        #expect(abs(out[0][0..<1200].map(abs).max()!) < 0.5, "right after the burst it is still holding down")
    }

    @Test("a reset forgets the burst")
    func resetForgets() {
        var limiter = PeakLimiter(sampleRate: 48_000)
        _ = run(&limiter, [tone(3, frames: 2400)])
        limiter.reset()
        let quiet = tone(0.5, frames: 4800)
        #expect(run(&limiter, [quiet]) == [quiet])
    }
}
