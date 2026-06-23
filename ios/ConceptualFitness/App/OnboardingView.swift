import CoreLocation
import SwiftUI
import UIKit

struct OnboardingView: View {
    @ObservedObject var authStore: AuthStore
    let session: AuthSession

    @StateObject private var locationProvider: LocationProvider
    @State private var step: OnboardingStep = .name
    @State private var firstName: String
    @State private var lastName: String
    @State private var profile: UserProfilePayload?
    @State private var isLoadingProfile = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    @State private var selectedCountry = TimezoneCountry.defaultCountry
    @State private var selectedTimezone = TimezoneCountry.defaultCountry.timezones[0]
    @State private var dateOfBirth = Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
    @State private var sex: OnboardingSex?
    @State private var heightUnit: HeightUnit = .defaultUnit
    @State private var weightUnit: WeightUnit = .defaultUnit
    @State private var heightCm = ""
    @State private var heightFeet = ""
    @State private var heightInches = ""
    @State private var weightKg = ""
    @State private var weightPounds = ""

    @MainActor
    init(authStore: AuthStore, session: AuthSession) {
        self.authStore = authStore
        self.session = session
        _locationProvider = StateObject(wrappedValue: LocationProvider())
        _firstName = State(initialValue: session.user.firstName ?? "")
        _lastName = State(initialValue: session.user.lastName ?? "")
    }

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if isLoadingProfile {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.top, 80)
                        } else {
                            content
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 22)
                    .padding(.bottom, 116)
                }
                .scrollIndicators(.hidden)
            }

            VStack {
                Spacer()
                footer
            }
        }
        .task {
            await loadProfileIfNeeded()
        }
        .onChange(of: locationProvider.authorizationStatus) { _, status in
            handleLocationStatus(status)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Set up your profile")
                    .font(.title2.weight(.bold))
                Spacer()
                Text("\(step.index + 1) of \(OnboardingStep.allCases.count)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: Double(step.index + 1), total: Double(OnboardingStep.allCases.count))
                .tint(.blue)

            Text(step.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .background(.white.opacity(0.72))
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .name:
            nameStep
        case .location:
            locationStep
        case .manualTimezone:
            manualTimezoneStep
        case .body:
            bodyStep
        }
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingStepTitle(
                title: "What should we call you?"
            )

            VStack(spacing: 12) {
                LargeTextField(
                    title: "First name",
                    text: $firstName,
                    textContentType: .givenName,
                    submitLabel: .next
                ) {
                    Task { await saveNameAndContinue() }
                }
                .onChange(of: firstName) { _, _ in errorMessage = nil }

                LargeTextField(
                    title: "Last name",
                    text: $lastName,
                    textContentType: .familyName,
                    submitLabel: .done
                )
            }
        }
    }

    private var locationStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingStepTitle(
                title: "Use your location for accurate days"
            )

            Text("Location keeps your timezone, local dates, and dashboard weather aligned with where you are.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Label("Timezone-aware sleep and workout dates", systemImage: "clock")
                Label("Weather-matched dashboard background", systemImage: "cloud.sun")
                Label("No location means a plain dashboard background", systemImage: "rectangle")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary.opacity(0.86))
        }
    }

    private var manualTimezoneStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingStepTitle(
                title: "Choose your timezone"
            )

            Text("Weather backgrounds will stay off. Pick the country and timezone the app should use for your health data.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                Picker("Country", selection: $selectedCountry) {
                    ForEach(TimezoneCountry.all) { country in
                        Text(country.name).tag(country)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedCountry) { _, country in
                    selectedTimezone = country.timezones[0]
                }

                if selectedCountry.timezones.count > 1 {
                    Picker("Timezone", selection: $selectedTimezone) {
                        ForEach(selectedCountry.timezones) { timezone in
                            Text(timezone.name).tag(timezone)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .padding(16)
            .glassSurface(cornerRadius: 18)
        }
    }

    private var bodyStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingStepTitle(
                title: "Confirm your body details"
            )

            DatePicker(
                "Date of birth",
                selection: $dateOfBirth,
                in: dateRange,
                displayedComponents: .date
            )
            .datePickerStyle(.compact)

            VStack(alignment: .leading, spacing: 10) {
                Text("Sex")
                    .font(.subheadline.weight(.semibold))
                Picker("Sex", selection: sexBinding) {
                    Text("Select").tag(OnboardingSex?.none)
                    ForEach(OnboardingSex.allCases) { option in
                        Text(option.title).tag(Optional(option))
                    }
                }
                .pickerStyle(.menu)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                .padding(.horizontal, 14)
                .background(.white.opacity(0.74), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                }
            }

            measurementFields
        }
    }

    private var measurementFields: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Height")
                    .font(.subheadline.weight(.semibold))
                Picker("Height unit", selection: $heightUnit) {
                    ForEach(HeightUnit.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .pickerStyle(.segmented)

                if heightUnit == .centimeters {
                    TextField("Height in cm", text: $heightCm)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                } else {
                    HStack {
                        TextField("ft", text: $heightFeet)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                        TextField("in", text: $heightInches)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Weight")
                    .font(.subheadline.weight(.semibold))
                Picker("Weight unit", selection: $weightUnit) {
                    ForEach(WeightUnit.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .pickerStyle(.segmented)

                if weightUnit == .kilograms {
                    TextField("Weight in kg", text: $weightKg)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField("Weight in lb", text: $weightPounds)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button {
                Task { await continueTapped() }
            } label: {
                if isSaving {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(step.primaryActionTitle)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isSaving || !canContinue)

            if step.index > 0 {
                Button {
                    errorMessage = nil
                    step = step.previous
                } label: {
                    Text("Back")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isSaving)
            }
        }
        .padding(18)
        .background(.white.opacity(0.88))
    }

    private var sexBinding: Binding<OnboardingSex?> {
        Binding(
            get: { sex },
            set: {
                sex = $0
                errorMessage = nil
            }
        )
    }

    private var canContinue: Bool {
        switch step {
        case .name:
            return !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .location:
            return true
        case .manualTimezone:
            return !selectedTimezone.identifier.isEmpty
        case .body:
            return sex != nil && parsedHeightCm != nil && parsedWeightKg != nil
        }
    }

    private var parsedHeightCm: Double? {
        switch heightUnit {
        case .centimeters:
            return positiveDouble(heightCm)
        case .feetInches:
            guard let feet = positiveDouble(heightFeet) else { return nil }
            let inches = Double(heightInches.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            guard inches >= 0 else { return nil }
            return feet * 30.48 + inches * 2.54
        }
    }

    private var parsedWeightKg: Double? {
        switch weightUnit {
        case .kilograms:
            return positiveDouble(weightKg)
        case .pounds:
            guard let pounds = positiveDouble(weightPounds) else { return nil }
            return pounds * 0.45359237
        }
    }

    private var dateRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 1900, month: 1, day: 1)) ?? Date.distantPast
        return start...Date()
    }

    @MainActor
    private func loadProfileIfNeeded() async {
        guard isLoadingProfile else { return }
        do {
            let loaded: UserProfilePayload = try await authStore.authenticatedRequest(path: "/profile")
            profile = loaded
            prefill(from: loaded)
            isLoadingProfile = false
        } catch {
            errorMessage = "Could not load your profile. Check the backend and try again."
            isLoadingProfile = false
        }
    }

    @MainActor
    private func continueTapped() async {
        switch step {
        case .name:
            await saveNameAndContinue()
        case .location:
            requestLocation()
        case .manualTimezone:
            await saveManualTimezone()
        case .body:
            await finishOnboarding()
        }
    }

    @MainActor
    private func saveNameAndContinue() async {
        let cleanedFirst = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedLast = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedFirst.isEmpty else {
            errorMessage = "Enter your first name to continue."
            return
        }
        isSaving = true
        errorMessage = nil
        do {
            try await authStore.updateName(
                firstName: cleanedFirst,
                lastName: cleanedLast.isEmpty ? nil : cleanedLast
            )
            step = .location
        } catch {
            errorMessage = "Could not save your name. Try again."
        }
        isSaving = false
    }

    @MainActor
    private func requestLocation() {
        errorMessage = nil
        switch locationProvider.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            Task { await saveAuthorizedLocation() }
        case .denied, .restricted:
            step = .manualTimezone
        case .notDetermined:
            locationProvider.requestLocation()
        @unknown default:
            step = .manualTimezone
        }
    }

    @MainActor
    private func handleLocationStatus(_ status: CLAuthorizationStatus) {
        guard step == .location else { return }
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            Task { await saveAuthorizedLocation() }
        case .denied, .restricted:
            step = .manualTimezone
        case .notDetermined:
            break
        @unknown default:
            step = .manualTimezone
        }
    }

    @MainActor
    private func saveAuthorizedLocation() async {
        isSaving = true
        errorMessage = nil
        do {
            let _: UserProfilePayload = try await authStore.authenticatedJSON(
                path: "/profile",
                method: "PATCH",
                body: ProfileUpdateRequest(
                    timezone: TimeZone.current.identifier,
                    dateOfBirth: nil,
                    sex: nil,
                    weatherEnabled: true,
                    locationPermissionStatus: "authorized",
                    heightSourcePreference: nil,
                    weightSourcePreference: nil,
                    onboardingCompleted: nil
                )
            )
            locationProvider.requestLocation()
            step = .body
        } catch {
            errorMessage = "Could not save your location preference. Try again."
        }
        isSaving = false
    }

    @MainActor
    private func saveManualTimezone() async {
        isSaving = true
        errorMessage = nil
        do {
            let _: UserProfilePayload = try await authStore.authenticatedJSON(
                path: "/profile",
                method: "PATCH",
                body: ProfileUpdateRequest(
                    timezone: selectedTimezone.identifier,
                    dateOfBirth: nil,
                    sex: nil,
                    weatherEnabled: false,
                    locationPermissionStatus: "denied",
                    heightSourcePreference: nil,
                    weightSourcePreference: nil,
                    onboardingCompleted: nil
                )
            )
            step = .body
        } catch {
            errorMessage = "Could not save your timezone. Try again."
        }
        isSaving = false
    }

    @MainActor
    private func finishOnboarding() async {
        guard let sex, let height = parsedHeightCm, let weight = parsedWeightKg else {
            errorMessage = "Complete each body detail to continue."
            return
        }
        isSaving = true
        errorMessage = nil
        do {
            let _: BodyMetricsPayload = try await authStore.authenticatedJSON(
                path: "/body-metrics",
                method: "POST",
                body: BodyMetricsUpdateRequest(heightCm: height, weightKg: weight)
            )
            let _: UserProfilePayload = try await authStore.authenticatedJSON(
                path: "/profile",
                method: "PATCH",
                body: ProfileUpdateRequest(
                    timezone: nil,
                    dateOfBirth: Self.apiDateFormatter.string(from: dateOfBirth),
                    sex: sex.backendValue,
                    weatherEnabled: nil,
                    locationPermissionStatus: nil,
                    heightSourcePreference: "manual",
                    weightSourcePreference: "manual",
                    onboardingCompleted: true
                )
            )
            try await authStore.refreshSession()
        } catch {
            errorMessage = "Could not finish onboarding. Check the backend and try again."
        }
        isSaving = false
    }

    private func prefill(from profile: UserProfilePayload) {
        if let dateString = profile.dateOfBirth,
           let date = Self.apiDateFormatter.date(from: dateString) {
            dateOfBirth = date
        }
        if let sexValue = profile.sex {
            sex = OnboardingSex(backendValue: sexValue)
        }
        if let height = profile.heightCm {
            if heightUnit == .centimeters {
                heightCm = Self.measurementFormatter.string(from: NSNumber(value: height)) ?? ""
            } else {
                let totalInches = height / 2.54
                let feet = floor(totalInches / 12)
                let inches = totalInches - feet * 12
                heightFeet = String(Int(feet))
                heightInches = Self.measurementFormatter.string(from: NSNumber(value: inches)) ?? ""
            }
        }
        if let weight = profile.weightKg {
            if weightUnit == .kilograms {
                weightKg = Self.measurementFormatter.string(from: NSNumber(value: weight)) ?? ""
            } else {
                weightPounds = Self.measurementFormatter.string(from: NSNumber(value: weight / 0.45359237)) ?? ""
            }
        }
    }

    private func positiveDouble(_ value: String) -> Double? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Double(cleaned), number > 0 else { return nil }
        return number
    }

    private static let apiDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let measurementFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        return formatter
    }()
}

