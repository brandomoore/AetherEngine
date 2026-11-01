import AVFoundation

extension AetherEngine {
    #if DEBUG
        public var activePicturePeakWorkersForTesting: Int { ActivePictureAnalysis.peakWorkers }
        public var activePictureWorkersForTesting: Int { ActivePictureAnalysis.admittedWorkers }
    #endif
    /// Opt-in, at most 2 Hz. Call only while a local consumer needs the result.
    /// Both subtitle placement and video fitting must share this operation.
    public func sampleActivePicture() async -> ActivePictureState {
        await activePictureAnalysis.sample(engine: self)
    }

    /// Releases the native output tap and invalidates outstanding analysis.
    public func stopActivePictureAnalysis() {
        activePictureAnalysis.reset(detach: true)
    }
}

/// Opt-in analysis for hosts that already own an AVPlayer. This shares the
/// engine's worker budget and does not create a player or another decoder.
@MainActor
public final class NativeActivePictureAnalyzer {
    private let analysis = ActivePictureAnalysis()

    public init() {}

    public func sample(player: AVPlayer, generation: UInt64, videoFormat: VideoFormat? = nil) async
        -> ActivePictureState
    {
        await analysis.sample(source: .native(player, generation, videoFormat))
    }

    public func stop() {
        analysis.reset(detach: true, clearTimeline: true)
    }
}

@MainActor
enum ActivePictureSource {
    case engine(AetherEngine)
    case native(AVPlayer, UInt64, VideoFormat?)

    var engine: AetherEngine? {
        if case .engine(let engine) = self { return engine }
        return nil
    }

    var player: AVPlayer? {
        switch self {
        case .engine(let engine): engine.currentAVPlayer
        case .native(let player, _, _): player
        }
    }

    var loadGeneration: UInt64 {
        switch self {
        case .engine(let engine): engine.loadGeneration
        case .native(_, let generation, _): generation
        }
    }

    var nativePixelFormat: OSType {
        let format: VideoFormat?
        switch self {
        case .engine(let engine): format = engine.videoFormat
        case .native(_, _, let value): format = value
        }
        switch format {
        case .sdr: return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .hdr10, .hdr10Plus, .hlg: return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .dolbyVision, nil:
            // Request converted RGB, never interpret a Profile 5/10 IPT
            // base layer as ordinary PQ YCbCr.
            return kCVPixelFormatType_64RGBAHalf
        }
    }
}

private struct ActivePictureOwner: Equatable {
    let load: UInt64
    let seek: UInt64
    let software: UInt64?
    let native: ObjectIdentifier?
    let nativeEpoch: UInt64?
    let nativePixelFormat: OSType?
}

@MainActor
final class ActivePictureAnalysis {
    let nativeTimeline = ActivePictureTimeline()
    static var admittedWorkers = 0
    #if DEBUG
        static var peakWorkers = 0
    #endif
    private var owner: ActivePictureOwner?
    private var revision: UInt64 = 0
    private var stability = ActivePictureStability()
    private var geometry: ActivePictureGeometry?
    private var pending: (pixels: ActivePicturePixels, time: Double)?
    private var lastSampleTime: Double?
    private var lastAttempt: TimeInterval = -.infinity
    private var lastPlayhead: Double?
    private var busy = false
    private var failure = ActivePictureState.UnknownReason.insufficientEvidence
    private var item: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private var timeJumpObserver: NSObjectProtocol?
    private var nativeTransform: CGAffineTransform?

    isolated deinit { reset(detach: true) }

    func reset(detach: Bool = false, clearTimeline: Bool = false) {
        if clearTimeline { nativeTimeline.reset() }
        revision &+= 1
        stability = ActivePictureStability()
        geometry = nil
        pending = nil
        lastSampleTime = nil
        lastPlayhead = nil
        failure = .discontinuity
        if detach {
            if let timeJumpObserver { NotificationCenter.default.removeObserver(timeJumpObserver) }
            timeJumpObserver = nil
            if let output { item?.remove(output) }
            output = nil
            item = nil
            nativeTransform = nil
            owner = nil
        }
    }

    private func identity(_ source: ActivePictureSource) -> ActivePictureOwner {
        ActivePictureOwner(
            load: source.loadGeneration, seek: source.engine?.currentSeekGeneration ?? 0,
            software: source.engine?.softwareHost?.activePictureGeneration,
            native: source.player?.currentItem.map(ObjectIdentifier.init),
            nativeEpoch: source.player.map { nativeTimeline.generation(at: $0.currentTime().seconds) }
                ?? nil,
            nativePixelFormat: source.player == nil ? nil : source.nativePixelFormat)
    }

    private func playhead(_ source: ActivePictureSource) -> Double {
        source.player?.currentTime().seconds ?? source.engine?.softwareHost?.sourceClockSeconds ?? .nan
    }

    private func state(at time: Double) -> ActivePictureState {
        guard let geometry, let rect = stability.rect(at: time),
            let evidenceTime = stability.evidenceTime
        else {
            return .unknown(stability.accepted == nil ? failure : .expired)
        }
        let upright = geometry.upright(rect, transform: nativeTransform ?? .identity)
        return .measured(
            ActivePictureObservation(
                normalizedRect: upright.rect, displaySize: upright.size, evidence: .sampledPixels,
                presentationTime: evidenceTime,
                validUntil: evidenceTime + ActivePictureStability.maximumAge,
                generation: revision
            ))
    }

