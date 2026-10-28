import CoreLocation
import SwiftUI

struct ProfileSaveForm<Content: View>: View {
    let title: String
    let store: ProfileStore
    var validationMessage: String? = nil
    let save: () async throws -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            content().disabled(isSaving)
            if let validationMessage {
                Section { Text(validationMessage).font(.footnote).foregroundStyle(.secondary) }
            }
            if let errorMessage {
                Section {
                    Label("Changes couldn’t be saved", systemImage: "exclamationmark.triangle")
                    Text(errorMessage)
                    Button("Try saving again") { Task { await submit() } }
                        .disabled(isSaving || validationMessage != nil)
                }
            }
            if isSaving { Section { ProgressView("Saving changes…") } }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .navigationBarBackButtonHidden(isSaving)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await submit() } }
                    .disabled(isSaving || validationMessage != nil)
            }
        }
    }

    @MainActor private func submit() async {
        guard !isSaving, validationMessage == nil else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await save()
            dismiss()
        } catch {
            guard !Task.isCancelled else { return }
            store.logFailure("save", error: error)
            errorMessage = "Check your connection and entries, then try again. Your entries are still here. Some changes may already have saved; retrying will keep them."
        }
    }
}

struct ProfileDetailsEditor: View {
    let store: ProfileStore
    let profile: AccountProfile
    let user: AuthUser?
    @State private var firstName: String
    @State private var lastName: String
    @State private var ageEntry: String
    @State private var birthYear: String
    @State private var dateOfBirth: Date
    @State private var sex: String
    @State private var timezone: String

    init(store: ProfileStore, profile: AccountProfile, user: AuthUser?) {
        self.store = store
        self.profile = profile
        self.user = user
        _firstName = State(initialValue: user?.firstName ?? "")
        _lastName = State(initialValue: user?.lastName ?? "")
        _ageEntry = State(initialValue: profile.dateOfBirth != nil ? "date" : profile.birthYear != nil ? "year" : "none")
        _birthYear = State(initialValue: profile.birthYear.map(String.init) ?? "")
        _dateOfBirth = State(initialValue: profile.dateOfBirth.flatMap(Self.dateFormatter.date) ?? Calendar.current.date(byAdding: .year, value: -30, to: Date())!)
        _sex = State(initialValue: profile.sex ?? "")
        _timezone = State(initialValue: profile.timezone)
    }