private enum OnboardingStep: CaseIterable {
    case name
    case location
    case manualTimezone
    case body

    var index: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    var previous: OnboardingStep {
        switch self {
        case .name:
            return .name
        case .location:
            return .name
        case .manualTimezone:
            return .location
        case .body:
            return .location
        }
    }

    var subtitle: String {
        switch self {
        case .name:
            return "Start with the account details used across the app."
        case .location:
            return "Location helps the app match your local day and dashboard weather."
        case .manualTimezone:
            return "Since location is unavailable, choose the timezone to apply."
        case .body:
            return "These values improve estimates that depend on age and body metrics."
        }
    }

    var primaryActionTitle: String {
        switch self {
        case .name, .manualTimezone:
            return "Continue"
        case .location:
            return "Use my location"
        case .body:
            return "Finish"
        }
    }

}

private struct OnboardingStepTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LargeTextField: View {
    let title: String
    @Binding var text: String
    let textContentType: UITextContentType
    let submitLabel: SubmitLabel
    var onSubmit: (() -> Void)?

    init(
        title: String,
        text: Binding<String>,
        textContentType: UITextContentType,
        submitLabel: SubmitLabel,
        onSubmit: (() -> Void)? = nil
    ) {
        self.title = title
        _text = text
        self.textContentType = textContentType
        self.submitLabel = submitLabel
        self.onSubmit = onSubmit
    }

