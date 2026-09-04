import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a request may still carry once a redirect takes it to a different host (ADR 0024).
///
/// GitHub answers the one read that matters here — `GET /repos/…/actions/jobs/{id}/logs` — with
/// a `302` to a short-lived blob on `*.githubusercontent.com`, and that blob carries its own
/// signature in its query string. It needs no bearer token, so it must not be sent one: a
/// credential that reaches a host which does not need it is a credential in one more place than
/// it has to be, and `Authorization` is the header that opens every repository the token can see.
///
/// `URLSession` does not make that decision. Left to itself it follows a cross-host redirect and
/// **copies the original request's headers onto it**, token included, which is why the decision
/// lives here as a value-in, value-out function: it is the part that can be *asserted*, on Linux,
/// with no session, no socket and no Mac. ``RedirectStrippingDelegate`` is the thin adapter that
/// asks it, and ``GitHubClient/jobLog(repo:jobID:)`` keeps its own unauthenticated second request
/// for the transport that does not follow redirects at all — the same rule stated twice, which is
/// the right number of times for this one.
public enum RedirectPolicy {
    /// The headers that are credentials for *one* host, and therefore never leave it.
    ///
    /// Two names, deliberately. `Accept`, `User-Agent` and `X-GitHub-Api-Version` say what is
    /// wanted and by which client rather than who is asking, so they may travel: the blob host
    /// ignores them, and dropping them would make a redirect answer differently from a request.
    /// Anything added here has to be a *credential* — something that would let its holder act as
    /// the person who sent it.
    ///
    /// `x-api-key` is Anthropic's spelling of the same thing and is here for the same reason: the
    /// app sends the user's own key straight to the endpoint they configured (ADR 0007), and an
    /// endpoint that answers with a redirect must not be able to forward that key to a host the
    /// user never named. A webhook signature is deliberately *not* here: it authenticates one
    /// message rather than its sender, so it is not something a holder can act with.
    public static let credentialHeaders = ["Authorization", "x-api-key"]

    /// The request a redirect may be followed with.
    ///
    /// Same host: the request as it was, at the new URL — a redirect inside `api.github.com`
    /// (a rename, a trailing slash, `github.com` → `api.github.com` paths) still needs the token,
    /// and stripping it there would turn a redirect into a `401`.
    ///
    /// Different host: the same request with every ``credentialHeaders`` entry removed. It is the
    /// *host* that decides, not an allowlist of known blob hosts, because the rule has to hold for
    /// the host GitHub redirects to next year as well as the one it redirects to today.
    /// - Parameters:
    ///   - original: The request that was sent, headers included.
    ///   - destination: Where the `Location` header points.
    /// - Returns: The request to follow the redirect with.
    public static func request(
        for original: HTTPRequest,
        redirectingTo destination: URL
    ) -> HTTPRequest {
        var followed = original
        followed.url = destination
        guard !isSameHost(original.url, destination) else { return followed }
        followed.headers = original.headers.filter { name, _ in
            !credentialHeaders.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        return followed
    }

    /// Whether two URLs name the same host, ignoring case.
    ///
    /// A host that cannot be established on either side counts as **different**, which is the
    /// safe answer rather than the convenient one: `URL` allows a URL with no host at all, and
    /// "we could not tell" must not be the branch that keeps the token.
    /// - Parameters:
    ///   - one: The first URL.
    ///   - other: The second URL.
    /// - Returns: `true` only when both name the same non-empty host.
    static func isSameHost(_ one: URL, _ other: URL) -> Bool {
        guard let first = one.host?.lowercased(), !first.isEmpty,
              let second = other.host?.lowercased(), !second.isEmpty
        else { return false }
        return first == second
    }
}

/// Applies ``RedirectPolicy`` to the redirects `URLSession` follows on its own.
///
/// The reason this class exists at all: ``URLSessionTransport`` used to run on a session with no
/// delegate, so a `302` off `api.github.com` was followed inside `URLSession` with the original
/// headers re-sent — the bearer token included — and the manual second request in
/// ``GitHubClient/jobLog(repo:jobID:)`` never got the chance to be the unauthenticated one,
/// because by then the blob had already been fetched. The header is now dropped on the hop
/// itself, wherever the hop happens.
///
/// It is stateless, and it has to be `@unchecked Sendable` rather than `Sendable`: `URLSession`
/// calls a delegate from its own queue, and `NSObject`/`URLSessionTaskDelegate` conformance
/// cannot be checked by the compiler on either platform this package builds on. There is nothing
/// to protect — no stored properties, and the decision is a pure function.
public final class RedirectStrippingDelegate: NSObject, URLSessionTaskDelegate {
    /// Creates the delegate.
    public override init() {
        super.init()
    }

