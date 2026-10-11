import Foundation
import AVFoundation
import CoreAudioTypes

/// The audio route as one log fragment, shared by every host that writes a route line, so the native and
/// the software path describe the same route in the same words and a diff between their logs is a diff
/// of routes, not of formats.
enum AudioRouteDescription {

    /// `output=… preferred=… max=… rendering=… multichannelContent=… ports=[type[ch=n, labels=…,
    /// heights=n], …] latency=…ms io=…ms`, or nil where there is no `AVAudioSession`. The output latency is
    /// the field AE#395 needs: a buffered AirPlay route delays sound by seconds where HDMI delays it by
    /// milliseconds, and a feed that is fine on one is late on the other.
    ///
    /// `rendering` and the port's channel labels are what a missing-heights report turns on: the
    /// rendering mode is the system's own word for what it does with the audio (`dolbyAtmos` against
    /// `surround` or `spatialAudio`), and the labels are the speakers the route reports. Read the two
    /// together: a Dolby MAT carrier can report fewer channels than it carries (AE#520), so `heights=0`
    /// next to `rendering=dolbyAtmos` proves nothing on its own, while `heights=0` next to `surround`
    /// is a route with no height channels at all.
    ///
    /// Ports are named by type, never by `portName`: for AirPods, Bluetooth and AirPlay that is
    /// whatever the user called the device, and an HDMI sink's name can be a renamed CEC name. The
    /// line reaches the host's handler and from there diagnostics reports, and no host-side scrub of
    /// a free-text name inside it can be made reliable.
    static func current() -> String? {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        let ports = session.currentRoute.outputs.map(portDescription).joined(separator: ", ")
        return "output=\(session.outputNumberOfChannels) preferred=\(session.preferredOutputNumberOfChannels) "
            + "max=\(session.maximumOutputNumberOfChannels) rendering=\(renderingModeName(session.renderingMode)) "
            + "multichannelContent=\(session.supportsMultichannelContent) ports=[\(ports)] "
            + "latency=\(String(format: "%.0f", session.outputLatency * 1000))ms "
            + "io=\(String(format: "%.1f", session.ioBufferDuration * 1000))ms"
        #else
        return nil
        #endif
    }

    #if os(iOS) || os(tvOS)
    private static func portDescription(_ port: AVAudioSessionPortDescription) -> String {
        var fields = ["ch=\(port.channels?.count ?? -1)"]
        if let labels = port.channels?.map(\.channelLabel), !labels.isEmpty {
            fields.append("labels=\(channelLabelSummary(labels))")
            fields.append("heights=\(heightChannelCount(labels))")
        }
        if port.isSpatialAudioEnabled { fields.append("spatial") }
        return "\(port.portType.rawValue)[\(fields.joined(separator: ", "))]"
    }

    static func renderingModeName(_ mode: AVAudioSession.RenderingMode) -> String {
        switch mode {
        case .notApplicable: return "notApplicable"
        case .monoStereo: return "monoStereo"
        case .surround: return "surround"
        case .spatialAudio: return "spatialAudio"
        case .dolbyAudio: return "dolbyAudio"
        case .dolbyAtmos: return "dolbyAtmos"
        @unknown default: return "raw\(mode.rawValue)"
        }
    }

