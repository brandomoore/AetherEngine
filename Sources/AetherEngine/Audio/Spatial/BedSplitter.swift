// Only with the TrueHDObjectAudio trait (off by default), which links LibTrueHD.
#if TrueHDObjectAudio
import Accelerate
import Foundation

/// Builds a `SpatialSpeakerLayout` bed out of a TrueHD stream's own channel-based presentation, the
/// 7.1 (or 5.1) bed Dolby renders the same mix into, using the object presentation only to learn
/// where its energy belongs.
///
/// Every output is a share of that bed: per STFT bin, each bed channel is divided between the floor
/// speakers it covers and the heights, in proportion to how much of the bin's energy in that channel
/// comes from elements at each place. An element's part in a bed channel is its spectral energy times
/// its ear-level gain into the channel; it goes to the heights in proportion to its layout gains
/// above ear level, the rest to the floor speakers the channel covers. No element signal reaches an
/// output, so the elements only need to be right in where their energy lies, which an object
/// presentation decoded without its matrix interpolation is.
///
/// Two corrections keep that estimate honest:
/// - Per band, an element can hold no more energy than the bed channels it feeds carry (`boundMargin`
///   times what its ear-level share of them allows). The decode without interpolation leaves a
///   residue in quiet elements; bounded by the bed, it can no longer pull a quiet channel's content
///   up or sideways.
/// - Per output and band, the result is steered towards the energy the elements would give that
///   output in a direct render (smoothed over about 200 ms), which restores the spread a per-bin
///   split loses where several elements share a bin. Raised fully (at most `balanceLimit`), lowered
///   only by a third of the gap in dB (`balanceLowering`): the elements' energies add up to less than
///   a mix of them wherever they carry the same signal, so a target below the split is mostly the
///   estimate's shortfall, and lowering fully cost heights. Not lowering at all let a split that
///   over-allocates stand.
///
/// The LFE is the bed's own, delayed alongside.
///
/// Streaming: output frame i is input frame i. The first `latency` frames after a reset produce no
/// output, and `drain` returns the ones still inside.
final class BedSplitter {
    static let fftSize = 2048
    static let hop = 512
    static let latency = fftSize
    static let boundMargin: Float = 2
    static let boundMinShare: Float = 0.05
    static let balanceSmoothing: Float = 0.95
    static let balanceLimit: Float = 4
    /// A lowering is applied at this fraction of its size in dB.
    static let balanceLowering: Float = 1.0 / 3

    let layout: SpatialSpeakerLayout
    let bedRoles: [ObjectAudioRole]

    // MARK: Configuration

    private let n = BedSplitter.fftSize
    private let h = BedSplitter.hop
    private let bins = BedSplitter.fftSize / 2 + 1
    private let outputs: Int
    private let lfeOutput: Int
    /// Layout indices of the height speakers, and of the outputs that are split (all but the LFE).
    private let heights: [Int]
    private let positional: [Int]
    /// Bed planes: the LFE, and the ones split onto the layout.
    private let bedLFE: Int?
    private let splitBeds: [Int]
    /// Per split bed channel: its index in `bedPanner`'s layout (nil when the panner has no speaker
    /// for it), and the pairs (`pairs` indices) of floor outputs it covers, its primary one first.
    private let bedPannerIndex: [Int?]
    private let pairsOfBed: [[Int]]
    /// (split bed channel, floor output) for every floor output a bed channel covers.
    private let pairs: [(bed: Int, output: Int)]
    /// Pans a position into the bed's channels (ear level), and into the layout at ear level.
    private let bedPanner: AllocentricPanner
    private let layoutPanner: AllocentricPanner
    private let bandEdges: [Int]

    // MARK: State

    private var elementCount = 0
    private var elementHistory: [Float] = []
    private var bedHistory: [Float]
    private var elementHop: [Float] = []
    private var bedHop: [Float]
    private var filled = 0
    private var accumulators: [Float]
    private var lfeDelay: [Float]
    /// The `h` frames being handed out during the current hop.
    private var ready: [Float]
    private var consumed: Int64 = 0
    private var written: Int64 = 0