    var body: some View {
        TextField(title, text: $text)
            .font(.title3.weight(.semibold))
            .textContentType(textContentType)
            .textInputAutocapitalization(.words)
            .submitLabel(submitLabel)
            .onSubmit { onSubmit?() }
            .padding(.horizontal, 16)
            .frame(minHeight: 64)
            .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
            }
    }
}

private enum OnboardingSex: String, CaseIterable, Identifiable {
    case female
    case male
    case other
    case preferNotToSay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .female:
            return "Female"
        case .male:
            return "Male"
        case .other:
            return "Other"
        case .preferNotToSay:
            return "Prefer not to say"
        }
    }

    var backendValue: String {
        switch self {
        case .female:
            return "female"
        case .male:
            return "male"
        case .other, .preferNotToSay:
            return "not_specified"
        }
    }

    init?(backendValue: String) {
        switch backendValue {
        case "female":
            self = .female
        case "male":
            self = .male
        case "not_specified":
            self = .preferNotToSay
        default:
            return nil
        }
    }
}

private enum HeightUnit: String, CaseIterable, Identifiable {
    case centimeters
    case feetInches

    var id: String { rawValue }
    var title: String { self == .centimeters ? "cm" : "ft/in" }

    static var defaultUnit: HeightUnit {
        Locale.current.region?.identifier == "US" ? .feetInches : .centimeters
    }
}

