import XCTest
@testable import ConceptualFitness

final class DataSourceTests: XCTestCase {
    private func connection(_ provider: String?, _ status: HealthConnectionState, lastSync: String? = nil) -> HealthConnectionStatus {
        HealthConnectionStatus(provider: provider, status: status, connectedAt: nil, lastSyncAt: lastSync, lastError: nil)
    }

    func testProvidersMapToDevices() {
        XCTAssertEqual(DataSourceDevice(provider: "apple_health"), .appleWatch)
        XCTAssertEqual(DataSourceDevice(provider: "google_health"), .fitbit)
        XCTAssertNil(DataSourceDevice(provider: nil))
        XCTAssertNil(DataSourceDevice(provider: "garmin"))
    }

    func testDisconnectedConnectionHasNoActiveDevice() {
        XCTAssertEqual(connection("apple_health", .disconnected).device, .appleWatch)
        XCTAssertNil(connection("apple_health", .disconnected).activeDevice)
        XCTAssertEqual(connection("google_health", .errored).activeDevice, .fitbit)
    }

    func testDeviceNamesFollowAppleNaming() {
        XCTAssertEqual(DataSourceDevice.appleWatch.title, "Apple Watch")
        XCTAssertEqual(DataSourceDevice.fitbit.title, "Fitbit / Google devices")
        XCTAssertFalse(DataSourceDevice.allCases.map(\.detail).joined().contains("HealthKit"))
    }

    func testSwitchCopyNamesBothDevicesAndKeepsHistory() {
        let copy = DeviceSwitchCopy.confirmation(from: .fitbit, to: .appleWatch)

        XCTAssertTrue(copy.hasPrefix("Fitbit imports will stop"))
        XCTAssertTrue(copy.contains("Your history stays."))
        XCTAssertTrue(copy.contains("Apple Watch measures differently"))
        XCTAssertFalse(DeviceSwitchCopy.confirmation(from: .appleWatch, to: .fitbit).contains("access"))
    }

    @MainActor
    func testCoordinatorOnlyHasASourceWhenConnected() {
        let coordinator = AppSyncCoordinator(client: DashboardAPIClient(), connection: connection(nil, .disconnected))
        XCTAssertFalse(coordinator.hasActiveSource)

        coordinator.updateConnection(connection("google_health", .errored))
        XCTAssertFalse(coordinator.hasActiveSource)

        coordinator.updateConnection(connection("apple_health", .connected))
        XCTAssertTrue(coordinator.hasActiveSource)
    }

    @MainActor
    func testSwitchingDeviceResetsSyncState() {
        let coordinator = AppSyncCoordinator(
            client: DashboardAPIClient(),
            connection: connection("google_health", .connected, lastSync: "2026-11-09T08:00:00Z")
        )
        XCTAssertNotNil(coordinator.lastSyncAt)
        let token = coordinator.refreshToken

        coordinator.updateConnection(connection("apple_health", .connected))

        XCTAssertNil(coordinator.lastSyncAt)
        XCTAssertGreaterThan(coordinator.refreshToken, token)
    }
}