    /// Per element: the position and gain its ear-level and bed gains were computed for.
    private var cachedPosition: [SIMD3<Float>?] = []
    private var cachedGain: [Float] = []
    private var earGains: [Float] = []
    private var bedGains: [Float] = []
    private var snapshot = ObjectAudioGainSnapshot()
    private var hasSnapshot = false
    /// Element weights for the last three hops, the oldest used: a frame spans four hops, so its
    /// centre lies two hops back from the newest input.
    private var weightRing: [[Float]] = [[], [], []]
    private var ringNewest = 0
    private var ringCount = 0
    private let weightStride: Int

    private var smoothedTarget: [Float]
    private var smoothedSplit: [Float]

    // MARK: Scratch

    private let window: [Float]
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    private var frameBuf: [Float]
    private var evenBuf: [Float], oddBuf: [Float], specRe: [Float], specIm: [Float]
    private var power: [Float], scratch: [Float]
    private var bedRe: [Float], bedIm: [Float], bedPower: [Float]
    private var bedBandEnergy: [Float]
    private var den: [Float], floorNum: [Float], topNum: [Float], target: [Float]
    private var outRe: [Float], outIm: [Float], expect: [Float]

    init(layout: SpatialSpeakerLayout, bedRoles: [ObjectAudioRole]) {
        self.layout = layout
        self.bedRoles = bedRoles
        let speakers = layout.speakers
        outputs = speakers.count
        lfeOutput = layout.lfeIndex
        heights = speakers.indices.filter { speakers[$0].isHeight }
        positional = speakers.indices.filter { $0 != layout.lfeIndex }
        let floor = speakers.indices.filter { !speakers[$0].isHeight && $0 != layout.lfeIndex }

        bedLFE = bedRoles.firstIndex(of: .lfe)
        let beds: [(plane: Int, speaker: SpatialSpeaker?, position: SIMD3<Float>)] = bedRoles.indices.compactMap { i in
            switch bedRoles[i] {
            case .bed(let s) where !s.isHeight: return (i, s, s.position)
            case .fixed(let p) where p.z == 0: return (i, nil, p)
            default: return nil
            }
        }
        splitBeds = beds.map(\.plane)
        let bedLayout = SpatialSpeakerLayout.l916
        let bedSpeakers = Set(beds.compactMap(\.speaker))
        bedPanner = AllocentricPanner(
            layout: bedLayout, excluded: Set(bedLayout.speakers.filter { !bedSpeakers.contains($0) }))
        bedPannerIndex = beds.map { bed in bed.speaker.flatMap { bedLayout.speakers.firstIndex(of: $0) } }
        layoutPanner = AllocentricPanner(layout: layout)

        // A floor output takes the bed channels nearest to it; a bed channel no output is nearest to
        // goes to the outputs nearest to it. So a 7.1 bed maps one to one onto a 7.1 floor, a 5.1 bed's
        // surrounds cover a 7.1 layout's sides and rears, and a 7.1 bed's rears fold onto a 5.1 floor.
        func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            let d = SIMD2(a.x - b.x, a.y - b.y)
            return (d * d).sum()
        }
        var covered = [[Int]](repeating: [], count: beds.count)
        for o in floor {
            let p = speakers[o].position
            let distances = beds.map { distance($0.position, p) }
            guard let best = distances.min() else { continue }
            for (j, d) in distances.enumerated() where d <= best + 1e-6 { covered[j].append(o) }
        }
        for j in beds.indices where covered[j].isEmpty {
            let distances = floor.map { distance(beds[j].position, speakers[$0].position) }
            guard let best = distances.min() else { continue }
            covered[j] = floor.indices.filter { distances[$0] <= best + 1e-6 }.map { floor[$0] }
        }
        // The primary output (first) is the nearest one, where a bed channel no element explains goes.
        var pairs: [(bed: Int, output: Int)] = []
        var pairsOfBed = [[Int]](repeating: [], count: beds.count)
        for j in beds.indices {
            let sorted = covered[j].sorted { distance(beds[j].position, speakers[$0].position)
                < distance(beds[j].position, speakers[$1].position) }
            for o in sorted {
                pairsOfBed[j].append(pairs.count)
                pairs.append((j, o))
            }
        }
        self.pairs = pairs
        self.pairsOfBed = pairsOfBed

        var edges: [Int] = []
        for i in 0...24 {
            let e = Int(pow(Double(n / 2 + 1), Double(i) / 24).rounded())
            if edges.last != e { edges.append(e) }
        }
        edges[0] = 0
        bandEdges = edges

