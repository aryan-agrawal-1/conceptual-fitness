import CoreLocation
import SwiftUI
import UIKit

struct OnboardingView: View {
    @ObservedObject var authStore: AuthStore
    let session: AuthSession

    @StateObject private var locationProvider: LocationProvider
    @State private var step: OnboardingStep
    @State private var firstName: String
    @State private var lastName: String
    @State private var isLoadingProfile = true
    @State private var asksName: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?

    @State private var selectedCountry = TimezoneCountry.defaultCountry
    @State private var selectedTimezone = TimezoneCountry.defaultCountry.timezones[0]
    @State private var dateOfBirth = Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
    @State private var sex: OnboardingSex?
    @State private var heightUnit: HeightUnit = .defaultUnit
    @State private var weightUnit: WeightUnit = .defaultUnit
    @State private var heightCm = 170
    @State private var heightFeet = 5
    @State private var heightInches = 7
    @State private var weightKg = 70
    @State private var weightTenths = 0
    @State private var weightPounds = 154
    @State private var device: DataSourceDevice?

    @MainActor
    init(authStore: AuthStore, session: AuthSession) {
        self.authStore = authStore
        self.session = session
        _locationProvider = StateObject(wrappedValue: LocationProvider())
        _firstName = State(initialValue: session.user.firstName ?? "")
        _lastName = State(initialValue: session.user.lastName ?? "")
        let knowsName = !(session.user.firstName ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        _step = State(initialValue: knowsName ? .location : .name)
        _asksName = State(initialValue: !knowsName)
        _device = State(initialValue: session.healthConnection.activeDevice)
    }

    var body: some View {
        ZStack {
            OnboardingSky(scene: step.scene, level: skyLevel)
                .animation(.easeInOut(duration: 0.6), value: step.scene)

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if isLoadingProfile {
                            ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 120)
                        } else {
                            OnboardingHeadline(title: step.title, subtitle: step.subtitle)
                                .padding(.top, step.headlineInset)
                            content
                                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                        }
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .onboardingGlass(cornerRadius: 16)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .id(step)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .deviceStage()
                footer
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(.snappy(duration: 0.35), value: step)
        .task {
            DeviceModels.prepare()
            await loadProfileIfNeeded()
        }
        .onChange(of: locationProvider.authorizationStatus) { _, status in
            handleLocationStatus(status)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                errorMessage = nil
                step = step.previous
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .onboardingGlass(cornerRadius: 20)
            }
            .opacity(step == firstStep ? 0 : 1)
            .disabled(step == firstStep || isSaving)
            .accessibilityLabel("Back")
            OnboardingProgressBar(position: progressPosition, total: progressSteps.count)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .name: nameStep
        case .location: locationStep
        case .manualTimezone: manualTimezoneStep
        case .birthday: birthdayStep
        case .sex: sexStep
        case .height: heightStep
        case .weight: weightStep
        case .device: deviceStep
        }
    }

    private var nameStep: some View {
        VStack(spacing: 12) {
            GlassTextField(title: "First name", text: $firstName, textContentType: .givenName, submitLabel: .next) {
                Task { await saveNameAndContinue() }
            }
            .onChange(of: firstName) { _, _ in errorMessage = nil }
            GlassTextField(title: "Last name", text: $lastName, textContentType: .familyName, submitLabel: .done)
        }
    }

    private var locationStep: some View {
        Color.clear.frame(height: 260)
    }

