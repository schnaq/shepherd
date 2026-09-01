import Foundation

/// The one encoder Shepherd's canonical JSON bytes are produced with.
///
/// Two options, and both of them are load-bearing:
///
/// - `sortedKeys` makes the bytes a pure function of the value. That is what lets the test suite
///   pin a schema, and what lets a signature be computed over exactly what is sent. JSON objects
///   are unordered, so no receiver may depend on the alphabetical order it happens to see.
/// - `withoutEscapingSlashes` keeps URLs and paths readable for a human — someone reading a
///   delivered webhook payload, or decrypting their own settings backup with a ten-line script.
///
/// Both callers — the outbound webhook envelope (ADR 0012) and the encrypted settings document
/// (ADR 0014) — need exactly these options, and they need to keep needing the *same* ones: a
/// change here is a wire-format change for both, which is precisely why it lives in one place.
enum CanonicalJSON {
    /// A fresh encoder configured for canonical output.
    /// - Returns: The encoder.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