    /// AE#395: one line per route change, for the process rather than per engine (a multiview runs several).
    /// A change mid-session leaves the session's start line describing a route that is gone, and a user
    /// switching output to test a theory is exactly that case. Installed on first touch, never removed.
    ///
    /// A rendering-mode, rendering-capability or spatial-playback change gets the same line: an output
    /// can switch between multichannel PCM and Dolby Atmos, or change the layouts it supports, without
    /// the route itself changing.
    static let changeLogger: Void = {
        let session = AVAudioSession.sharedInstance()
        _ = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: nil
        ) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).map(String.init) ?? "?"
            guard let route = current() else { return }
            EngineLog.emit("[AetherEngine] audioRoute changed reason=\(reason) \(route)", category: .engine)
        }
        for (name, what) in [(AVAudioSession.renderingModeChangeNotification, "rendering mode"),
                             (AVAudioSession.renderingCapabilitiesChangeNotification, "rendering capabilities"),
                             (AVAudioSession.spatialPlaybackCapabilitiesChangedNotification, "spatial playback")] {
            _ = NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { _ in
                guard let route = current() else { return }
                EngineLog.emit("[AetherEngine] audioRoute \(what) changed \(route)", category: .engine)
            }
        }
    }()
    #endif

    // MARK: - Channel labels

    /// Height labels in CoreAudio's numbering: top centre, the three vertical-height (top front)
    /// positions, the three top-back positions, the top-middle and top-rear rows Atmos layouts use,
    /// and the top-surround pair.
    private static let heightLabels: Set<AudioChannelLabel> = [
        kAudioChannelLabel_TopCenterSurround,
        kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_VerticalHeightCenter,
        kAudioChannelLabel_VerticalHeightRight,
        kAudioChannelLabel_TopBackLeft, kAudioChannelLabel_TopBackCenter, kAudioChannelLabel_TopBackRight,
        kAudioChannelLabel_LeftTopMiddle, kAudioChannelLabel_RightTopMiddle,
        kAudioChannelLabel_LeftTopRear, kAudioChannelLabel_CenterTopRear, kAudioChannelLabel_RightTopRear,
        kAudioChannelLabel_LeftTopSurround, kAudioChannelLabel_RightTopSurround,
    ]

    /// The abbreviations CoreAudioBaseTypes.h uses in its layout comments.
    private static let labelNames: [AudioChannelLabel: String] = [
        kAudioChannelLabel_Left: "L", kAudioChannelLabel_Right: "R", kAudioChannelLabel_Center: "C",
        kAudioChannelLabel_LFEScreen: "LFE", kAudioChannelLabel_LFE2: "LFE2",
        kAudioChannelLabel_LeftSurround: "Ls", kAudioChannelLabel_RightSurround: "Rs",
        kAudioChannelLabel_LeftCenter: "Lc", kAudioChannelLabel_RightCenter: "Rc",
        kAudioChannelLabel_CenterSurround: "Cs",
        kAudioChannelLabel_LeftSurroundDirect: "Lsd", kAudioChannelLabel_RightSurroundDirect: "Rsd",
        kAudioChannelLabel_RearSurroundLeft: "Rls", kAudioChannelLabel_RearSurroundRight: "Rrs",
        kAudioChannelLabel_LeftWide: "Lw", kAudioChannelLabel_RightWide: "Rw",
        kAudioChannelLabel_TopCenterSurround: "Ts",
        kAudioChannelLabel_VerticalHeightLeft: "Vhl", kAudioChannelLabel_VerticalHeightCenter: "Vhc",
        kAudioChannelLabel_VerticalHeightRight: "Vhr",
        kAudioChannelLabel_TopBackLeft: "Tbl", kAudioChannelLabel_TopBackCenter: "Tbc",
        kAudioChannelLabel_TopBackRight: "Tbr",
        kAudioChannelLabel_LeftTopMiddle: "Ltm", kAudioChannelLabel_RightTopMiddle: "Rtm",
        kAudioChannelLabel_LeftTopRear: "Ltr", kAudioChannelLabel_CenterTopRear: "Ctr",
        kAudioChannelLabel_RightTopRear: "Rtr",
        kAudioChannelLabel_LeftSideSurround: "Lss", kAudioChannelLabel_RightSideSurround: "Rss",
        kAudioChannelLabel_LeftBottom: "Lb", kAudioChannelLabel_RightBottom: "Rb",
        kAudioChannelLabel_CenterBottom: "Cb",
        kAudioChannelLabel_LeftTopSurround: "Lts", kAudioChannelLabel_RightTopSurround: "Rts",
        kAudioChannelLabel_LFE3: "LFE3",
        kAudioChannelLabel_LeftBackSurround: "Lbs", kAudioChannelLabel_RightBackSurround: "Rbs",
        kAudioChannelLabel_LeftEdgeOfScreen: "Les", kAudioChannelLabel_RightEdgeOfScreen: "Res",
        kAudioChannelLabel_Mono: "M",
        kAudioChannelLabel_HeadphonesLeft: "HpL", kAudioChannelLabel_HeadphonesRight: "HpR",
        kAudioChannelLabel_Unused: "-", kAudioChannelLabel_Unknown: "?",
    ]

    static func heightChannelCount(_ labels: [AudioChannelLabel]) -> Int {
        labels.filter(heightLabels.contains).count
    }

    /// Labels in route order, with runs folded so a 32-channel route stays one short field:
    /// consecutive discrete channels as `D0-31`, repeats of one label as `?x32`.
    /// `L R C LFE Ls Rs Rls Rrs Vhl Vhr Ltr Rtr` is a 7.1.4 route.
    static func channelLabelSummary(_ labels: [AudioChannelLabel]) -> String {
        var tokens: [String] = []
        var index = 0
        while index < labels.count {
            let label = labels[index]
            var end = index + 1
            if let discrete = discreteIndex(label) {
                while end < labels.count, discreteIndex(labels[end]) == discrete + UInt32(end - index) { end += 1 }
                let run = end - index
                tokens.append(run > 1 ? "D\(discrete)-\(discrete + UInt32(run - 1))" : "D\(discrete)")
            } else {
                while end < labels.count, labels[end] == label { end += 1 }
                let run = end - index
                let name = labelName(label)
                tokens.append(run > 1 ? "\(name)x\(run)" : name)
            }
            index = end
        }
        return tokens.joined(separator: " ")
    }

    /// One label's short name: CoreAudio's abbreviation, `D<n>` for a discrete channel, `A<n>` for an
    /// ambisonic component, `#<value>` for anything else.
    static func labelName(_ label: AudioChannelLabel) -> String {
        if let name = labelNames[label] { return name }
        if let discrete = discreteIndex(label) { return "D\(discrete)" }
        return hoaName(label) ?? "#\(label)"
    }

    private static func discreteIndex(_ label: AudioChannelLabel) -> UInt32? {
        label >> 16 == 1 ? label & 0xFFFF : nil
    }

    private static func hoaName(_ label: AudioChannelLabel) -> String? {
        label >> 16 == 2 ? "A\(label & 0xFFFF)" : nil
    }
}
