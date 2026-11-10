import XCTest
@testable import ConceptualFitness

final class AuthTests: XCTestCase {
    func testSessionDecodesASignedInUserWithoutAHealthConnection() throws {
        let json = """
        {
          "user": {"id": "user-1", "email": "person@example.com", "first_name": null, "last_name": null},
          "health_connection": {
            "provider": null, "status": "disconnected",
            "connected_at": null, "last_sync_at": null, "last_error": null
          },
          "profile": {"onboarding_completed_at": null, "weather_enabled": false}
        }
        """
        let session = try JSONDecoder().decode(AuthMeResponse.self, from: Data(json.utf8)).session

        XCTAssertNil(session.healthConnection.provider)
        XCTAssertEqual(session.healthConnection.status, .disconnected)
    }

    func testSessionDecodesAConnectedFitbit() throws {
        let json = """
        {
          "user": {"id": "user-1", "email": null, "first_name": "Aryan", "last_name": null},
          "health_connection": {
            "provider": "google_health", "status": "connected",
            "connected_at": "2026-11-09T08:00:00Z", "last_sync_at": null, "last_error": null
          },
          "profile": {"onboarding_completed_at": null, "weather_enabled": true}
        }
        """
        let session = try JSONDecoder().decode(AuthMeResponse.self, from: Data(json.utf8)).session

        XCTAssertEqual(session.healthConnection.provider, "google_health")
        XCTAssertEqual(session.healthConnection.status, .connected)
    }

    func testConnectedCallbacksReportNoError() {
        XCTAssertNil(AuthStore.healthConnectionOutcome(from: URL(string: "healthapp://auth/callback?status=health_connected")!))
        XCTAssertNil(AuthStore.healthConnectionOutcome(from: URL(string: "healthapp://auth/callback?status=health_connected_queued")!))
    }

    func testHealthAccountInUseExplainsTheConflict() throws {
        let message = try XCTUnwrap(AuthStore.healthConnectionOutcome(
            from: URL(string: "healthapp://auth/callback?status=error&reason=health_account_in_use")!
        ))

        XCTAssertTrue(message.contains("already connected to a different"))
    }

    func testOtherCallbackErrorsOfferARetry() {
        XCTAssertEqual(
            AuthStore.healthConnectionOutcome(from: URL(string: "healthapp://auth/callback?status=error&reason=oauth_failed")!),
            "Fitbit wasn’t connected. You can try again."
        )
    }

    func testSessionDecodesTheSignInProvider() throws {
        let json = """
        {
          "user": {"id": "user-1", "sign_in_provider": "apple", "email": null, "first_name": null, "last_name": null},
          "health_connection": {
            "provider": null, "status": "disconnected",
            "connected_at": null, "last_sync_at": null, "last_error": null
          },
          "profile": {"onboarding_completed_at": null, "weather_enabled": false}
        }
        """
        let session = try JSONDecoder().decode(AuthMeResponse.self, from: Data(json.utf8)).session

        XCTAssertEqual(session.user.signInProvider, .apple)
    }

    func testCachedSessionsFromBeforeAppleSignInStillDecode() throws {
        let json = """
        {
          "user": {"id": "user-1", "email": null, "first_name": null, "last_name": null},
          "health_connection": {
            "provider": null, "status": "disconnected",
            "connected_at": null, "last_sync_at": null, "last_error": null
          },
          "profile": {"onboarding_completed_at": null, "weather_enabled": false}
        }
        """

        XCTAssertNil(try JSONDecoder().decode(AuthSession.self, from: Data(json.utf8)).user.signInProvider)
    }

    func testNonceIsHashedForApple() {
        XCTAssertEqual(
            AuthStore.sha256Hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testRecoveryGrantNeedsAnAuthorizedRecoveryResponse() throws {
        let authorized = AppleCompletionResponse(status: "authorized", code: nil, grant: "grant-1", purpose: "recover_deletion")
        let signedIn = AppleCompletionResponse(status: "signed_in", code: "code-1", grant: nil, purpose: nil)

        XCTAssertEqual(try AuthStore.recoveryGrant(from: authorized), "grant-1")
        XCTAssertThrowsError(try AuthStore.recoveryGrant(from: signedIn))
    }

    func testGoogleAccountInUseIsExplainedOnSignIn() {
        let message = AuthStore.signInFailureMessage(
            for: SignInRefusal(reason: "google_account_in_use"),
            provider: .google
        )

        XCTAssertTrue(message.contains("can’t be used to sign in"))
    }

    func testPendingDeletionIsExplainedOnAppleSignIn() {
        let message = AuthStore.signInFailureMessage(
            for: HTTPResponseError(statusCode: 403, code: "account_pending_deletion"),
            provider: .apple
        )

        XCTAssertTrue(message.contains("scheduled for deletion"))
    }

    func testCallbackReasonIsOnlyReadFromErrors() {
        XCTAssertNil(AuthStore.callbackReason(from: URL(string: "healthapp://auth/callback?status=signed_in&code=abc")!))
        XCTAssertEqual(
            AuthStore.callbackReason(from: URL(string: "healthapp://auth/callback?status=error&reason=google_account_in_use")!),
            "google_account_in_use"
        )
    }

    func testGoogleAccountInUseExplainsTheFitbitConflict() throws {
        let message = try XCTUnwrap(AuthStore.healthConnectionOutcome(
            from: URL(string: "healthapp://auth/callback?status=error&reason=google_account_in_use")!
        ))

        XCTAssertTrue(message.contains("signs in to a different"))
    }
}
