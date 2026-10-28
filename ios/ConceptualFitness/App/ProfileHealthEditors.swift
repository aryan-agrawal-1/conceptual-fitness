import CoreLocation
import SwiftUI

struct ProfileBodyEditor: View {
    let store: ProfileStore
    let profile: AccountProfile
    @State private var height = ""
    @State private var weight = ""
    @State private var heightSource: String
    @State private var weightSource: String
    @State private var measurementTime = Date().ISO8601Format()

    init(store: ProfileStore, profile: AccountProfile) {
        self.store = store
        self.profile = profile
        _heightSource = State(initialValue: profile.heightProvenance.preference)
        _weightSource = State(initialValue: profile.weightProvenance.preference)
    }

    private var current: AccountProfile { store.profile ?? profile }
    private var units: ProfileUnits { profile.unitSystem }

    var body: some View {
        ProfileSaveForm(title: "Body measurements", store: store, validationMessage: validationMessage, save: save) {
            measurementSection("Height", value: current.heightCm.map { "\(ProfileInput.number(units.height($0))) \(units.heightSymbol)" }, provenance: current.heightProvenance, preference: $heightSource)
            measurementSection("Weight", value: current.weightKg.map(units.massText), provenance: current.weightProvenance, preference: $weightSource)
            Section {
                TextField("New height (\(units.heightSymbol))", text: $height).keyboardType(.decimalPad)
                    .onChange(of: height) { _, value in if !value.isEmpty { heightSource = "manual" } }
                TextField("New weight (\(units.massSymbol))", text: $weight).keyboardType(.decimalPad)
                    .onChange(of: weight) { _, value in if !value.isEmpty { weightSource = "manual" } }
            } header: { Text("Add manual measurements") } footer: {
                Text("Leave either field blank to keep its records. New measurements are recorded now. Entering a value selects Manual as its preferred source; you can change that selection before saving.")
            }
        }
    }

    private func measurementSection(_ title: String, value: String?, provenance: ProfileProvenance, preference: Binding<String>) -> some View {
        Section(title) {
            LabeledContent("Current value", value: value ?? "Not set")
            Picker("Preferred source", selection: preference) {
                Text("Google Health").tag("google")
                Text("Manual").tag("manual")
            }
            .accessibilityLabel("\(title) preferred source")
            LabeledContent("Active source", value: provenance.activeSource?.displayTitle ?? "No matching source record")
            LabeledContent("Measured", value: DashboardFormatters.parseBackendDateTime(provenance.updatedAt)?.formatted(date: .abbreviated, time: .shortened) ?? "Timestamp unavailable")
            if provenance.activeSource == nil {
                Text(value == nil ? "Add a manual value or sync a measurement from Google Health." : "This is a saved profile value. The selected source has no matching measurement yet.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var validationMessage: String? {
        if !height.isEmpty {
            guard let value = ProfileInput.decimal(height), value > 0, units.centimeters(value) <= 260 else {
                return "Enter a positive height up to \(ProfileInput.number(units.height(260))) \(units.heightSymbol)."
            }
        }
        if !weight.isEmpty {
            guard let value = ProfileInput.decimal(weight), value > 0, units.kilograms(value) <= 700 else {
                return "Enter a positive weight up to \(ProfileInput.number(units.mass(700))) \(units.massSymbol)."
            }
        }
        return nil
    }

    @MainActor private func save() async throws {
        if !height.isEmpty || !weight.isEmpty {
            var fields: [String: ProfileValue] = ["observed_at": .text(measurementTime)]
            if let value = ProfileInput.decimal(height) { fields["height_cm"] = .number(units.centimeters(value)) }
            if let value = ProfileInput.decimal(weight) { fields["weight_kg"] = .number(units.kilograms(value)) }
            let _: BodyResponse = try await store.authStore.authenticatedJSON(path: "/body-metrics", method: "POST", body: fields)
        }
        try await store.update(["height_source_preference": .text(heightSource), "weight_source_preference": .text(weightSource)])
    }

    private struct BodyResponse: Decodable { let bmi: Double? }
}

struct ProfileWeatherEditor: View {
    let store: ProfileStore
    @StateObject private var location = LocationProvider()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var weatherEnabled: Bool

    init(store: ProfileStore, profile: AccountProfile) {
        self.store = store
        _weatherEnabled = State(initialValue: profile.weatherEnabled)
    }

    var body: some View {
        ProfileSaveForm(title: "Location and weather", store: store, save: {
            try await store.update(["weather_enabled": .bool(weatherEnabled), "location_permission_status": .text(permissionValue)])
            try await store.authStore.refreshSession()
        }) {
            Section {
                Toggle("Weather on dashboard", isOn: $weatherEnabled)
                Text("Uses local weather for the dashboard background. When weather or location is unavailable, the dashboard uses its plain background.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Location permission") {
                LabeledContent("iOS permission", value: permissionTitle)
                if location.authorizationStatus == .notDetermined {
                    Button("Allow location") { location.requestLocation() }
                } else {
                    Button("Open iOS Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                }
                Text("Turning weather off does not revoke iOS permission. Change permission in Settings. Choose your health-data timezone in Personal details.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { location.refreshAuthorizationStatus() } }
    }

    private var permissionTitle: String {
        switch location.authorizationStatus {
        case .authorizedAlways: "Always allowed"
        case .authorizedWhenInUse: "Allowed while using the app"
        case .denied: "Denied — change in Settings"
        case .restricted: "Restricted by iOS"
        case .notDetermined: "Not requested"
        @unknown default: "Unavailable"
        }
    }

    private var permissionValue: String {
        switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not_determined"
        @unknown default: "not_determined"
        }
    }
}
