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

private struct ActivePictureOwner: Equatable {
    let load: UInt64
    let seek: UInt64
    let software: UInt64?
    let native: ObjectIdentifier?
    let nativeEpoch: UInt64?
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
    private var nativeGeometrySupported: Bool?

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
            nativeGeometrySupported = nil
            owner = nil
        }
    }

    private func identity(_ engine: AetherEngine) -> ActivePictureOwner {
        ActivePictureOwner(load: engine.loadGeneration, seek: engine.currentSeekGeneration,
                           software: engine.softwareHost?.activePictureGeneration,
                           native: engine.currentAVPlayer?.currentItem.map(ObjectIdentifier.init),
                           nativeEpoch: engine.currentAVPlayer.map { nativeTimeline.generation(at: $0.currentTime().seconds) } ?? nil)
    }

    private func playhead(_ engine: AetherEngine) -> Double {
        engine.currentAVPlayer?.currentTime().seconds ?? engine.softwareHost?.sourceClockSeconds ?? .nan
    }

    private func state(at time: Double) -> ActivePictureState {
        guard let geometry, let rect = stability.rect(at: time), let evidenceTime = stability.evidenceTime
        else {
            return .unknown(stability.accepted == nil ? failure : .expired)
        }
        return .measured(ActivePictureObservation(
            normalizedRect: rect, displaySize: geometry.displaySize, evidence: .sampledPixels,
            presentationTime: evidenceTime, validUntil: evidenceTime + ActivePictureStability.maximumAge,
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

    private func ineligibility(_ engine: AetherEngine) -> ActivePictureState.UnknownReason? {
        guard engine.isSessionReady, engine.hasFirstFrameReadyForDisplay, !engine.isSeeking,
              !engine.pictureInPictureActive else {
            return .unavailable
        }
        #if !os(visionOS)
        guard engine.currentAVPlayer?.isExternalPlaybackActive != true else {
            return .unavailable
        }
        #endif
        guard engine.videoFormat == .sdr else {
            return .unsupportedColor
        }
        return nil
    }

    func sample(engine: AetherEngine) async -> ActivePictureState {
        guard !Task.isCancelled else { return .unknown(.disabled) }
        if let reason = ineligibility(engine) {
            reset(detach: true)
            return .unknown(reason)
        }
        let currentOwner = identity(engine)
        if owner != currentOwner {
            reset(detach: true)
            owner = currentOwner
        }
        guard let frameGeneration = currentOwner.software ?? currentOwner.nativeEpoch else {
            reset(detach: true)
            return .unknown(.discontinuity)
        }
        let time = playhead(engine)
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
        defer { busy = false; Self.admittedWorkers -= 1 }
        let token = revision
        let frame: ActivePictureFrame?
        if let player = engine.currentAVPlayer, let currentItem = player.currentItem {
            if item !== currentItem {
                item = currentItem
                let newOutput = AVPlayerItemVideoOutput(outputSettings: nil)
                newOutput.suppressesPlayerRendering = false
                currentItem.add(newOutput)
                output = newOutput
                timeJumpObserver = NotificationCenter.default.addObserver(
                    forName: AVPlayerItem.timeJumpedNotification, object: currentItem, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reset() }
                }
            }
            if nativeGeometrySupported == nil {
                // Output pixels do not encode a track's display rotation.
                if let track = currentItem.tracks.compactMap(\.assetTrack).first(where: { $0.mediaType == .video }) {
                    do {
                        let transform = try await track.load(.preferredTransform)
                        if let reason = ineligibility(engine) {
                            reset(detach: true)
                            return .unknown(reason)
                        }
                        guard token == revision, identity(engine) == currentOwner, !Task.isCancelled else {
                            return .unknown(.discontinuity)
                        }
                        nativeGeometrySupported = transform == .identity
                    } catch {
                        EngineLog.emit("[AetherEngine] active picture: native display transform unavailable", category: .engine)
                        return .unknown(.unsupportedGeometry)
                    }
                }
            }
            guard nativeGeometrySupported == true else { return .unknown(.unsupportedGeometry) }
            let requested = player.currentTime()
            var displayed = CMTime.invalid
            if let output, output.hasNewPixelBuffer(forItemTime: requested),
               let buffer = output.copyPixelBuffer(forItemTime: requested, itemTimeForDisplay: &displayed),
               displayed.isNumeric, displayed.seconds <= requested.seconds,
               nativeTimeline.generation(at: displayed.seconds) == frameGeneration,
               requested.seconds - displayed.seconds <= ActivePictureStability.maximumAge {
                frame = ActivePictureFrame(buffer: buffer, time: displayed.seconds, generation: frameGeneration)
            } else {
                frame = nil
            }
        } else {
            frame = engine.softwareHost?.activePictureFrame
        }
        guard let frame, frame.time.isFinite, lastSampleTime.map({ frame.time > $0 }) ?? true,
              frameGeneration == frame.generation,
              frame.time - time <= ActivePictureStability.maximumAge,
              time - frame.time <= ActivePictureStability.maximumAge else {
            return state(at: playhead(engine))
        }
        lastSampleTime = frame.time
        let pixels = await ActivePictureWorker.shared.analyze(frame)
        if let reason = ineligibility(engine) {
            reset(detach: true)
            return .unknown(reason)
        }
        guard token == revision, currentOwner == identity(engine), !Task.isCancelled else {
            return .unknown(.discontinuity)
        }
        pending = (pixels, frame.time)
        let presented = playhead(engine)
        consumePending(at: presented)
        return state(at: presented)
    }
}
