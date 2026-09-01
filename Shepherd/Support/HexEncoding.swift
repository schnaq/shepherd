import Foundation

/// Lowercase hexadecimal, the encoding both of Shepherd's signature schemes are written in.
///
/// AWS SigV4 (``SigV4Signer``) and the webhook HMAC header (``WebhookSignature``) each specify
/// lowercase hex and nothing else, so there is one implementation rather than two identical
/// ones. Hand-rolled rather than `String(format:)` in a loop: this runs over a 32-byte digest on
/// every signed request, and the formatter costs more than the hash it is describing.
enum HexEncoding {
    /// Lowercase hex of some bytes.
    /// - Parameter bytes: The bytes to encode.
    /// - Returns: Two lowercase hex characters per byte, in order.
    static func lowercase(_ bytes: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var characters: [UInt8] = []
        for byte in bytes {
            characters.append(digits[Int(byte >> 4)])
            characters.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: characters, as: UTF8.self)
    }
}
