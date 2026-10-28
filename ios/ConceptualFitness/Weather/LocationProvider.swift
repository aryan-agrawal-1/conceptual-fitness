import CoreLocation
import Foundation

@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var locationName: String?
    @Published private(set) var revision = 0

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var wantsLocation = false

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    func requestLocation() {
        wantsLocation = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            locationName = "Location unavailable"
        @unknown default:
            locationName = "Location unavailable"
        }
    }

    func refreshAuthorizationStatus() {
        authorizationStatus = manager.authorizationStatus
    }

    func stopLocationRequests() {
        wantsLocation = false
        geocoder.cancelGeocode()
        location = nil
        locationName = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
            if wantsLocation && (authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways) {
                manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor in
            guard wantsLocation else { return }
            location = latest
            revision += 1
            await reverseGeocode(latest)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            locationName = "Weather fallback"
        }
    }

    private func reverseGeocode(_ location: CLLocation) async {
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            let placemark = placemarks.first
            locationName = placemark?.locality ?? placemark?.administrativeArea ?? placemark?.country ?? "Current location"
        } catch {
            locationName = "Current location"
        }
    }
}
