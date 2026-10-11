import Testing
import CoreAudioTypes
@testable import AetherEngine

/// The route line names the speakers the output offers, so a report can say whether an HDMI route had
/// height channels to put a bed's heights on.
struct AudioRouteDescriptionTests {

    @Test("a 7.1.4 route is spelled with CoreAudio's abbreviations and counts four heights")
    func atmosRoute() {
        let labels: [AudioChannelLabel] = [
            kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
            kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
            kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
            kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_VerticalHeightRight,
            kAudioChannelLabel_LeftTopRear, kAudioChannelLabel_RightTopRear,
        ]
        #expect(AudioRouteDescription.channelLabelSummary(labels) == "L R C LFE Ls Rs Rls Rrs Vhl Vhr Ltr Rtr")
        #expect(AudioRouteDescription.heightChannelCount(labels) == 4)
    }

    @Test("the top-middle row of a 9.1.6 route counts as heights")
    func topMiddle() {
        let labels = [kAudioChannelLabel_LeftTopMiddle, kAudioChannelLabel_RightTopMiddle, kAudioChannelLabel_Left]
        #expect(AudioRouteDescription.heightChannelCount(labels) == 2)
    }

    @Test("the top-surround pair counts as heights and every label in the SDK's 55-66 range has a name")
    func topSurroundAndLaterLabels() {
        let labels = (55...66).map { AudioChannelLabel($0) }
        #expect(AudioRouteDescription.heightChannelCount(labels) == 2)
        #expect(!AudioRouteDescription.channelLabelSummary(labels).contains("#"))
    }

    @Test("a bed speaker and the route name the same channel the same way")
    func bedSpeakersUseRouteNames() {
        let names = SpatialSpeakerLayout.l714.speakers.map { AudioRouteDescription.labelName($0.channelLabel) }
        #expect(names.joined(separator: " ") == "L R C LFE Ls Rs Rls Rrs Vhl Vhr Ltr Rtr")
        let ninePointOneSix = SpatialSpeakerLayout.l916.speakers.map { AudioRouteDescription.labelName($0.channelLabel) }
        #expect(ninePointOneSix.joined(separator: " ") == "L R C LFE Ls Rs Rls Rrs Lw Rw Vhl Vhr Ltm Rtm Ltr Rtr")
    }

    @Test("runs fold so a 32-channel route stays one short field, and no label is a height")
    func runsFold() {
        let discrete = (0..<32).map { kAudioChannelLabel_Discrete_0 | AudioChannelLabel($0) }
        #expect(AudioRouteDescription.channelLabelSummary(discrete) == "D0-31")
        #expect(AudioRouteDescription.heightChannelCount(discrete) == 0)
        let unknown = [AudioChannelLabel](repeating: kAudioChannelLabel_Unknown, count: 8)
        #expect(AudioRouteDescription.channelLabelSummary(unknown) == "?x8")
        let mixed = [kAudioChannelLabel_Left, kAudioChannelLabel_Right,
                     kAudioChannelLabel_Discrete_0 | 2, kAudioChannelLabel_Discrete_0 | 3,
                     kAudioChannelLabel_Discrete_0 | 5, kAudioChannelLabel_HOA_ACN_0 | 1, 9999]
        #expect(AudioRouteDescription.channelLabelSummary(mixed) == "L R D2-3 D5 A1 #9999")
    }
}

#if os(iOS) || os(tvOS)
/// The live line, read off whatever route the device or simulator has: the fields a missing-heights
/// report reads are always there, in order, whatever the values.
struct AudioRouteDescriptionLiveTests {
    @Test("the route line carries the rendering mode, multichannel support and per-port labels")
    func liveLine() throws {
        let line = try #require(AudioRouteDescription.current())
        print("[AudioRouteDescriptionLiveTests] \(line)")
        let rendering = try #require(line.range(of: " rendering="))
        let multichannel = try #require(line.range(of: " multichannelContent="))
        let ports = try #require(line.range(of: " ports=["))
        #expect(rendering.lowerBound < multichannel.lowerBound && multichannel.lowerBound < ports.lowerBound)
        #expect(!line.contains("rendering=raw"), "every mode the SDK defines has a name")
        // Each port is its type and its channel fields, never the device's name.
        #expect(line.range(of: #"ports=\[(\]|[A-Za-z0-9]+\[ch=-?\d+)"#, options: .regularExpression) != nil)
    }
}
#endif
