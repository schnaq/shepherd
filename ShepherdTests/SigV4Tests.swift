import Foundation
import XCTest

@testable import Shepherd

/// AWS Signature Version 4, pinned to the official test suite (ADR 0014).
///
/// The reason these vectors are hard-coded rather than merely "the code looks right": SigV4 is a
/// specification where every single byte of the canonical request matters — a missing trailing
/// newline in the headers block, a lower-case hex escape, a header sorted before it is
/// lower-cased — and each of those mistakes produces a perfectly well-formed signature that the
/// server rejects with `SignatureDoesNotMatch` and no further explanation. A test that only
/// checks "we produce 64 hex characters" would pass through all of them.
///
/// The credentials, host and timestamp below are AWS's own published ones from the
/// `aws-sig-v4-test-suite`; the expected signatures are the suite's. They are also reproducible
/// by hand: derive the signing key, HMAC the string-to-sign, done.
final class SigV4Tests: XCTestCase {
    // MARK: - The suite's shared fixtures

    private let accessKeyID = "AKIDEXAMPLE"
    private let secretAccessKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
    private let suiteHost = "example.amazonaws.com"
    private let suiteRegion = "us-east-1"
    private let suiteService = "service"
    /// `20150830T123600Z`, the suite's timestamp.
    private let suiteDate = Date(timeIntervalSince1970: 1_440_938_160)

    private var suiteSigner: SigV4Signer {
        SigV4Signer(
            credentials: SigV4Signer.Credentials(
                accessKeyID: accessKeyID,
                secretAccessKey: secretAccessKey
            ),
            region: suiteRegion,
            service: suiteService
        )
    }

    private func suiteHeaders() -> [String: String] {
        [
            "Host": suiteHost,
            "X-Amz-Date": SigV4Signer.amzDate(suiteDate),
        ]
    }

    // MARK: - Timestamps

    func testTheTimestampIsTheSuitesAndIsUTCRegardlessOfLocale() {
        XCTAssertEqual(SigV4Signer.amzDate(suiteDate), "20150830T123600Z")
        XCTAssertEqual(SigV4Signer.dateStamp(suiteDate), "20150830")
    }

    // MARK: - Official vectors

    func testGetWithNoQueryMatchesTheSuiteSignature() {
        let request = SigV4Signer.Request(
            method: "GET",
            path: "/",
            headers: suiteHeaders(),
            payloadHash: SigV4Signer.emptyPayloadHash
        )
        XCTAssertEqual(
            SigV4Signer.canonicalRequest(request),
            """
            GET
            /

            host:example.amazonaws.com
            x-amz-date:20150830T123600Z

            host;x-amz-date
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """
        )
        XCTAssertEqual(
            suiteSigner.stringToSign(request, at: suiteDate),
            """
            AWS4-HMAC-SHA256
            20150830T123600Z
            20150830/us-east-1/service/aws4_request
            bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63
            """
        )
        XCTAssertEqual(
            suiteSigner.signature(request, at: suiteDate),
            "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
        )
    }

    func testGetWithOneQueryParameterMatchesTheSuiteSignature() {
        let request = SigV4Signer.Request(
            method: "GET",
            path: "/",
            query: [SigV4Signer.QueryItem(name: "Param1", value: "value1")],
            headers: suiteHeaders(),
            payloadHash: SigV4Signer.emptyPayloadHash
        )
        XCTAssertEqual(
            suiteSigner.signature(request, at: suiteDate),
            "a67d582fa61cc504c4bae71f336f98b97f1ea3c7a6bfe1b6e45aec72011b9aeb"
        )
    }

    func testPostWithAnEmptyBodyMatchesTheSuiteSignature() {
        let request = SigV4Signer.Request(
            method: "POST",
            path: "/",
            headers: suiteHeaders(),
            payloadHash: SigV4Signer.emptyPayloadHash
        )
        XCTAssertEqual(
            suiteSigner.signature(request, at: suiteDate),
            "5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b"
        )
    }

    /// The signing-key derivation on its own, against the vector in AWS's own
    /// "deriving the signing key" example. Isolating it means a break in the four-step HMAC
    /// chain is distinguishable from a break in canonicalisation.
    func testTheSigningKeyChainMatchesTheDocumentedVector() {
        let key = SigV4Signer.signingKey(
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            dateStamp: "20120215",
            region: "us-east-1",
            service: "iam"
        )
        let hex = key.withUnsafeBytes { buffer in
            buffer.map { String(format: "%02x", Int($0)) }.joined()
        }
        XCTAssertEqual(
            hex,
            "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d"
        )
    }

    func testTheEmptyPayloadHashConstantIsTheRealSHA256OfNothing() {
        XCTAssertEqual(SigV4Signer.hexSHA256(Data()), SigV4Signer.emptyPayloadHash)
    }

