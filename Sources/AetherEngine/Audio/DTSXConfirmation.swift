import Foundation

// #744 follow-up: `TrackInfo.isDTSX` from LibDTSX's verdict. FFmpeg labels DTS:X by two of its
// markers only, so a DTS-HD MA track it calls plain can turn out to be DTS:X once the object-audio
// route decodes it. The verdict is about the track, so it outlives the session that produced it the
// same way a confirmed JOC flag does.
extension AetherEngine {

    /// Every republish of `audioTracks` runs through here (see `applyConfirmedAtmos`).
    func applyConfirmedTrackFlags() {
        applyConfirmedAtmos()
        guard !confirmedDTSXStreamIndices.isEmpty, loadedURL == confirmedDTSXSource else { return }
        let flagged = Self.applyingConfirmedDTSX(to: audioTracks, confirmed: confirmedDTSXStreamIndices)
        if flagged != audioTracks { audioTracks = flagged }
    }

    /// Called once the native session has published its pick, so `streamIndex` is in the numbering
    /// `audioTracks` uses. A new item starts a new ledger; a reload of the same one keeps it.
    func recordConfirmedDTSX(streamIndex: Int32) {
        guard let url = loadedURL else { return }
        if confirmedDTSXSource != url {
            confirmedDTSXSource = url
            confirmedDTSXStreamIndices = []
        }
        guard confirmedDTSXStreamIndices.insert(streamIndex).inserted else { return }
        EngineLog.emit("[AetherEngine] #744: stream \(streamIndex) confirmed DTS:X by LibDTSX", category: .engine)
        applyConfirmedTrackFlags()
    }

    /// Pure half of `applyConfirmedTrackFlags`. Additive, like the Atmos ledger: nothing is cleared.
    nonisolated static func applyingConfirmedDTSX(to tracks: [TrackInfo], confirmed: Set<Int32>) -> [TrackInfo] {
        guard !confirmed.isEmpty else { return tracks }
        return tracks.map { track in
            guard let index = Int32(exactly: track.id), confirmed.contains(index), !track.isDTSX else {
                return track
            }
            var flipped = track
            flipped.isDTSX = true
            return flipped
        }
    }
}