private enum WeightUnit: String, CaseIterable, Identifiable {
    case kilograms
    case pounds

    var id: String { rawValue }
    var title: String { self == .kilograms ? "kg" : "lb" }

    static var defaultUnit: WeightUnit {
        Locale.current.region?.identifier == "US" ? .pounds : .kilograms
    }
}

private struct TimezoneChoice: Identifiable, Hashable {
    let identifier: String
    let name: String

    var id: String { identifier }
}

private struct TimezoneCountry: Identifiable, Hashable {
    let code: String
    let name: String
    let timezones: [TimezoneChoice]

    var id: String { code }

    static let defaultCountry = TimezoneCountry(
        code: "GB",
        name: "United Kingdom",
        timezones: [TimezoneChoice(identifier: "Europe/London", name: "United Kingdom")]
    )

    static let all: [TimezoneCountry] = [
        defaultCountry,
        TimezoneCountry(
            code: "US",
            name: "United States",
            timezones: [
                TimezoneChoice(identifier: "America/New_York", name: "Eastern"),
                TimezoneChoice(identifier: "America/Chicago", name: "Central"),
                TimezoneChoice(identifier: "America/Denver", name: "Mountain"),
                TimezoneChoice(identifier: "America/Los_Angeles", name: "Pacific"),
                TimezoneChoice(identifier: "America/Anchorage", name: "Alaska"),
                TimezoneChoice(identifier: "Pacific/Honolulu", name: "Hawaii"),
            ]
        ),
        TimezoneCountry(
            code: "CA",
            name: "Canada",
            timezones: [
                TimezoneChoice(identifier: "America/Toronto", name: "Eastern"),
                TimezoneChoice(identifier: "America/Winnipeg", name: "Central"),
                TimezoneChoice(identifier: "America/Edmonton", name: "Mountain"),
                TimezoneChoice(identifier: "America/Vancouver", name: "Pacific"),
                TimezoneChoice(identifier: "America/Halifax", name: "Atlantic"),
            ]
        ),
        TimezoneCountry(
            code: "AU",
            name: "Australia",
            timezones: [
                TimezoneChoice(identifier: "Australia/Sydney", name: "Eastern"),
                TimezoneChoice(identifier: "Australia/Adelaide", name: "Central"),
                TimezoneChoice(identifier: "Australia/Perth", name: "Western"),
            ]
        ),
        TimezoneCountry(code: "IE", name: "Ireland", timezones: [TimezoneChoice(identifier: "Europe/Dublin", name: "Ireland")]),
        TimezoneCountry(code: "FR", name: "France", timezones: [TimezoneChoice(identifier: "Europe/Paris", name: "France")]),
        TimezoneCountry(code: "DE", name: "Germany", timezones: [TimezoneChoice(identifier: "Europe/Berlin", name: "Germany")]),
        TimezoneCountry(code: "ES", name: "Spain", timezones: [TimezoneChoice(identifier: "Europe/Madrid", name: "Mainland Spain")]),
        TimezoneCountry(code: "IT", name: "Italy", timezones: [TimezoneChoice(identifier: "Europe/Rome", name: "Italy")]),
        TimezoneCountry(code: "NL", name: "Netherlands", timezones: [TimezoneChoice(identifier: "Europe/Amsterdam", name: "Netherlands")]),
        TimezoneCountry(code: "SE", name: "Sweden", timezones: [TimezoneChoice(identifier: "Europe/Stockholm", name: "Sweden")]),
        TimezoneCountry(code: "NO", name: "Norway", timezones: [TimezoneChoice(identifier: "Europe/Oslo", name: "Norway")]),
        TimezoneCountry(code: "DK", name: "Denmark", timezones: [TimezoneChoice(identifier: "Europe/Copenhagen", name: "Denmark")]),
        TimezoneCountry(code: "CH", name: "Switzerland", timezones: [TimezoneChoice(identifier: "Europe/Zurich", name: "Switzerland")]),
        TimezoneCountry(code: "PT", name: "Portugal", timezones: [TimezoneChoice(identifier: "Europe/Lisbon", name: "Portugal")]),
        TimezoneCountry(code: "IN", name: "India", timezones: [TimezoneChoice(identifier: "Asia/Kolkata", name: "India")]),
        TimezoneCountry(code: "SG", name: "Singapore", timezones: [TimezoneChoice(identifier: "Asia/Singapore", name: "Singapore")]),
        TimezoneCountry(code: "JP", name: "Japan", timezones: [TimezoneChoice(identifier: "Asia/Tokyo", name: "Japan")]),
        TimezoneCountry(code: "KR", name: "South Korea", timezones: [TimezoneChoice(identifier: "Asia/Seoul", name: "South Korea")]),
        TimezoneCountry(code: "CN", name: "China", timezones: [TimezoneChoice(identifier: "Asia/Shanghai", name: "China")]),
        TimezoneCountry(code: "BR", name: "Brazil", timezones: [TimezoneChoice(identifier: "America/Sao_Paulo", name: "Brasilia")]),
        TimezoneCountry(code: "MX", name: "Mexico", timezones: [TimezoneChoice(identifier: "America/Mexico_City", name: "Central")]),
        TimezoneCountry(code: "NZ", name: "New Zealand", timezones: [TimezoneChoice(identifier: "Pacific/Auckland", name: "New Zealand")]),
        TimezoneCountry(code: "ZA", name: "South Africa", timezones: [TimezoneChoice(identifier: "Africa/Johannesburg", name: "South Africa")]),
        TimezoneCountry(code: "AE", name: "United Arab Emirates", timezones: [TimezoneChoice(identifier: "Asia/Dubai", name: "UAE")]),
        TimezoneCountry(code: "OTHER", name: "Other", timezones: TimeZone.knownTimeZoneIdentifiers.map { TimezoneChoice(identifier: $0, name: $0) }),
    ]
}

