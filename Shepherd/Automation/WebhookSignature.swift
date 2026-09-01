import CryptoKit
import Foundation

/// Signs webhook bodies so a receiver can prove the request came from this Shepherd install.
///
/// The shape is GitHub's own: `sha256=<hex>` over the **exact bytes of the request body**,
/// HMAC-SHA256 with a shared secret. That is deliberate — an n8n node (or any middleware)
/// already configured to verify `X-Hub-Signature-256` works unchanged against this header.
///
/// The secret lives in the Keychain and nowhere else (ADR 0004's rule, applied to ADR 0012):
/// this type never stores it, and the settings tab never writes it to `UserDefaults`.
enum WebhookSignature {
    /// The header the signature is sent in.
    static let headerName = "X-Shepherd-Signature"

    /// Computes the header value for a body.
    /// - Parameters:
    ///   - body: The exact bytes that will be POSTed.
    ///   - secret: The shared secret; an empty one means "unsigned".
    /// - Returns: `sha256=<64 lowercase hex characters>`, or `nil` when no secret is configured.
    static func header(for body: Data, secret: String) -> String? {
        guard !secret.isEmpty else { return nil }
        let code = HMAC<SHA256>.authenticationCode(
            for: body,
            using: SymmetricKey(data: Data(secret.utf8))
        )
        // Lowercase hex, the encoding every HMAC verifier expects.
        return "sha256=" + HexEncoding.lowercase(code)
    }
}
