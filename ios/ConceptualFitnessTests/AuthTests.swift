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
}