        // Per element: layout g² (outputs), its total over the positional outputs, its bed shares
        // (split beds), floor share per pair, top share per height.
        weightStride = outputs + 1 + beds.count + pairs.count + heights.count

        var w = [Float](repeating: 0, count: n)
        for i in 0..<n { w[i] = 0.5 - 0.5 * cos(2 * .pi * Float(i) / Float(n)) }
        window = w
        forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
        inverse = vDSP_DFT_zrop_CreateSetup(forward, vDSP_Length(n), .INVERSE)!
        let bedPlanes = bedRoles.count
        bedHistory = [Float](repeating: 0, count: bedPlanes * n)
        bedHop = [Float](repeating: 0, count: bedPlanes * h)
        accumulators = [Float](repeating: 0, count: outputs * n)
        lfeDelay = [Float](repeating: 0, count: n - h)
        ready = [Float](repeating: 0, count: outputs * h)
        frameBuf = [Float](repeating: 0, count: n)
        evenBuf = [Float](repeating: 0, count: n / 2)
        oddBuf = evenBuf; specRe = evenBuf; specIm = evenBuf
        power = [Float](repeating: 0, count: bins)
        scratch = power
        bedRe = [Float](repeating: 0, count: beds.count * bins)
        bedIm = bedRe; bedPower = bedRe; den = bedRe
        floorNum = [Float](repeating: 0, count: pairs.count * bins)
        topNum = [Float](repeating: 0, count: beds.count * heights.count * bins)
        target = [Float](repeating: 0, count: outputs * bins)
        outRe = target; outIm = target; expect = target
        bedBandEnergy = [Float](repeating: 0, count: beds.count * bandEdges.count)
        smoothedTarget = [Float](repeating: 0, count: outputs * bandEdges.count)
        smoothedSplit = smoothedTarget
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
    }

    /// Input frames taken that have not come out yet.
    var backlog: Int { Int(consumed - written) }

    /// Forget everything: the next input starts a new stream (a seek, a restart).
    func reset() {
        for i in elementHistory.indices { elementHistory[i] = 0 }
        for i in bedHistory.indices { bedHistory[i] = 0 }
        for i in accumulators.indices { accumulators[i] = 0 }
        for i in lfeDelay.indices { lfeDelay[i] = 0 }
        for i in ready.indices { ready[i] = 0 }
        for i in smoothedTarget.indices { smoothedTarget[i] = 0; smoothedSplit[i] = 0 }
        cachedPosition = Array(repeating: nil, count: elementCount)
        ringCount = 0
        hasSnapshot = false
        filled = 0
        consumed = 0
        written = 0
    }

    /// The elements' gains and positions from here on (`ObjectAudioRenderer.snapshot`).
    func setGains(_ source: ObjectAudioGainSnapshot) {
        snapshot = source
        hasSnapshot = true
    }

    /// Takes `frameCount` frames of elements and bed (nil for silence) and writes the output frames
    /// that are complete into `output` (one plane per layout channel), returning how many.
    @discardableResult
    func process(elements: [UnsafePointer<Float>]?, bed: [UnsafePointer<Float>]?, frameCount: Int,
                 output: [UnsafeMutablePointer<Float>]) -> Int {
        let count = elements?.count ?? elementCount
        if count != elementCount { resizeElements(count) }
        var taken = 0
        var out = 0
        while taken < frameCount {
            let take = min(h - filled, frameCount - taken)
            for c in 0..<elementCount {
                let dst = c * h + filled
                if let elements { elementHop.withUnsafeMutableBufferPointer { (($0.baseAddress! + dst)).update(from: elements[c] + taken, count: take) } }
                else { elementHop.withUnsafeMutableBufferPointer { ($0.baseAddress! + dst).update(repeating: 0, count: take) } }
            }
            for c in 0..<bedRoles.count {
                let dst = c * h + filled
                if let bed, c < bed.count { bedHop.withUnsafeMutableBufferPointer { ($0.baseAddress! + dst).update(from: bed[c] + taken, count: take) } }
                else { bedHop.withUnsafeMutableBufferPointer { ($0.baseAddress! + dst).update(repeating: 0, count: take) } }
            }
            // Output for these frames: `ready` holds the hop that came out of the last full frame.
            let skip = Int(max(0, min(Int64(take), Int64(Self.latency) - consumed)))
            if take > skip {
                for c in 0..<outputs {
                    ready.withUnsafeBufferPointer {
                        (output[c] + out).update(from: $0.baseAddress! + c * h + filled + skip, count: take - skip)
                    }
                }
                out += take - skip
            }
            consumed += Int64(take)
            filled += take
            taken += take
            if filled == h {
                filled = 0
                processHop()
            }
        }
        written += Int64(out)
        return out
    }

    /// Writes the frames still inside (at most `latency`) into `output` and returns how many. The
    /// splitter is reset afterwards.
    func drain(output: [UnsafeMutablePointer<Float>]) -> Int {
        let pending = backlog
        guard pending > 0 else { reset(); return 0 }
        var out = 0
        var remaining = Self.latency
        var cursor = output
        while remaining > 0, out < pending {
            let step = min(remaining, h)
            let got = process(elements: nil, bed: nil, frameCount: step, output: cursor)
            let keep = min(got, pending - out)
            out += keep
            cursor = cursor.map { $0 + keep }
            remaining -= step
        }
        reset()
        return out
    }

    private func resizeElements(_ count: Int) {
        elementCount = count
        elementHistory = [Float](repeating: 0, count: count * n)
        elementHop = [Float](repeating: 0, count: count * h)
        cachedPosition = Array(repeating: nil, count: count)
        cachedGain = [Float](repeating: 0, count: count)
        earGains = [Float](repeating: 0, count: count * outputs)
        bedGains = [Float](repeating: 0, count: count * bedPanner.layout.channelCount)
        for i in weightRing.indices { weightRing[i] = [Float](repeating: 0, count: count * weightStride) }
        ringCount = 0
    }

    // MARK: - Hop

    private func processHop() {
        shiftIn(&elementHistory, from: elementHop, channels: elementCount)
        shiftIn(&bedHistory, from: bedHop, channels: bedRoles.count)
        pushWeights()
        let weights = weightRing[(ringNewest + 3 - (ringCount - 1)) % 3]
        split(weights: ringCount > 0 ? weights : nil)
        emitHop()
    }

    private func shiftIn(_ history: inout [Float], from hopBuffer: [Float], channels: Int) {
        let n = self.n, h = self.h
        history.withUnsafeMutableBufferPointer { hist in
            hopBuffer.withUnsafeBufferPointer { hop in
                for c in 0..<channels {
                    let p = hist.baseAddress! + c * n
                    p.update(from: p + h, count: n - h)
                    (p + n - h).update(from: hop.baseAddress! + c * h, count: h)
                }
            }
        }
    }

    /// Derive this hop's element weights from the latest gains and push them on the ring.
    private func pushWeights() {
        guard hasSnapshot, snapshot.positions.count == elementCount,
              snapshot.layoutGains.count == elementCount * outputs else { return }
        ringNewest = (ringNewest + 1) % 3
        ringCount = min(ringCount + 1, 3)
        let bedChannels = bedPanner.layout.channelCount
        var ear = [Float](repeating: 0, count: outputs)
        var bedRow = [Float](repeating: 0, count: bedChannels)
        weightRing[ringNewest].withUnsafeMutableBufferPointer { w in
            for k in 0..<elementCount {
                let base = k * weightStride
                for i in 0..<weightStride { w[base + i] = 0 }
                guard let position = snapshot.positions[k] else { continue }
                let gain = snapshot.gains[k]
                if cachedPosition[k] != position || cachedGain[k] != gain {
                    cachedPosition[k] = position
                    cachedGain[k] = gain
                    let floor = SIMD3(position.x, position.y, 0)
                    for i in ear.indices { ear[i] = 0 }
                    layoutPanner.pointGains(floor, into: &ear)
                    for i in bedRow.indices { bedRow[i] = 0 }
                    bedPanner.pointGains(floor, into: &bedRow)
                    for i in 0..<outputs { earGains[k * outputs + i] = ear[i] * gain }
                    for i in 0..<bedChannels { bedGains[k * bedChannels + i] = bedRow[i] * gain }
                }
                var total: Float = 0
                for c in positional {
                    let g = snapshot.layoutGains[k * outputs + c]
                    w[base + c] = g * g
                    total += g * g
                }
                guard total > 0 else { continue }
                w[base + outputs] = total
                var above: Float = 0
                let tops = base + outputs + 1 + splitBeds.count + pairs.count
                for (t, c) in heights.enumerated() {
                    w[tops + t] = w[base + c] / total
                    above += w[tops + t]
                }
                let shares = base + outputs + 1
                for j in splitBeds.indices {
                    if let i = bedPannerIndex[j] {
                        let g = bedGains[k * bedChannels + i]
                        w[shares + j] = g * g
                    }
                }
                let floorShares = shares + splitBeds.count
                for j in splitBeds.indices {
                    var sum: Float = 0
                    for p in pairsOfBed[j] { let e = earGains[k * outputs + pairs[p].output]; sum += e * e }
                    for (rank, p) in pairsOfBed[j].enumerated() {
                        let e = earGains[k * outputs + pairs[p].output]
                        let share = sum > 0 ? e * e / sum : (rank == 0 ? 1 : 0)
                        w[floorShares + p] = share * (1 - above)
                    }
                }
            }
        }
    }

    /// Windowed real FFT of `n` frames at `source`, into `specRe`/`specIm` (zrop packing).
    private func spectrum(_ source: UnsafePointer<Float>) {
        frameBuf.withUnsafeMutableBufferPointer { f in
            vDSP_vmul(source, 1, window, 1, f.baseAddress!, 1, vDSP_Length(n))
        }
        frameBuf.withUnsafeBufferPointer { f in
            evenBuf.withUnsafeMutableBufferPointer { e in
                oddBuf.withUnsafeMutableBufferPointer { o in
                    f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { c in
                        var split = DSPSplitComplex(realp: e.baseAddress!, imagp: o.baseAddress!)
                        vDSP_ctoz(c, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
            }
        }
        vDSP_DFT_Execute(forward, evenBuf, oddBuf, &specRe, &specIm)
    }

    /// Unpack `specRe`/`specIm` into `bins` real and imaginary values at `re`/`im`.
    private func unpack(re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>) {
        let half = n / 2
        specRe.withUnsafeBufferPointer { r in
            specIm.withUnsafeBufferPointer { i in
                re.update(from: r.baseAddress!, count: half)
                im.update(from: i.baseAddress!, count: half)
                re[half] = i[0]
                im[0] = 0
                im[half] = 0
            }
        }
    }

    private func split(weights: [Float]?) {
        let bins = self.bins, B = splitBeds.count, H = heights.count
        let nb = vDSP_Length(bins)
        let tiny: Float = 1e-20

        // Bed spectra and powers.
        bedHistory.withUnsafeBufferPointer { hist in
            bedRe.withUnsafeMutableBufferPointer { re in
                bedIm.withUnsafeMutableBufferPointer { im in
                    for j in 0..<B {
                        spectrum(hist.baseAddress! + splitBeds[j] * n)
                        unpack(re: re.baseAddress! + j * bins, im: im.baseAddress! + j * bins)
                    }
                }
            }
        }
        bedPower.withUnsafeMutableBufferPointer { p in
            vDSP_vmma(bedRe, 1, bedRe, 1, bedIm, 1, bedIm, 1, p.baseAddress!, 1, vDSP_Length(B * bins))
        }
        zero(&den); zero(&floorNum); zero(&topNum); zero(&target)
        let bands = bandEdges.count - 1
        for j in 0..<B {
            for band in 0..<bands {
                let lo = bandEdges[band], hi = min(bandEdges[band + 1], bins)
                var e: Float = 0
                if lo < hi { bedPower.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + j * bins + lo, 1, &e, vDSP_Length(hi - lo)) } }
                bedBandEnergy[j * bands + band] = e
            }
        }

        if let weights {
            var re = [Float](repeating: 0, count: bins), im = re
            for k in 0..<elementCount {
                let base = k * weightStride
                let total = weights[base + outputs]
                let shares = base + outputs + 1
                guard total > 0 else { continue }
                var shareSum: Float = 0
                for j in 0..<B { shareSum += weights[shares + j] }
                guard shareSum > 0 else { continue }
                elementHistory.withUnsafeBufferPointer { spectrum($0.baseAddress! + k * n) }
                re.withUnsafeMutableBufferPointer { r in
                    im.withUnsafeMutableBufferPointer { i in unpack(re: r.baseAddress!, im: i.baseAddress!) }
                }
                vDSP_vmma(re, 1, re, 1, im, 1, im, 1, &power, 1, nb)
                // The bed bound, per band, from every bed channel the element puts a real part of
                // itself in. Per band rather than per bin: in a single bin the bed can hold less than
                // one element, where several cancel in Dolby's mix, and a per-bin bound cut those.
                for band in 0..<bands {
                    let lo = bandEdges[band], hi = min(bandEdges[band + 1], bins)
                    guard lo < hi else { continue }
                    var e: Float = 0
                    vDSP_sve(power.withUnsafeBufferPointer { $0.baseAddress! + lo }, 1, &e, vDSP_Length(hi - lo))
                    guard e > 0 else { continue }
                    var limit = Float.infinity
                    for j in 0..<B where weights[shares + j] > Self.boundMinShare * shareSum {
                        limit = min(limit, Self.boundMargin * bedBandEnergy[j * bands + band] / weights[shares + j])
                    }
                    if e > limit {
                        var f = limit / e
                        power.withUnsafeMutableBufferPointer { vDSP_vsmul($0.baseAddress! + lo, 1, &f, $0.baseAddress! + lo, 1, vDSP_Length(hi - lo)) }
                    }
                }
                target.withUnsafeMutableBufferPointer { t in
                    for c in positional {
                        var g = weights[base + c]
                        if g > 0 { vDSP_vsma(power, 1, &g, t.baseAddress! + c * bins, 1, t.baseAddress! + c * bins, 1, nb) }
                    }
                }
                let floorShares = shares + B
                let tops = floorShares + pairs.count
                for j in 0..<B {
                    let a = weights[shares + j]
                    if a == 0 { continue }
                    var w = a
                    den.withUnsafeMutableBufferPointer { vDSP_vsma(power, 1, &w, $0.baseAddress! + j * bins, 1, $0.baseAddress! + j * bins, 1, nb) }
                    floorNum.withUnsafeMutableBufferPointer { f in
                        for p in pairsOfBed[j] {
                            var s = a * weights[floorShares + p]
                            if s > 0 { vDSP_vsma(power, 1, &s, f.baseAddress! + p * bins, 1, f.baseAddress! + p * bins, 1, nb) }
                        }
                    }
                    topNum.withUnsafeMutableBufferPointer { t in
                        for ti in 0..<H {
                            var s = a * weights[tops + ti]
                            let row = (j * H + ti) * bins
                            if s > 0 { vDSP_vsma(power, 1, &s, t.baseAddress! + row, 1, t.baseAddress! + row, 1, nb) }
                        }
                    }
                }
            }
        }


        // Each bed channel, split by those shares: a bin no element explains stays on the channel's
        // primary floor output.
        zero(&outRe); zero(&outIm); zero(&expect)
        var eps = tiny
        var dSafe = [Float](repeating: 0, count: bins), share = dSafe, gain = dSafe
        for j in 0..<B {
            den.withUnsafeBufferPointer { vDSP_vsadd($0.baseAddress! + j * bins, 1, &eps, &dSafe, 1, nb) }
            func add(_ output: Int, num: UnsafePointer<Float>?, primary: Bool) {
                if let num {
                    if primary {
                        vDSP_vsadd(num, 1, &eps, &share, 1, nb)
                        vDSP_vdiv(dSafe, 1, share, 1, &share, 1, nb)
                    } else {
                        vDSP_vdiv(dSafe, 1, num, 1, &share, 1, nb)
                    }
                }
                var count = Int32(bins)
                vvsqrtf(&gain, share, &count)
                let row = output * bins, bedRow = j * bins
                outRe.withUnsafeMutableBufferPointer { o in
                    bedRe.withUnsafeBufferPointer { vDSP_vma($0.baseAddress! + bedRow, 1, gain, 1, o.baseAddress! + row, 1, o.baseAddress! + row, 1, nb) }
                }
                outIm.withUnsafeMutableBufferPointer { o in
                    bedIm.withUnsafeBufferPointer { vDSP_vma($0.baseAddress! + bedRow, 1, gain, 1, o.baseAddress! + row, 1, o.baseAddress! + row, 1, nb) }
                }
                expect.withUnsafeMutableBufferPointer { e in
                    bedPower.withUnsafeBufferPointer { vDSP_vma($0.baseAddress! + bedRow, 1, share, 1, e.baseAddress! + row, 1, e.baseAddress! + row, 1, nb) }
                }
            }
            floorNum.withUnsafeBufferPointer { f in
                for (rank, p) in pairsOfBed[j].enumerated() {
                    add(pairs[p].output, num: f.baseAddress! + p * bins, primary: rank == 0)
                }
            }
            topNum.withUnsafeBufferPointer { t in
                for (ti, c) in heights.enumerated() {
                    add(c, num: t.baseAddress! + (j * H + ti) * bins, primary: false)
                }
            }
        }

        // An output fed by several bed channels sums them coherently; set each bin's energy to the
        // shares' sum.
        for c in positional {
            let row = c * bins
            for b in 0..<bins {
                let got = outRe[row + b] * outRe[row + b] + outIm[row + b] * outIm[row + b]
                let fix: Float = got > tiny ? (expect[row + b] / got).squareRoot() : 1
                outRe[row + b] *= fix
                outIm[row + b] *= fix
            }
        }

        // Balance per output and band, towards the energy a direct render would give it.
        let a = Self.balanceSmoothing
        for band in 0..<bands {
            let lo = bandEdges[band], hi = min(bandEdges[band + 1], bins)
            guard lo < hi else { continue }
            for c in positional {
                var t: Float = 0, e: Float = 0
                let row = c * bins
                for b in lo..<hi { t += target[row + b]; e += expect[row + b] }
                let slot = c * bands + band
                smoothedTarget[slot] = a * smoothedTarget[slot] + (1 - a) * t
                smoothedSplit[slot] = a * smoothedSplit[slot] + (1 - a) * e
                let st = smoothedTarget[slot], se = smoothedSplit[slot]
                guard st > tiny, se > tiny else { continue }
                let r = st / se
                let g = (r >= 1 ? min(r, Self.balanceLimit) : pow(r, Self.balanceLowering)).squareRoot()
                for b in lo..<hi { outRe[row + b] *= g; outIm[row + b] *= g }
            }
        }

        // Back to the time domain, overlap-added.
        let half = n / 2
        var scale = 1 / (2 * Float(n) * 1.5)
        for c in positional {
            let row = c * bins
            outRe.withUnsafeBufferPointer { r in specRe.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: r.baseAddress! + row, count: half) } }
            outIm.withUnsafeBufferPointer { i in specIm.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: i.baseAddress! + row, count: half) } }
            specIm[0] = outRe[row + half]
            vDSP_DFT_Execute(inverse, specRe, specIm, &evenBuf, &oddBuf)
            evenBuf.withUnsafeMutableBufferPointer { e in
                oddBuf.withUnsafeMutableBufferPointer { o in
                    frameBuf.withUnsafeMutableBufferPointer { f in
                        f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cplx in
                            var s = DSPSplitComplex(realp: e.baseAddress!, imagp: o.baseAddress!)
                            vDSP_ztoc(&s, 1, cplx, 2, vDSP_Length(half))
                        }
                    }
                }
            }
            vDSP_vmul(frameBuf, 1, window, 1, &frameBuf, 1, vDSP_Length(n))
            accumulators.withUnsafeMutableBufferPointer { acc in
                vDSP_vsma(frameBuf, 1, &scale, acc.baseAddress! + c * n, 1, acc.baseAddress! + c * n, 1, vDSP_Length(n))
            }
        }
    }

    /// The oldest hop of every accumulator, and the LFE `latency` back, into `ready`.
    private func emitHop() {
        let n = self.n, h = self.h
        ready.withUnsafeMutableBufferPointer { r in
            accumulators.withUnsafeMutableBufferPointer { acc in
                for c in positional {
                    let a = acc.baseAddress! + c * n
                    (r.baseAddress! + c * h).update(from: a, count: h)
                    a.update(from: a + h, count: n - h)
                    (a + n - h).update(repeating: 0, count: h)
                }
            }
            // The newest hop enters `n - h` back and leaves three hops later, for the hop after
            // that: `latency` frames, like the split outputs.
            lfeDelay.withUnsafeMutableBufferPointer { d in
                let p = d.baseAddress!, length = n - h
                (r.baseAddress! + lfeOutput * h).update(from: p, count: h)
                p.update(from: p + h, count: length - h)
                if let bedLFE {
                    bedHistory.withUnsafeBufferPointer { (p + length - h).update(from: $0.baseAddress! + bedLFE * n + n - h, count: h) }
                } else {
                    (p + length - h).update(repeating: 0, count: h)
                }
            }
        }
    }

    private func zero(_ a: inout [Float]) {
        a.withUnsafeMutableBufferPointer { vDSP_vclr($0.baseAddress!, 1, vDSP_Length($0.count)) }
    }
}
#endif