private struct UserProfilePayload: Decodable {
    let timezone: String
    let dateOfBirth: String?
    let sex: String?
    let heightCm: Double?
    let weightKg: Double?
    let weatherEnabled: Bool
    let onboardingCompletedAt: String?

    enum CodingKeys: String, CodingKey {
        case timezone
        case dateOfBirth = "date_of_birth"
        case sex
        case heightCm = "height_cm"
        case weightKg = "weight_kg"
        case weatherEnabled = "weather_enabled"
        case onboardingCompletedAt = "onboarding_completed_at"
    }
}

private struct ProfileUpdateRequest: Encodable {
    let timezone: String?
    let dateOfBirth: String?
    let sex: String?
    let weatherEnabled: Bool?
    let locationPermissionStatus: String?
    let heightSourcePreference: String?
    let weightSourcePreference: String?
    let onboardingCompleted: Bool?

    enum CodingKeys: String, CodingKey {
        case timezone
        case dateOfBirth = "date_of_birth"
        case sex
        case weatherEnabled = "weather_enabled"
        case locationPermissionStatus = "location_permission_status"
        case heightSourcePreference = "height_source_preference"
        case weightSourcePreference = "weight_source_preference"
        case onboardingCompleted = "onboarding_completed"
    }
}

private struct BodyMetricsUpdateRequest: Encodable {
    let heightCm: Double
    let weightKg: Double

    enum CodingKeys: String, CodingKey {
        case heightCm = "height_cm"
        case weightKg = "weight_kg"
    }
}

private struct BodyMetricsPayload: Decodable {
    let heightCm: Double?
    let weightKg: Double?

    enum CodingKeys: String, CodingKey {
        case heightCm = "height_cm"
        case weightKg = "weight_kg"
    }
}

#Preview {
    OnboardingView(authStore: AuthStore(), session: .preview)
}
