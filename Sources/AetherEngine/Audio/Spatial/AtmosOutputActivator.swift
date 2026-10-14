import AVFoundation

/// Keeps a tvOS HDMI route in Dolby Atmos while the engine's `AVPlayer` plays an APAC track.
///
/// tvOS hands APAC to the receiver as Dolby MAT, and some sinks show Dolby Atmos for that on their own.
/// Not all do: a Samsung HW-Q990C fed by an Apple TV 4K (tvOS 27.2) played APAC without ever showing
/// Atmos, although `AVAudioSession` reported a MAT format throughout. A second, unmuted player looping
/// a silent E-AC-3 stream signalled as Dolby Atmos brought it to Atmos before the first frame and kept
/// it there across a seek. Nothing the app can read tracked the indicator; only the sink shows it.
///
/// The stream (`Resources/silent-atmos.mp4`, written bit by bit by `Scripts/make-silent-atmos.swift`)
/// decodes to digital silence, so nothing is mixed into the programme. It plays only while the host
/// player plays or waits to play an item `playsAPAC` accepts, and is released otherwise, since a
/// prerolled E-AC-3 stream would compete with other audio.
@MainActor
final class AtmosOutputActivator {
    static let silentAtmosStream = Bundle.module.url(forResource: "silent-atmos", withExtension: "mp4")!

    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private weak var host: AVPlayer?
    private var playsAPAC: @MainActor (AVPlayerItem) -> Bool = { _ in false }
    private var observations: [NSKeyValueObservation] = []
    private var selectionObserver: NSObjectProtocol?

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
    }

    /// Follows `host`: its item, its audio selection and whether it is playing.
    func attach(to host: AVPlayer, playsAPAC: @escaping @MainActor (AVPlayerItem) -> Bool) {
        detach()
        self.host = host
        self.playsAPAC = playsAPAC
        // A host play() changes timeControlStatus synchronously on the main thread, so the stream
        // starts inside that call, ahead of the APAC output.
        observations = [
            host.observe(\.currentItem, options: [.initial]) { [weak self] _, _ in
                Self.onMain { self?.follow(self?.host?.currentItem) }
            },
            host.observe(\.timeControlStatus) { [weak self] _, _ in
                Self.onMain { self?.update() }
            },
        ]
    }

    func detach() {
        observations.forEach { $0.invalidate() }
        observations = []
        host = nil
        follow(nil)
    }

    private func follow(_ item: AVPlayerItem?) {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = item.map {
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: $0, queue: .main
            ) { [weak self] _ in
                Self.onMain { self?.update() }
            }
        }
        update()
    }

    private func update() {
        guard let host, let item = host.currentItem, playsAPAC(item) else {
            release()
            return
        }
        guard host.timeControlStatus != .paused else {
            player.pause()
            return
        }
        if looper == nil {
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: Self.silentAtmosStream))
        }
        player.play()
    }

    private func release() {
        guard let looper else { return }
        player.pause()
        looper.disableLooping()
        self.looper = nil
        player.removeAllItems()
    }

    private nonisolated static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in body() }
        }
    }
}

extension AetherEngine {
    /// tvOS only: the switch is an HDMI one, and on iOS and macOS a second unmuted player beside the
    /// engine's would compete with it for Now Playing and the audio session for no gain.
    func followAtmosOutput() {
        #if os(tvOS)
        guard let player = currentAVPlayer else {
            atmosOutputActivator?.detach()
            return
        }
        let activator = atmosOutputActivator ?? AtmosOutputActivator()
        atmosOutputActivator = activator
        activator.attach(to: player) { [weak self] _ in self?.nativeVideoSession?.audioIsAPAC == true }
        #endif
    }

    /// #597: a media services reset invalidates the activator's own `AVQueuePlayer` along with the engine's,
    /// and the engine only rebuilds its own. Dropped here, the next `currentAVPlayer` builds a fresh one.
    func dropAtmosOutputActivator() {
        atmosOutputActivator?.detach()
        atmosOutputActivator = nil
    }
}