    var body: some View {
        ProfileSaveForm(title: "Personal details", store: store, validationMessage: validationMessage, save: save) {
            Section("Name") {
                TextField("First name", text: $firstName).textContentType(.givenName)
                TextField("Last name (optional)", text: $lastName).textContentType(.familyName)
                Text(user?.email ?? "Email unavailable").foregroundStyle(.secondary)
                Text("Your email is managed by your Google account.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Body details") {
                Picker("Birth details", selection: $ageEntry) {
                    Text("Not set").tag("none")
                    Text("Date of birth").tag("date")
                    Text("Birth year only").tag("year")
                }
                if ageEntry == "date" {
                    DatePicker("Date of birth", selection: $dateOfBirth, in: Self.dateFormatter.date(from: "1900-01-01")!...Date(), displayedComponents: .date)
                } else if ageEntry == "year" {
                    TextField("Birth year", text: $birthYear).keyboardType(.numberPad)
                }
                Picker("Sex", selection: $sex) {
                    Text("Not set").tag("")
                    Text("Female").tag("female")
                    Text("Male").tag("male")
                    Text("Prefer not to say").tag("not_specified")
                }
                Text("These details help estimates that depend on age and body metrics.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Local days") {
                Picker("Timezone", selection: $timezone) {
                    ForEach(Array(Set(TimeZone.knownTimeZoneIdentifiers + [timezone])).sorted(), id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.navigationLink)
                Text("Sleep, workouts, and daily records use this timezone.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var validationMessage: String? {
        if firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || firstName.count > 80 || lastName.count > 80 {
            return "Enter a first name. Names can contain up to 80 characters."
        }
        if ageEntry == "year", !(1900...Calendar.current.component(.year, from: Date())).contains(Int(birthYear) ?? 0) {
            return "Enter a birth year between 1900 and this year."
        }
        return nil
    }

    @MainActor private func save() async throws {
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        if first != user?.firstName || last != (user?.lastName ?? "") {
            try await store.authStore.updateName(firstName: first, lastName: last.isEmpty ? nil : last)
        }
        try await store.update([
            "date_of_birth": ageEntry == "date" ? .text(Self.dateFormatter.string(from: dateOfBirth)) : .null,
            "birth_year": ageEntry == "year" ? .number(Double(birthYear)!) : .null,
            "sex": .optionalText(sex), "timezone": .text(timezone)
        ])
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct ProfileGoalsEditor: View {
    let store: ProfileStore
    @State private var primary: String
    @State private var secondary: String
    @State private var sleepTarget: Int

    init(store: ProfileStore, profile: AccountProfile) {
        self.store = store
        _primary = State(initialValue: profile.primaryGoal ?? "")
        _secondary = State(initialValue: profile.secondaryGoals.joined(separator: "\n"))
        _sleepTarget = State(initialValue: profile.sleepTargetMinutes)
    }

    var body: some View {
        ProfileSaveForm(title: "Goals and sleep", store: store, validationMessage: validationMessage, save: {
            try await store.update(["primary_goal": .optionalText(primary), "secondary_goals": .list(ProfileInput.lines(secondary)), "sleep_target_minutes": .number(Double(sleepTarget))])
        }) {
            Section("Primary goal") { TextField("What matters most to you?", text: $primary, axis: .vertical).accessibilityLabel("Primary goal") }
            Section {
                TextField("Secondary goals", text: $secondary, axis: .vertical).lineLimit(3...10)
            } header: { Text("Secondary goals") } footer: { Text("Optional. Enter one goal per line, up to 10 goals and 80 characters each. Clear a field to remove it.") }
            Section("Sleep") {
                Stepper("Sleep target: \(sleepTarget / 60)h \(sleepTarget % 60)m", value: $sleepTarget, in: 180...900, step: 15)
            }
        }
    }

    private var validationMessage: String? {
        primary.count > 80 || !ProfileInput.validLines(secondary, count: 10, length: 80)
            ? "Use up to 80 characters per goal and no more than 10 secondary goals." : nil
    }
}

struct ProfileConstraintsEditor: View {
    let store: ProfileStore
    @State private var schedule: String
    @State private var equipment: String
    @State private var injuries: String
    @State private var diet: String
    @State private var sleep: String

    init(store: ProfileStore, profile: AccountProfile) {
        self.store = store
        _schedule = State(initialValue: profile.constraints.schedule.joined(separator: "\n"))
        _equipment = State(initialValue: profile.constraints.equipment.joined(separator: "\n"))
        _injuries = State(initialValue: profile.constraints.injuries.joined(separator: "\n"))
        _diet = State(initialValue: profile.constraints.dietaryPreferences.joined(separator: "\n"))
        _sleep = State(initialValue: profile.constraints.sleepSchedule ?? "")
    }

    var body: some View {
        ProfileSaveForm(title: "Constraints", store: store, validationMessage: validationMessage, save: {
            try await store.update(["constraints": .object([
                "schedule": .list(ProfileInput.lines(schedule)), "equipment": .list(ProfileInput.lines(equipment)),
                "injuries": .list(ProfileInput.lines(injuries)), "dietary_preferences": .list(ProfileInput.lines(diet)),
                "sleep_schedule": .optionalText(sleep)
            ])])
        }) {
            Section { Text("Optional context for your goals. Enter one item per line; clear a field to remove its saved items.").font(.subheadline) }
            constraint("Schedule", text: $schedule, hint: "For example, weekdays after 18:00")
            constraint("Equipment", text: $equipment, hint: "Equipment you have access to")
            constraint("Injuries and limitations", text: $injuries, hint: "Limitations you want taken into account")
            constraint("Dietary preferences", text: $diet, hint: "Food preferences or restrictions")
            Section("Sleep schedule") { TextField("For example, 23:00–07:00", text: $sleep, axis: .vertical).accessibilityLabel("Sleep schedule") }
        }
    }

    private func constraint(_ title: String, text: Binding<String>, hint: String) -> some View {
        Section(title) { TextField(hint, text: text, axis: .vertical).lineLimit(2...8).accessibilityLabel(title) }
    }

    private var validationMessage: String? {
        let valid = ProfileInput.validLines(schedule, count: 20) && ProfileInput.validLines(equipment, count: 50)
            && ProfileInput.validLines(injuries, count: 20) && ProfileInput.validLines(diet, count: 20) && sleep.count <= 160
        return valid ? nil : "Use up to 160 characters per item, 50 equipment items, and 20 items in each other list."
    }
}

struct ProfileUnitsEditor: View {
    let store: ProfileStore
    @State private var units: ProfileUnits
    init(store: ProfileStore, profile: AccountProfile) {
        self.store = store
        _units = State(initialValue: profile.unitSystem)
    }
    var body: some View {
        ProfileSaveForm(title: "Units", store: store, save: { try await store.update(["unit_system": .text(units.rawValue)]) }) {
            Section {
                Picker("Display units", selection: $units) { ForEach(ProfileUnits.allCases) { Text($0.title).tag($0) } }
                Text("Metric uses cm, kg, km, and °C. Imperial uses inches, lb, miles, and °F. Workout entries use the selected units; saved measurements retain their original precision.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
