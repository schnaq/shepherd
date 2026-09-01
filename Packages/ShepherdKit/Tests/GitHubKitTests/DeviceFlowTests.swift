import Foundation
import ShepherdCore
import XCTest
@testable import GitHubKit

final class DeviceFlowTests: XCTestCase {
    private let clientID = "Iv1.shepherd-public-id"

    private func authenticator(
        transport: MockTransport,
        sleeper: any Sleeping = RecordingSleeper(),
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 0) }
    ) -> DeviceFlowAuthenticator {
        DeviceFlowAuthenticator(
            clientID: clientID,
            transport: transport,
            sleeper: sleeper,
            now: now
        )
    }

    func testDeviceCodeRequestUsesTheDocumentedEndpointAndForm() async throws {
        let transport = MockTransport()
        let response = try Fixture.response("device-code")
        await transport.route("/login/device/code", response)

        let grant = try await authenticator(transport: transport)
            .requestDeviceCode(scopes: ["repo", "read:org"])

        XCTAssertEqual(grant.userCode, "WDJB-MJHT")
        XCTAssertEqual(grant.deviceCode, "3584d83530557fdd1f46af8289938c8ef79f9dc5")
        XCTAssertEqual(grant.verificationURI.absoluteString, "https://github.com/login/device")
        XCTAssertEqual(grant.expiresIn, 900)
        XCTAssertEqual(grant.interval, 5)
        XCTAssertEqual(grant.expiresAt, Date(timeIntervalSince1970: 900))

        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(
            request?.url.absoluteString,
            "https://github.com/login/device/code"
        )
        XCTAssertEqual(request?.headers["Accept"], "application/json")
        let body = String(decoding: request?.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("client_id=Iv1.shepherd-public-id"))
        XCTAssertTrue(body.contains("scope=repo%20read%3Aorg"))
        XCTAssertFalse(body.contains("client_secret"), "the device flow needs no secret")
    }

    func testPollingWaitsThroughAuthorizationPendingAndSlowDown() async throws {
        let transport = MockTransport()
        let pending = try Fixture.response("device-token-pending")
        let slowDown = try Fixture.response("device-token-slow-down")
        let success = try Fixture.response("device-token-success")
        await transport.route("/login/oauth/access_token", pending)
        await transport.route("/login/oauth/access_token", slowDown)
        await transport.route("/login/oauth/access_token", success)

        let sleeper = RecordingSleeper()
        let grant = DeviceCodeGrant(
            deviceCode: "device",
            userCode: "WDJB-MJHT",
            verificationURI: URL(fileURLWithPath: "/"),
            expiresIn: 900,
            interval: 5,
            issuedAt: Date(timeIntervalSince1970: 0)
        )
        let tokens = try await authenticator(transport: transport, sleeper: sleeper)
            .pollForToken(grant)

        XCTAssertEqual(tokens.accessToken, "ghu_16C7e42F292c6912E7710c838347Ae178B4a")
        XCTAssertEqual(tokens.refreshToken, "ghr_1B4a2e77838347a7E420ce178F2E7c6912E169")
        XCTAssertEqual(tokens.expiresAt, Date(timeIntervalSince1970: 28_800))
        XCTAssertTrue(tokens.isRefreshable)

        let waits = await sleeper.recorded
        XCTAssertEqual(waits.count, 3)
        XCTAssertEqual(waits[0].inSeconds, 5, accuracy: 0.001)
        XCTAssertEqual(waits[1].inSeconds, 5, accuracy: 0.001)
        XCTAssertEqual(
            waits[2].inSeconds,
            10,
            accuracy: 0.001,
            "slow_down must widen the interval"
        )
    }

    func testAccessDeniedSurfacesAsATypedError() async throws {
        let transport = MockTransport()
        let denied = try Fixture.response("device-token-denied")
        await transport.route("/login/oauth/access_token", denied)

        let grant = DeviceCodeGrant(
            deviceCode: "device",
            userCode: "X",
            verificationURI: URL(fileURLWithPath: "/"),
            expiresIn: 900,
            interval: 1,
            issuedAt: Date(timeIntervalSince1970: 0)
        )
        do {
            _ = try await authenticator(transport: transport).pollForToken(grant)
            XCTFail("expected the denial to surface")
        } catch let error as GitHubError {
            XCTAssertEqual(error, .deviceFlowDenied)
        }
    }

    func testExpiredGrantStopsPolling() async throws {
        let transport = MockTransport()
        let pending = try Fixture.response("device-token-pending")
        await transport.route("/login/oauth/access_token", pending)

        // The clock is already past the grant's deadline.
        let grant = DeviceCodeGrant(
            deviceCode: "device",
            userCode: "X",
            verificationURI: URL(fileURLWithPath: "/"),
            expiresIn: 900,
            interval: 5,
            issuedAt: Date(timeIntervalSince1970: 0)
        )
        do {
            _ = try await authenticator(
                transport: transport,
                now: { Date(timeIntervalSince1970: 1_000) }
            ).pollForToken(grant)
            XCTFail("expected the grant to expire")
        } catch let error as GitHubError {
            XCTAssertEqual(error, .deviceFlowExpired)
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty, "an expired grant must not be polled at all")
    }

    func testExpiredTokenErrorMapsToExpired() {
        XCTAssertEqual(
            DeviceFlowAuthenticator.mapDeviceFlowError(code: "expired_token", description: nil),
            .deviceFlowExpired
        )
        XCTAssertEqual(
            DeviceFlowAuthenticator.mapDeviceFlowError(code: "access_denied", description: nil),
            .deviceFlowDenied
        )
        XCTAssertEqual(
            DeviceFlowAuthenticator.mapDeviceFlowError(
                code: "unsupported_grant_type",
                description: "nope"
            ),
            .deviceFlowError(code: "unsupported_grant_type", description: "nope")
        )
    }

    func testAuthenticatePresentsTheUserCodeBeforePolling() async throws {
        let transport = MockTransport()
        let code = try Fixture.response("device-code")
        let success = try Fixture.response("device-token-success")
        await transport.route("/login/device/code", code)
        await transport.route("/login/oauth/access_token", success)

        let presented = PresentationRecorder()
        let tokens = try await authenticator(transport: transport).authenticate { grant in
            presented.record(grant.userCode)
        }
        XCTAssertEqual(tokens.accessToken, "ghu_16C7e42F292c6912E7710c838347Ae178B4a")
        XCTAssertEqual(presented.value, "WDJB-MJHT")
    }

    // MARK: - Refresh

    func testRefresherExchangesARefreshToken() async throws {
        let transport = MockTransport()
        let success = try Fixture.response("device-token-success")
        await transport.route("/login/oauth/access_token", success)

        let refresher = TokenRefresher(
            clientID: clientID,
            transport: transport,
            now: { Date(timeIntervalSince1970: 100) }
        )
        let tokens = try await refresher.refresh(refreshToken: "ghr_old")
        XCTAssertEqual(tokens.accessToken, "ghu_16C7e42F292c6912E7710c838347Ae178B4a")
        XCTAssertEqual(tokens.expiresAt, Date(timeIntervalSince1970: 28_900))

        let request = await transport.onlyRequest()
        let body = String(decoding: request?.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=ghr_old"))
    }

    func testRefreshFailureIsTyped() async throws {
        let transport = MockTransport()
        await transport.route(
            "/login/oauth/access_token",
            Fixture.response(
                json: "{\"error\":\"bad_refresh_token\",\"error_description\":\"expired\"}"
            )
        )
        let refresher = TokenRefresher(clientID: clientID, transport: transport)
        do {
            _ = try await refresher.refresh(refreshToken: "ghr_old")
            XCTFail("expected the refresh to fail")
        } catch let error as GitHubError {
            guard case .tokenRefreshFailed(let message) = error else {
                return XCTFail("expected .tokenRefreshFailed, got \(error)")
            }
            XCTAssertEqual(message, "expired")
        }
    }

    // MARK: - Token store and provider

    func testInMemoryTokenStoreRoundTrip() async throws {
        let store = InMemoryTokenStore()
        let token = TokenSet(accessToken: "a", refreshToken: "r", expiresAt: nil)
        try await store.setToken(token, for: "octocat")

        let loaded = try await store.token(for: "octocat")
        XCTAssertEqual(loaded, token)

        let logins = await store.storedLogins
        XCTAssertEqual(logins, ["octocat"])

        try await store.deleteToken(for: "octocat")
        let afterDeletion = try await store.token(for: "octocat")
        XCTAssertNil(afterDeletion)
    }

    func testExpiryIsEvaluatedWithLeeway() {
        let token = TokenSet(
            accessToken: "a",
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertFalse(token.isExpired(at: Date(timeIntervalSince1970: 800), leeway: 60))
        XCTAssertTrue(token.isExpired(at: Date(timeIntervalSince1970: 950), leeway: 60))
        XCTAssertFalse(
            TokenSet(accessToken: "pat").isExpired(at: Date(timeIntervalSince1970: 10_000)),
            "personal access tokens have no known expiry"
        )
    }

    func testRefreshingProviderRenewsAnExpiredToken() async throws {
        let transport = MockTransport()
        let success = try Fixture.response("device-token-success")
        await transport.route("/login/oauth/access_token", success)

        let store = InMemoryTokenStore()
        try await store.setToken(
            TokenSet(
                accessToken: "stale",
                refreshToken: "ghr_old",
                expiresAt: Date(timeIntervalSince1970: 10)
            ),
            for: "octocat"
        )

        let provider = RefreshingTokenProvider(
            login: "octocat",
            store: store,
            refresher: TokenRefresher(
                clientID: clientID,
                transport: transport,
                now: { Date(timeIntervalSince1970: 100) }
            ),
            now: { Date(timeIntervalSince1970: 100) }
        )
        let token = try await provider.accessToken()
        XCTAssertEqual(token, "ghu_16C7e42F292c6912E7710c838347Ae178B4a")

        let stored = try await store.token(for: "octocat")
        XCTAssertEqual(stored?.accessToken, "ghu_16C7e42F292c6912E7710c838347Ae178B4a")
    }

    func testConcurrentCallersShareOneRefresh() async throws {
        let transport = MockTransport()
        await transport.route(
            "/login/oauth/access_token",
            try Fixture.response("device-token-success")
        )

        let store = InMemoryTokenStore()
        try await store.setToken(
            TokenSet(
                accessToken: "stale",
                refreshToken: "ghr_old",
                expiresAt: Date(timeIntervalSince1970: 10)
            ),
            for: "octocat"
        )

        let provider = RefreshingTokenProvider(
            login: "octocat",
            store: store,
            refresher: TokenRefresher(
                clientID: clientID,
                transport: transport,
                now: { Date(timeIntervalSince1970: 100) }
            ),
            now: { Date(timeIntervalSince1970: 100) }
        )

        // A sweep fires five detail fetches at once, each asking for a token.
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 {
                group.addTask { try await provider.accessToken() }
            }
            var collected: [String] = []
            for try await token in group { collected.append(token) }
            return collected
        }

        XCTAssertEqual(tokens.count, 5)
        XCTAssertEqual(
            Set(tokens),
            ["ghu_16C7e42F292c6912E7710c838347Ae178B4a"],
            "every caller gets the winner's token"
        )

        // GitHub App refresh tokens are single-use and rotate: a second POST with the same
        // token fails, and its loser could overwrite the winner's fresh pair in the store.
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1, "five callers, exactly one refresh")

        let stored = try await store.token(for: "octocat")
        XCTAssertEqual(stored?.accessToken, "ghu_16C7e42F292c6912E7710c838347Ae178B4a")
    }

    func testAFreshTokenIsReturnedWithoutRefreshingAgain() async throws {
        let transport = MockTransport()
        await transport.route(
            "/login/oauth/access_token",
            try Fixture.response("device-token-success")
        )
        let store = InMemoryTokenStore()
        try await store.setToken(
            TokenSet(
                accessToken: "stale",
                refreshToken: "ghr_old",
                expiresAt: Date(timeIntervalSince1970: 10)
            ),
            for: "octocat"
        )
        let provider = RefreshingTokenProvider(
            login: "octocat",
            store: store,
            refresher: TokenRefresher(
                clientID: clientID,
                transport: transport,
                now: { Date(timeIntervalSince1970: 100) }
            ),
            now: { Date(timeIntervalSince1970: 100) }
        )

        _ = try await provider.accessToken()
        _ = try await provider.accessToken()

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1, "the second call reads the renewed token from the store")
    }

    func testRefreshingProviderReportsAMissingToken() async {
        let provider = RefreshingTokenProvider(login: "nobody", store: InMemoryTokenStore())
        do {
            _ = try await provider.accessToken()
            XCTFail("expected a missing-token error")
        } catch let error as GitHubError {
            XCTAssertEqual(error, .missingToken(login: "nobody"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

/// A tiny thread-confined recorder for the presentation callback.
///
/// The callback is `@Sendable`, so the recorder has to be safe to touch from another
/// isolation domain; a lock keeps that honest without pulling in an actor for one string.
private final class PresentationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    func record(_ value: String) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
