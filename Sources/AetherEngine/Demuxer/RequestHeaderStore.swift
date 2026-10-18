import Foundation

/// AE#792: the HTTP headers a session's source requests carry, as one value every reader of that
/// session reads at request time instead of a copy each one froze at its open.
///
/// A credential that rotates under a playing session (a bearer token that lives an hour) changes
/// nothing about the session except this value, and every request an `AVIOReader` builds already
/// goes through one place (`headers(for:)`), so the value is the only thing that was frozen. The
/// session creates one store per load, hands it to the readers it opens (through
/// `DemuxerOpenProfile.requestHeaders`) and to the producer's reopens, and
/// `AetherEngine.updateRequestHeaders(_:)` replaces the value in it. A request already in flight
/// finishes with the headers it was sent with; the next one carries the new set.
///
/// Redirect scoping is not this type's business: `RedirectHeaderPolicy` still decides which of
/// these headers a given target may see, on the value read here.
final class RequestHeaderStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: String]
    private var revisionValue: UInt64 = 0
    private var refusal: CredentialRefusal?
    private var announcedRevision: UInt64?

    /// AE#792 part 2: the origin answered 401 or 403 to a request this store's headers went out on.
    /// `revision` is the store's revision when that request was built, so a later look can tell a
    /// refusal of the current credential from one the host has already replaced.
    struct CredentialRefusal: Equatable, Sendable {
        let status: Int
        let revision: UInt64
        let at: Date
    }

    /// Called once per revision, on the first credential refusal of that revision, from the reader's
    /// thread. The engine forwards it to `sourceAuthorizationRefused`.
    var onCredentialRefusal: (@Sendable (Int) -> Void)? {
        get { lock.withLock { onRefusal } }
        set { lock.withLock { onRefusal = newValue } }
    }
    private var onRefusal: (@Sendable (Int) -> Void)?

    init(_ headers: [String: String]) {
        value = headers
    }

    var current: [String: String] {
        lock.withLock { value }
    }

    /// Bumped by every `replace`, so a reader can stamp what it sent and the revive arm can ask
    /// whether the credential moved since.
    var revision: UInt64 {
        lock.withLock { revisionValue }
    }

    func replace(_ headers: [String: String]) {
        lock.withLock {
            value = headers
            revisionValue &+= 1
        }
    }

    /// Records a 401/403 the origin answered to headers of `revision`. Only the newest revision's
    /// refusal is kept: a late answer to a credential already replaced says nothing about the
    /// current one.
    func noteCredentialRefusal(status: Int, revision: UInt64, at instant: Date = Date()) {
        let callback: (@Sendable (Int) -> Void)?
        lock.lock()
        if let kept = refusal, kept.revision > revision {
            lock.unlock()
            return
        }
        refusal = CredentialRefusal(status: status, revision: revision, at: instant)
        if announcedRevision != revision {
            announcedRevision = revision
            callback = onRefusal
        } else {
            callback = nil
        }
        lock.unlock()
        callback?(status)
    }

    /// The last credential refusal, when it happened within `window` of `now`.
    func recentCredentialRefusal(within window: TimeInterval, now: Date = Date()) -> CredentialRefusal? {
        lock.withLock {
            guard let refusal, now.timeIntervalSince(refusal.at) <= window else { return nil }
            return refusal
        }
    }
}
