import Foundation
import GitHubKit

/// The session every request that carries a credential goes through.
///
/// `URLSession.shared` follows a cross-host redirect and copies the original request's headers
/// onto it, credential included — which is why `GitHubKit`'s transport has never used it
/// (ADR 0024, `RedirectPolicy`). That reasoning is not about GitHub: it holds for the S3-compatible
/// bucket the encrypted settings document is stored in (ADR 0014), for the webhook receiver
/// (ADR 0012) and, most of all, for the AI endpoints the user configures themselves (ADR 0007),
/// where the header is the user's own API key and the endpoint is a host Shepherd does not
/// control. An endpoint that answers with a `302` must not be able to forward that key onwards.
///
/// One session for the whole app rather than one per client: it is stateless, `URLSession` pools
/// connections per session, and a session built per request would throw those away.
enum CredentialSafeSession {
    /// The shared session. Its redirects go through ``GitHubKit/RedirectPolicy``.
    static let shared: URLSession = RedirectStrippingDelegate.makeSession()
}