    private func consumePending(at time: Double) {
        guard let pending, time >= pending.time else { return }
        self.pending = nil
        guard time - pending.time <= ActivePictureStability.maximumAge else { return }
        if let reason = pending.pixels.failure {
            reset()
            failure = reason
            return
        }
        if let next = pending.pixels.geometry {
            if geometry != next {
                stability = ActivePictureStability()
                geometry = next
                revision &+= 1
            }
            stability.record(pending.pixels.bounds, at: pending.time)
        }
        failure = pending.pixels.failure ?? .insufficientEvidence
    }

    private func ineligibility(_ source: ActivePictureSource) -> ActivePictureState.UnknownReason? {
        if let engine = source.engine {
            guard engine.isSessionReady, engine.hasFirstFrameReadyForDisplay, !engine.isSeeking,
                !engine.pictureInPictureActive
            else { return .unavailable }
        } else {
            guard source.player?.currentItem?.status == .readyToPlay else { return .unavailable }
        }
        #if !os(visionOS)
            guard source.player?.isExternalPlaybackActive != true else {
                return .unavailable
            }
        #endif
        return nil
    }

    func sample(engine: AetherEngine) async -> ActivePictureState {
        await sample(source: .engine(engine))
    }

    func sample(source: ActivePictureSource) async -> ActivePictureState {
        guard !Task.isCancelled else { return .unknown(.disabled) }
        if let reason = ineligibility(source) {
            reset(detach: true)
            return .unknown(reason)
        }
        let currentOwner = identity(source)
        if owner != currentOwner {
            reset(detach: true)
            owner = currentOwner
        }
        guard let frameGeneration = currentOwner.software ?? currentOwner.nativeEpoch else {
            reset(detach: true)
            return .unknown(.discontinuity)
        }
        let time = playhead(source)
        guard time.isFinite else { return .unknown(.unavailable) }
        if let lastPlayhead, time < lastPlayhead || time - lastPlayhead > 3 {
            reset()
        }
        lastPlayhead = time
        consumePending(at: time)
        let now = ProcessInfo.processInfo.systemUptime
        guard !busy, pending == nil, now - lastAttempt >= 0.5, Self.admittedWorkers < 4 else {
            return state(at: time)
        }
        busy = true
        Self.admittedWorkers += 1
        #if DEBUG
            Self.peakWorkers = max(Self.peakWorkers, Self.admittedWorkers)
        #endif
        lastAttempt = now
        defer {
            busy = false
            Self.admittedWorkers -= 1
        }
        let token = revision
        let frame: ActivePictureFrame?
        if let player = source.player, let currentItem = player.currentItem {
            if item !== currentItem {
                item = currentItem
                // Ask AVFoundation for display-referred, CPU-readable pixels.
                // Wide color preserves HDR rather than forcing an SDR tap.
                let newOutput = AVPlayerItemVideoOutput(outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: source.nativePixelFormat,
                    AVVideoAllowWideColorKey: true,
                ])
                newOutput.suppressesPlayerRendering = false
                currentItem.add(newOutput)
                output = newOutput
                timeJumpObserver = NotificationCenter.default.addObserver(
                    forName: AVPlayerItem.timeJumpedNotification, object: currentItem, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reset() }
                }
            }
            if nativeTransform == nil {
                // Output pixels do not encode a track's display rotation.
                if let track = currentItem.tracks.compactMap(\.assetTrack).first(where: {
                    $0.mediaType == .video
                }) {
                    do {
                        let transform = try await track.load(.preferredTransform)
                        if let reason = ineligibility(source) {
                            reset(detach: true)
                            return .unknown(reason)
                        }
                        guard token == revision, identity(source) == currentOwner, !Task.isCancelled else {
                            return .unknown(.discontinuity)
                        }
                        guard ActivePictureGeometry.supports(transform) else {
                            return .unknown(.unsupportedGeometry)
                        }
                        nativeTransform = CGAffineTransform(
                            a: transform.a, b: transform.b,
                            c: transform.c, d: transform.d, tx: 0, ty: 0)
                    } catch {
                        EngineLog.emit(
                            "[AetherEngine] active picture: native display transform unavailable",
                            category: .engine)
                        return .unknown(.unsupportedGeometry)
                    }
                }
            }
            guard nativeTransform != nil else { return .unknown(.unsupportedGeometry) }
            let requested = player.currentTime()
            var displayed = CMTime.invalid
            if let output, output.hasNewPixelBuffer(forItemTime: requested),
                let buffer = output.copyPixelBuffer(forItemTime: requested, itemTimeForDisplay: &displayed),
                displayed.isNumeric, displayed.seconds <= requested.seconds,
                nativeTimeline.generation(at: displayed.seconds) == frameGeneration,
                requested.seconds - displayed.seconds <= ActivePictureStability.maximumAge
            {
                frame = ActivePictureFrame(
                    buffer: buffer, time: displayed.seconds, generation: frameGeneration)
            } else {
                frame = nil
            }
        } else {
            frame = source.engine?.softwareHost?.activePictureFrame
        }
        guard let frame, frame.time.isFinite, lastSampleTime.map({ frame.time > $0 }) ?? true,
            frameGeneration == frame.generation,
            frame.time - time <= ActivePictureStability.maximumAge,
            time - frame.time <= ActivePictureStability.maximumAge
        else {
            return state(at: playhead(source))
        }
        lastSampleTime = frame.time
        let pixels = await ActivePictureWorker.shared.analyze(frame)
        if let reason = ineligibility(source) {
            reset(detach: true)
            return .unknown(reason)
        }
        guard token == revision, currentOwner == identity(source), !Task.isCancelled else {
            return .unknown(.discontinuity)
        }
        pending = (pixels, frame.time)
        let presented = playhead(source)
        consumePending(at: presented)
        return state(at: presented)
    }
}