    // MARK: - Canonicalisation rules in isolation

    func testOnlyUnreservedCharactersSurviveEncodingAndEscapesAreUppercase() {
        XCTAssertEqual(SigV4Signer.uriEncode("aA0-_.~", encodeSlash: true), "aA0-_.~")
        XCTAssertEqual(SigV4Signer.uriEncode("a b", encodeSlash: true), "a%20b")
        XCTAssertEqual(SigV4Signer.uriEncode("a+b", encodeSlash: true), "a%2Bb")
        XCTAssertEqual(SigV4Signer.uriEncode("a=b&c", encodeSlash: true), "a%3Db%26c")
        // Multi-byte scalars are escaped byte by byte, as UTF-8.
        XCTAssertEqual(SigV4Signer.uriEncode("ü", encodeSlash: true), "%C3%BC")
    }

    func testASlashIsStructuralInAPathAndEscapedInAQuery() {
        XCTAssertEqual(SigV4Signer.uriEncode("a/b", encodeSlash: false), "a/b")
        XCTAssertEqual(SigV4Signer.uriEncode("a/b", encodeSlash: true), "a%2Fb")
    }

    func testTheCanonicalURIIsSingleEncodedAndAlwaysAbsolute() {
        XCTAssertEqual(SigV4Signer.canonicalURI(path: ""), "/")
        XCTAssertEqual(
            SigV4Signer.canonicalURI(path: "/bucket/shepherd/settings.enc.json"),
            "/bucket/shepherd/settings.enc.json"
        )
        // Single encoding is S3's rule: the space becomes %20 exactly once.
        XCTAssertEqual(
            SigV4Signer.canonicalURI(path: "/bucket/my folder/settings.enc.json"),
            "/bucket/my%20folder/settings.enc.json"
        )
        XCTAssertEqual(SigV4Signer.canonicalURI(path: "no-leading-slash"), "/no-leading-slash")
    }

    func testQueryParametersAreSortedByEncodedNameThenValue() {
        let query = [
            SigV4Signer.QueryItem(name: "b", value: "2"),
            SigV4Signer.QueryItem(name: "a", value: "z"),
            SigV4Signer.QueryItem(name: "a", value: "a"),
            SigV4Signer.QueryItem(name: "A", value: "1"),
        ]
        XCTAssertEqual(SigV4Signer.canonicalQuery(query), "A=1&a=a&a=z&b=2")
        XCTAssertEqual(SigV4Signer.canonicalQuery([]), "")
    }

    func testHeadersAreLowercasedTrimmedAndSortedAndEachEndsWithANewline() {
        let headers = [
            "X-Amz-Date": "20150830T123600Z",
            "Host": "  example.amazonaws.com  ",
            "Content-Type": "application/json",
        ]
        XCTAssertEqual(
            SigV4Signer.canonicalHeaders(headers),
            "content-type:application/json\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n"
        )
        XCTAssertEqual(
            SigV4Signer.signedHeaders(headers),
            "content-type;host;x-amz-date"
        )
    }

    func testTheAuthorizationHeaderCarriesTheScopeTheSignedHeadersAndTheSignature() {
        let request = SigV4Signer.Request(
            method: "GET",
            path: "/",
            headers: suiteHeaders(),
            payloadHash: SigV4Signer.emptyPayloadHash
        )
        XCTAssertEqual(
            suiteSigner.authorizationHeader(request, at: suiteDate),
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
                + "SignedHeaders=host;x-amz-date, "
                + "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
        )
    }

    /// Header order in the dictionary must not reach the signature. This is the kind of thing
    /// that works by accident until a Swift release changes `Dictionary`'s iteration order.
    func testTheSignatureDoesNotDependOnDictionaryOrder() {
        let first = SigV4Signer.Request(
            method: "PUT",
            path: "/bucket/shepherd/settings.enc.json",
            headers: [
                "host": "object.storage.eu01.onstackit.cloud",
                "x-amz-date": "20260901T101500Z",
                "x-amz-content-sha256": SigV4Signer.emptyPayloadHash,
                "content-type": "application/json",
            ],
            payloadHash: SigV4Signer.emptyPayloadHash
        )
        var reordered = first
        reordered.headers = [
            "content-type": "application/json",
            "X-Amz-Content-Sha256": SigV4Signer.emptyPayloadHash,
            "X-Amz-Date": "20260901T101500Z",
            "HOST": "object.storage.eu01.onstackit.cloud",
        ]
        XCTAssertEqual(
            suiteSigner.signature(first, at: suiteDate),
            suiteSigner.signature(reordered, at: suiteDate)
        )
    }
}