    private var manualTimezoneStep: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Country", selection: $selectedCountry) {
                ForEach(TimezoneCountry.all) { country in
                    Text(country.name).tag(country)
                }
            }
            .pickerStyle(.menu)
            .tint(.white)
            .onChange(of: selectedCountry) { _, country in
                selectedTimezone = country.timezones[0]
            }
            if selectedCountry.timezones.count > 1 {
                Divider().overlay(.white.opacity(0.2))
                Picker("Timezone", selection: $selectedTimezone) {
                    ForEach(selectedCountry.timezones) { timezone in
                        Text(timezone.name).tag(timezone)
                    }
                }
                .pickerStyle(.menu)
                .tint(.white)
            }
        }
        .padding(16)
        .onboardingGlass()
    }

    private var birthdayStep: some View {
        DatePicker("Date of birth", selection: $dateOfBirth, in: dateRange, displayedComponents: .date)
            .datePickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .onboardingGlass(cornerRadius: 28)
    }

    private var sexStep: some View {
        VStack(spacing: 10) {
            ForEach(OnboardingSex.allCases) { option in
                let selected = sex == option
                Button {
                    sex = option
                    errorMessage = nil
                } label: {
                    HStack {
                        Text(option.title).font(.title3.weight(.semibold))
                        Spacer()
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selected ? .white : .white.opacity(0.4))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 64)
                    .background(.white.opacity(selected ? 0.18 : 0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(selected ? 0.9 : 0.14), lineWidth: selected ? 2 : 1))
                    .contentShape(RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(.snappy, value: sex)
    }

    private var heightStep: some View {
        VStack(spacing: 18) {
            BigReading(value: heightReading, unit: heightUnit == .centimeters ? "cm" : nil)
            HStack(spacing: 0) {
                if heightUnit == .centimeters {
                    wheel(selection: $heightCm, range: 120...230, suffix: "")
                } else {
                    wheel(selection: $heightFeet, range: 3...8, suffix: "ft")
                    wheel(selection: $heightInches, range: 0...11, suffix: "in")
                }
            }
            .padding(.vertical, 4)
            .onboardingGlass(cornerRadius: 28)
            unitPicker(selection: $heightUnit)
        }
        .onChange(of: heightUnit) { _, unit in convertHeight(to: unit) }
    }

    private var weightStep: some View {
        VStack(spacing: 18) {
            BigReading(value: weightReading, unit: weightUnit == .kilograms ? "kg" : "lb")
            HStack(spacing: 0) {
                if weightUnit == .kilograms {
                    wheel(selection: $weightKg, range: 30...250, suffix: "")
                    wheel(selection: $weightTenths, range: 0...9, suffix: "", prefix: ".")
                } else {
                    wheel(selection: $weightPounds, range: 66...550, suffix: "")
                }
            }
            .padding(.vertical, 4)
            .onboardingGlass(cornerRadius: 28)
            unitPicker(selection: $weightUnit)
        }
        .onChange(of: weightUnit) { _, unit in convertWeight(to: unit) }
    }

    private var deviceStep: some View {
        let connected = session.healthConnection.status == .connected ? session.healthConnection.activeDevice : nil
        let cards = ForEach(DataSourceDevice.allCases) { option in
            DeviceShowcaseCard(device: option, selected: device == option, connected: connected == option) {
                device = option
                errorMessage = nil
            }
        }
        return VStack(spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { cards }.fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 12) { cards }
            }
            Text("You can change this later in Profile.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    private func wheel(selection: Binding<Int>, range: ClosedRange<Int>, suffix: String, prefix: String = "") -> some View {
        Picker("", selection: selection) {
            ForEach(Array(range), id: \.self) { value in
                Text("\(prefix)\(value)\(suffix.isEmpty ? "" : " \(suffix)")").tag(value)
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }

    private func unitPicker<Unit: Hashable & Identifiable & CaseIterable>(selection: Binding<Unit>) -> some View where Unit.AllCases: RandomAccessCollection, Unit: OnboardingUnit {
        Picker("Unit", selection: selection) {
            ForEach(Unit.allCases) { unit in
                Text(unit.title).tag(unit)
            }
        }
        .pickerStyle(.segmented)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Button {
                Task { await continueTapped() }
            } label: {
                if isSaving {
                    ProgressView().tint(Color(red: 0.08, green: 0.10, blue: 0.24))
                } else {
                    Text(primaryActionTitle)
                }
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .disabled(isSaving || !canContinue || isLoadingProfile)

            if step == .device {
                Button("Not now") {
                    Task { await completeOnboarding() }
                }
                .buttonStyle(OnboardingQuietButtonStyle())
                .disabled(isSaving)
                .accessibilityHint("Finishes setup without a device. Scores stay empty until you connect one.")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var canContinue: Bool {
        switch step {
        case .name:
            return !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .sex:
            return sex != nil
        case .device:
            return device != nil
        case .location, .manualTimezone, .birthday, .height, .weight:
            return true
        }
    }

    private var firstStep: OnboardingStep {
        asksName ? .name : .location
    }

    private var progressSteps: [OnboardingStep] {
        (firstStep == .name ? [.name] : []) + [.location, .birthday, .sex, .height, .weight, .device]
    }

    private var progressPosition: Int {
        (progressSteps.firstIndex(of: step == .manualTimezone ? .location : step) ?? 0) + 1
    }

    private var primaryActionTitle: String {
        guard step == .device, let device else { return step.primaryActionTitle }
        if session.healthConnection.status == .connected && session.healthConnection.activeDevice == device {
            return "Finish"
        }
        return "Connect \(device.shortName)"
    }

    private var skyLevel: Double {
        switch step {
        case .sex: sex?.cardioCoefficient ?? 1.795
        case .height: parsedHeightCm
        case .weight: weightUnit == .kilograms ? Double(weightKg) + Double(weightTenths) / 10 : Double(weightPounds)
        default: 0
        }
    }

    private var heightReading: String {
        heightUnit == .centimeters ? "\(heightCm)" : "\(heightFeet)′ \(heightInches)″"
    }

    private var weightReading: String {
        weightUnit == .kilograms ? "\(weightKg).\(weightTenths)" : "\(weightPounds)"
    }

    private var parsedHeightCm: Double {
        heightUnit == .centimeters ? Double(heightCm) : Double(heightFeet) * 30.48 + Double(heightInches) * 2.54
    }

    private var parsedWeightKg: Double {
        weightUnit == .kilograms ? Double(weightKg) + Double(weightTenths) / 10 : Double(weightPounds) * 0.45359237
    }

    private var dateRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 1900, month: 1, day: 1)) ?? Date.distantPast
        return start...Date()
    }

    private func convertHeight(to unit: HeightUnit) {
        let centimetres = unit == .centimeters
            ? Double(heightFeet) * 30.48 + Double(heightInches) * 2.54
            : Double(heightCm)
        setHeight(centimetres)
    }

    private func convertWeight(to unit: WeightUnit) {
        let kilograms = unit == .kilograms
            ? Double(weightPounds) * 0.45359237
            : Double(weightKg) + Double(weightTenths) / 10
        setWeight(kilograms)
    }

    private func setHeight(_ centimetres: Double) {
        heightCm = min(230, max(120, Int(centimetres.rounded())))
        let totalInches = Int((centimetres / 2.54).rounded())
        heightFeet = min(8, max(3, totalInches / 12))
        heightInches = totalInches % 12
    }

    private func setWeight(_ kilograms: Double) {
        let tenths = Int((kilograms * 10).rounded())
        weightKg = min(250, max(30, tenths / 10))
        weightTenths = tenths % 10
        weightPounds = min(550, max(66, Int((kilograms / 0.45359237).rounded())))
    }

    @MainActor
    private func loadProfileIfNeeded() async {
        guard isLoadingProfile else { return }
        do {
            let loaded: UserProfilePayload = try await authStore.authenticatedRequest(path: "/profile")
            prefill(from: loaded)
        } catch {
            errorMessage = "Your profile couldn’t load. Check your connection and try again."
        }
        isLoadingProfile = false
    }

    @MainActor
    private func continueTapped() async {
        errorMessage = nil
        switch step {
        case .name: await saveNameAndContinue()
        case .location: requestLocation()
        case .manualTimezone: await saveManualTimezone()
        case .birthday: step = .sex
        case .sex: step = .height
        case .height: step = .weight
        case .weight: await saveBodyAndContinue()
        case .device: await connectDeviceAndFinish()
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
        do {
            try await authStore.updateName(firstName: cleanedFirst, lastName: cleanedLast.isEmpty ? nil : cleanedLast)
            step = .location
        } catch {
            errorMessage = "Your name couldn’t save. Try again."
        }
        isSaving = false
    }

    @MainActor
    private func requestLocation() {
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
        guard !isSaving else { return }
        isSaving = true
        do {
            try await updateProfile(ProfileUpdateRequest(
                timezone: TimeZone.current.identifier, dateOfBirth: nil, sex: nil, weatherEnabled: true,
                locationPermissionStatus: "authorized", heightSourcePreference: nil, weightSourcePreference: nil,
                onboardingCompleted: nil
            ))
            locationProvider.requestLocation()
            step = .birthday
        } catch {
            errorMessage = "Your location preference couldn’t save. Try again."
        }
        isSaving = false
    }

    @MainActor
    private func saveManualTimezone() async {
        isSaving = true
        do {
            try await updateProfile(ProfileUpdateRequest(
                timezone: selectedTimezone.identifier, dateOfBirth: nil, sex: nil, weatherEnabled: false,
                locationPermissionStatus: "denied", heightSourcePreference: nil, weightSourcePreference: nil,
                onboardingCompleted: nil
            ))
            step = .birthday
        } catch {
            errorMessage = "Your timezone couldn’t save. Try again."
        }
        isSaving = false
    }

    @MainActor
    private func saveBodyAndContinue() async {
        guard let sex else {
            step = .sex
            return
        }
        isSaving = true
        do {
            let _: BodyMetricsPayload = try await authStore.authenticatedJSON(
                path: "/body-metrics",
                method: "POST",
                body: BodyMetricsUpdateRequest(heightCm: parsedHeightCm, weightKg: parsedWeightKg)
            )
            try await updateProfile(ProfileUpdateRequest(
                timezone: nil, dateOfBirth: Self.apiDateFormatter.string(from: dateOfBirth), sex: sex.backendValue,
                weatherEnabled: nil, locationPermissionStatus: nil, heightSourcePreference: "manual",
                weightSourcePreference: "manual", onboardingCompleted: nil
            ))
            step = .device
        } catch {
            errorMessage = "Your body details couldn’t save. Check your connection and try again."
        }
        isSaving = false
    }

    @MainActor
    private func connectDeviceAndFinish() async {
        guard let device else { return }
        isSaving = true
        let connection = authStore.connectedSession?.healthConnection
        if connection?.status != .connected || connection?.activeDevice != device {
            if let message = await authStore.connect(device) {
                errorMessage = message
                isSaving = false
                return
            }
            guard authStore.connectedSession?.healthConnection.status == .connected,
                  authStore.connectedSession?.healthConnection.activeDevice == device else {
                isSaving = false
                return
            }
        }
        isSaving = false
        await completeOnboarding()
    }

    @MainActor
    private func completeOnboarding() async {
        isSaving = true
        errorMessage = nil
        do {
            try await updateProfile(ProfileUpdateRequest(
                timezone: nil, dateOfBirth: nil, sex: nil, weatherEnabled: nil, locationPermissionStatus: nil,
                heightSourcePreference: nil, weightSourcePreference: nil, onboardingCompleted: true
            ))
            try await authStore.refreshSession()
        } catch {
            errorMessage = "Setup couldn’t finish. Check your connection and try again."
        }
        isSaving = false
    }

    private func updateProfile(_ request: ProfileUpdateRequest) async throws {
        let _: UserProfilePayload = try await authStore.authenticatedJSON(path: "/profile", method: "PATCH", body: request)
    }

    private func prefill(from profile: UserProfilePayload) {
        if let dateString = profile.dateOfBirth, let date = Self.apiDateFormatter.date(from: dateString) {
            dateOfBirth = date
        }
        if let sexValue = profile.sex {
            sex = OnboardingSex(backendValue: sexValue)
        }
        if let height = profile.heightCm { setHeight(height) }
        if let weight = profile.weightKg { setWeight(weight) }
    }

    private static let apiDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private enum OnboardingStep: CaseIterable {
    case name
    case location
    case manualTimezone
    case birthday
    case sex
    case height
    case weight
    case device

    var scene: OnboardingScene {
        switch self {
        case .name: .welcome
        case .location: .location
        case .manualTimezone: .timezone
        case .birthday: .birthday
        case .sex: .sex
        case .height: .height
        case .weight: .weight
        case .device: .device
        }
    }

    var previous: OnboardingStep {
        switch self {
        case .name, .location: .name
        case .manualTimezone, .birthday: .location
        case .sex: .birthday
        case .height: .sex
        case .weight: .height
        case .device: .weight
        }
    }

    var headlineInset: CGFloat {
        switch self {
        case .location: 300
        case .birthday, .sex, .height, .weight: 150
        case .name, .manualTimezone, .device: 16
        }
    }

    var title: String {
        switch self {
        case .name: "What should we call you?"
        case .location: "Make every day line up"
        case .manualTimezone: "Choose your timezone"
        case .birthday: "When were you born?"
        case .sex: "What’s your sex?"
        case .height: "How tall are you?"
        case .weight: "What do you weigh?"
        case .device: "Which device do you wear?"
        }
    }

    var subtitle: String? {
        switch self {
        case .name: nil
        case .location: "Your location keeps sleep and workouts on your local day, and matches the dashboard sky to your weather."
        case .manualTimezone: "Weather stays off without location."
        case .birthday: "Age sets your heart-rate zones."
        case .sex: "Sets how heart-rate effort counts toward Strain."
        case .height: "Saved to your profile."
        case .weight: "The load for bodyweight exercises in Strain."
        case .device: "Scores come from your device. Journal and workouts work without one."
        }
    }

    var primaryActionTitle: String {
        switch self {
        case .location: "Use my location"
        case .device: "Finish"
        default: "Continue"
        }
    }
}

private protocol OnboardingUnit {
    var title: String { get }
}

private struct BigReading: View {
    let value: String
    let unit: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            if let unit {
                Text(unit).font(.title2.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: value)
        .accessibilityElement(children: .combine)
    }
}

private struct GlassTextField: View {
    let title: String
    @Binding var text: String
    let textContentType: UITextContentType
    let submitLabel: SubmitLabel
    var onSubmit: (() -> Void)?

    init(title: String, text: Binding<String>, textContentType: UITextContentType, submitLabel: SubmitLabel, onSubmit: (() -> Void)? = nil) {
        self.title = title
        _text = text
        self.textContentType = textContentType
        self.submitLabel = submitLabel
        self.onSubmit = onSubmit
    }

    var body: some View {
        TextField(title, text: $text)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .textContentType(textContentType)
            .textInputAutocapitalization(.words)
            .submitLabel(submitLabel)
            .onSubmit { onSubmit?() }
            .padding(.horizontal, 20)
            .frame(minHeight: 64)
            .onboardingGlass(cornerRadius: 20)
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

    var cardioCoefficient: Double {
        switch self {
        case .female: 1.67
        case .male: 1.92
        case .other, .preferNotToSay: 1.795
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

private enum HeightUnit: String, CaseIterable, Identifiable, OnboardingUnit {
    case centimeters
    case feetInches

    var id: String { rawValue }
    var title: String { self == .centimeters ? "cm" : "ft/in" }

    static var defaultUnit: HeightUnit {
        Locale.current.region?.identifier == "US" ? .feetInches : .centimeters
    }
}

private enum WeightUnit: String, CaseIterable, Identifiable, OnboardingUnit {
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
