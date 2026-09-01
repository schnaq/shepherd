import Foundation

/// Everything that can go wrong on the way between this Mac's settings and the user's bucket
/// (ADR 0014).
///
/// The descriptions are user-facing: the whole feature is four buttons and a status line, so a
/// failure has to explain itself there or it explains itself nowhere. Two of them are worded
/// with unusual care:
///
/// - ``wrongPassphraseOrCorruptedData`` is the *only* thing an authentication failure is ever
///   reported as. GCM cannot tell a wrong key from a flipped bit, and pretending otherwise
///   would invite a user to "fix" a corrupted object by trying more passphrases.
/// - ``passphraseTooShort(minimum:)`` fires before an upload rather than after, because the
///   passphrase is the only thing standing between the bucket's contents and the user's GitHub
///   token.
enum SettingsSyncError: Error, LocalizedError, Equatable {
    /// The endpoint, bucket or region has not been filled in.
    case notConfigured
    /// The endpoint is not a usable https URL.
    case invalidEndpoint
    /// The bucket name is empty or contains a slash.
    case invalidBucket
    /// No access key pair is stored.
    case credentialsMissing
    /// No passphrase was entered.
    case passphraseMissing
    /// The passphrase is shorter than the minimum.
    case passphraseTooShort(minimum: Int)
    /// The envelope claims a version this build does not understand.
    case unsupportedEnvelopeVersion(Int)
    /// The envelope names a KDF or cipher this build does not implement.
    case unsupportedAlgorithm(String)
    /// The envelope's iteration count is absurd — a hostile object must not be able to hang the app.
    case iterationsOutOfRange(Int)
    /// The envelope JSON is not an envelope.
    case malformedEnvelope
    /// PBKDF2 refused to derive a key.
    case keyDerivationFailed(Int32)
    /// The AEAD tag did not verify.
    case wrongPassphraseOrCorruptedData
    /// The decrypted bytes are not a settings document.
    case malformedDocument
    /// The document claims a version this build does not understand.
    case unsupportedDocumentVersion(Int)
    /// The bucket has no settings object yet.
    case noRemoteDocument
    /// The storage service refused the request.
    case remoteRejected(status: Int, message: String)
    /// The request never got an answer.
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "Fill in the endpoint, bucket and region first.")
        case .invalidEndpoint:
            return String(localized: "That is not a valid https endpoint URL.")
        case .invalidBucket:
            return String(localized: "The bucket name must not be empty or contain a slash.")
        case .credentialsMissing:
            return String(localized: "Save an access key id and secret access key first.")
        case .passphraseMissing:
            return String(localized: "Enter your passphrase.")
        case .passphraseTooShort(let minimum):
            return String(localized: "Use a passphrase of at least \(minimum) characters — it is the only thing protecting your tokens in the bucket.")
        case .unsupportedEnvelopeVersion(let version):
            return String(localized: "The stored settings were written by a newer Shepherd (envelope version \(version)). Update Shepherd on this Mac.")
        case .unsupportedAlgorithm(let name):
            return String(localized: "The stored settings use an algorithm this build does not know: \(name).")
        case .iterationsOutOfRange(let iterations):
            return String(localized: "The stored settings declare an implausible key-derivation cost (\(iterations) iterations) and were not decrypted.")
        case .malformedEnvelope:
            return String(localized: "The object in the bucket is not a Shepherd settings envelope.")
        case .keyDerivationFailed(let status):
            return String(localized: "The passphrase could not be turned into a key (status \(status)).")
        case .wrongPassphraseOrCorruptedData:
            return String(localized: "Wrong passphrase or corrupted data. Nothing was applied.")
        case .malformedDocument:
            return String(localized: "The settings decrypted, but their contents could not be read.")
        case .unsupportedDocumentVersion(let version):
            return String(localized: "These settings were written by a newer Shepherd (document version \(version)). Update Shepherd on this Mac.")
        case .noRemoteDocument:
            return String(localized: "Nothing has been uploaded to this bucket yet.")
        case .remoteRejected(let status, let message):
            return message.isEmpty
                ? String(localized: "The storage service answered \(status).")
                : String(localized: "The storage service answered \(status): \(message)")
        case .transport(let message):
            return String(localized: "The bucket could not be reached: \(message)")
        }
    }
}