    /// The request `URLSession` should follow a redirect with, credentials removed if it leaves
    /// the host.
    ///
    /// Split out from the callback below and given plain values so that it can be asserted
    /// without fabricating a `URLSessionTask`: the callback's only job is to find the two
    /// requests and hand them here.
    ///
    /// It *removes* headers from the request `URLSession` proposed rather than replacing them
    /// wholesale, because that request also carries headers the session added itself
    /// (`Accept-Encoding`, cookies it is managing, `Content-Length`) and a redirect that lost
    /// those would fail in a way no test would explain.
    /// - Parameters:
    ///   - original: The request as it was sent.
    ///   - proposed: The request `URLSession` intends to send next.
    /// - Returns: The request to follow with.
    public static func followedRequest(original: URLRequest, proposed: URLRequest) -> URLRequest {
        guard let originalURL = original.url, let destination = proposed.url else {
            return proposed
        }
        let sent = HTTPRequest(
            method: original.httpMethod ?? "GET",
            url: originalURL,
            headers: original.allHTTPHeaderFields ?? [:]
        )
        let allowed = RedirectPolicy.request(for: sent, redirectingTo: destination)
        var followed = proposed
        for name in sent.headers.keys where allowed.headers[name] == nil {
            followed.setValue(nil, forHTTPHeaderField: name)
        }
        return followed
    }

    /// Lets `URLSession` follow the redirect, with the credentials it may keep.
    ///
    /// Always continues — answering `nil` here would turn a `302` into the redirect's own
    /// response body, which is not what any caller of this transport asked for. What changes is
    /// only *which headers* go with it.
    /// - Parameters:
    ///   - session: The session following the redirect.
    ///   - task: The task being redirected; its `originalRequest` is the host of record.
    ///   - response: The `3xx` response that asked for the redirect.
    ///   - request: The request `URLSession` proposes to send next.
    ///   - completionHandler: Called with the request to follow with.
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // `originalRequest` rather than `currentRequest`: on a chain of hops the question is
        // whether the token is still on the host it was issued for, not whether the last two hops
        // happened to agree.
        guard let original = task.originalRequest else {
            completionHandler(request)
            return
        }
        completionHandler(
            RedirectStrippingDelegate.followedRequest(original: original, proposed: request)
        )
    }
}

extension RedirectStrippingDelegate {
    /// A session that will not carry a credential off the host it was sent to.
    ///
    /// The one place that knows how to build such a session, because there is one reason to want
    /// one and every client that sends a credential wants it: `URLSession.shared` cannot be given
    /// a delegate, and a delegate is the only place `URLSession` lets anybody see the redirect it
    /// is about to follow. Whoever calls this owns the session and should hold it rather than
    /// build one per request.
    /// - Parameter configuration: The configuration to use; the default one unless a caller has
    ///   a reason of its own.
    /// - Returns: A session whose redirects go through ``RedirectPolicy``.
    public static func makeSession(
        configuration: URLSessionConfiguration = .default
    ) -> URLSession {
        URLSession(
            configuration: configuration,
            delegate: RedirectStrippingDelegate(),
            delegateQueue: nil
        )
    }
}

/// The conformance is `@unchecked` because it cannot be anything else: `URLSessionTaskDelegate`
/// inherits from `NSObjectProtocol`, whose conformance no compiler on either platform this
/// package builds on can check. It is honest here — the class has no stored properties at all, so
/// there is no state for two queues to disagree about.
extension RedirectStrippingDelegate: @unchecked Sendable {}
