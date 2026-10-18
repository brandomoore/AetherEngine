import Foundation
import Testing
@testable import AetherEngine

/// Covers the machine-readable failure companion (#376). The gap it closes: `PlaybackState.error`
/// carries one string, and on the native paths that string is `AVPlayerItem.error.localizedDescription`
/// forwarded verbatim, so a host classifying its failures was substring-matching text the OS had
/// already translated. The kind and the underlying domain / code are what survive a locale.
@Suite("PlaybackErrorInfo (#376)")
struct PlaybackErrorInfoTests {

    @MainActor
    @Test("A failed custom probe publishes its cause before the host observes the terminal state")
    func customProbeRetainsCause() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        var observed: PlaybackErrorInfo?
        let token = engine.$state.sink { state in
            if case .error = state { observed = engine.errorInfo }
        }
        defer { token.cancel() }
        do {
            _ = try await engine.load(source: .custom(DataIOReader(data: Data()), formatHint: "mpegts"))
            Issue.record("An empty custom source must fail its probe")
        } catch {
            #expect(observed?.kind == .customSourceProbeFailed)
            #expect(observed?.underlyingDomain == "AetherEngine.DemuxerError")
            #expect(observed?.underlyingCode != nil)
            #expect(observed == engine.errorInfo)
        }
    }

    @MainActor
    @Test("A live HLS join the origin refuses publishes its answer, not a probe failure",
          .timeLimit(.minutes(1)),
          arguments: [(509, PlaybackErrorKind.sourceRateLimited), (403, .sourceRefused)])
    func refusedLiveJoinPublishesTheOriginsAnswer(status: Int, kind: PlaybackErrorKind) async throws {
        let origin = try #require(RefusingOrigin(status: status))
        defer { origin.stop() }
        let observed = try await failedLiveIngestLoad(
            try #require(URL(string: "http://127.0.0.1:\(origin.port)/live/1.m3u8")))
        #expect(observed?.kind == kind)
        #expect(observed?.underlyingCode == status)
    }

    @MainActor
    @Test("A live HLS join that reaches nothing publishes an unavailable live source", .timeLimit(.minutes(1)))
    func unreachableLiveJoinIsUnavailable() async throws {
        let observed = try await failedLiveIngestLoad(try #require(URL(string: "http://127.0.0.1:1/live/1.m3u8")))
        #expect(observed?.kind == .liveSourceUnavailable)
    }

    /// Loads `url` live through the engine's own HLS ingest, as a known HLS playlist on the live path
    /// is, and returns the failure the load published.
    @MainActor
    private func failedLiveIngestLoad(_ url: URL) async throws -> PlaybackErrorInfo? {
        let engine = try AetherEngine()
        defer { engine.stop() }
        var observed: PlaybackErrorInfo?
        let token = engine.$state.sink { state in
            if case .error = state { observed = engine.errorInfo }
        }
        defer { token.cancel() }
        var options = LoadOptions()
        options.isLive = true
        do {
            _ = try await engine.load(
                source: .custom(HLSLiveIngestReader(playlistURL: url), formatHint: "mpegts"), options: options)
            Issue.record("A refused live playlist must fail the load")
        } catch {}
        return observed
    }

    /// Answers every request with `status` and an empty body, one response per connection.
    private final class RefusingOrigin: @unchecked Sendable {
        let port: UInt16
        private let listener: LoopbackListener

        init?(status: Int) {
            guard let listener = LoopbackListener(backlog: 8) else { return nil }
            self.listener = listener
            port = listener.port
            listener.start { conn in
                Thread.detachNewThread {
                    defer { close(conn) }
                    var request = Data()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while request.range(of: Data("\r\n\r\n".utf8)) == nil {
                        let n = read(conn, &buffer, buffer.count)
                        guard n > 0 else { return }
                        request.append(contentsOf: buffer[0..<n])
                    }
                    let response = "HTTP/1.1 \(status) Refused\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    _ = response.withCString { write(conn, $0, strlen($0)) }
                }
                return true
            }
        }

        func stop() {
            listener.stop()
        }
    }

    @Test("An underlying NSError contributes its domain and code")
    func capturesUnderlying() {
        let underlying = NSError(domain: "CoreMediaErrorDomain", code: -12939)
        let info = PlaybackErrorInfo(kind: .nativeItemFailed,
                                     message: underlying.localizedDescription,
                                     underlying: underlying)
        #expect(info.kind == .nativeItemFailed)
        #expect(info.underlyingDomain == "CoreMediaErrorDomain")
        #expect(info.underlyingCode == -12939)
    }

    @Test("An engine-authored failure has no underlying domain, which is how a host tells the halves apart")
    func engineAuthoredHasNoUnderlying() {
        let info = PlaybackErrorInfo(kind: .liveSourceUnavailable, message: "Live source unavailable")
        #expect(info.underlyingDomain == nil)
        #expect(info.underlyingCode == nil)
        // The same constructor path the hosts use when there is nothing underneath.
        let fromNilError = PlaybackErrorInfo(kind: .liveSourceUnavailable,
                                             message: "Live source unavailable",
                                             underlying: nil)
        #expect(fromNilError == info)
    }

    /// The raw values are API: a host ships them into an analytics bucket, so a rename is a silent
    /// break in someone else's histogram rather than a compile error here.
    @Test("Kind raw values are the published tokens and are distinct")
    func rawValuesAreStableAndDistinct() {
        let kinds: [PlaybackErrorKind] = [
            .sourceOpenFailed, .sourceRefused, .customSourceProbeFailed, .liveSourceUnavailable,
            .hlsPlaylistOnRawLivePath, .dolbyVisionRequiresHardware, .demuxedAudioLiveUnsupported,
            .nativeItemFailed, .noPlayableTrackWithinBudget, .masterPlaylistRejected,
            .vodSourceFailed, .softwarePipelineFailed, .audioSessionFailed,
            .reloadFailed, .liveReloadNeverReady, .audioTrackSwitchFailed,
        ]
        #expect(Set(kinds.map(\.rawValue)).count == kinds.count)
        #expect(PlaybackErrorKind.nativeItemFailed.rawValue == "nativeItemFailed")
        #expect(PlaybackErrorKind(rawValue: "nativeItemFailed") == .nativeItemFailed)
    }

    @MainActor
    @Test("publishError assigns the info BEFORE the state, so a $state sink reads this failure's own")
    func infoIsVisibleFromAStateSink() throws {
        let engine = try AetherEngine()
        var seen: [PlaybackErrorInfo?] = []
        let token = engine.$state
            .dropFirst()                        // the replay of .idle belongs to no failure
            .sink { _ in seen.append(engine.errorInfo) }
        defer { token.cancel() }

        engine.publishError(.liveSourceUnavailable, "Live source unavailable")

        #expect(seen.count == 1)
        #expect(seen.first??.kind == .liveSourceUnavailable)
        #expect(engine.state == .error("Live source unavailable"))
    }

    @MainActor
    @Test("The info dies with the failure it describes")
    func clearedWhenTheStateLeavesError() throws {
        let engine = try AetherEngine()
        engine.publishError(.reloadFailed, "Reload failed: nope")
        #expect(engine.errorInfo?.kind == .reloadFailed)

        engine.state = .loading
        #expect(engine.errorInfo == nil)
    }

    /// The funnel is the reason a published `.error` can never arrive without its classification. A new
    /// failure site that assigns `state` directly would compile, run, and publish an unclassifiable
    /// error, which is exactly the shape this issue exists to remove.
    @Test("Nothing outside the funnel publishes .error")
    func onlyTheFunnelPublishesError() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)

        let assignment = try NSRegularExpression(pattern: #"state\s*=\s*\.error\("#)
        var offenders: [String] = []
        for file in files where file.lastPathComponent != "PlaybackErrorInfo.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let hits = assignment.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            if hits > 0 { offenders.append("\(file.lastPathComponent) (\(hits))") }
        }
        #expect(offenders.isEmpty, "publish these through publishError instead: \(offenders.joined(separator: ", "))")
    }
}
