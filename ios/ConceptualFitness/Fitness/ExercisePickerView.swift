import SwiftUI
import UIKit

struct ExercisePickerView: View {
    @Environment(\.dismiss) private var dismiss
    let client: FitnessAPIClient
    let onSelect: (FitnessExercise) -> Void

    @State private var query = ""
    @State private var results: [FitnessExercise] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var customExerciseEditor: CustomExerciseEditor?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if isLoading && results.isEmpty {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(HealthTheme.track)
                                .frame(height: 290)
                                .accessibilityHidden(true)
                        } else if results.isEmpty {
                            ContentUnavailableView(
                                query.isEmpty ? "No exercises available" : "No exercises found",
                                systemImage: "dumbbell",
                                description: Text(errorMessage ?? "Try another name or create a private custom exercise.")
                            )
                        } else {
                            let favorites = query.isEmpty ? results.filter(\.isFavorite) : []
                            if !favorites.isEmpty {
                                section("Favorites", exercises: favorites)
                            }
                            section(
                                query.isEmpty ? "Popular exercises" : "Results",
                                exercises: results.filter { query.isEmpty ? !$0.isFavorite : true }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Exercise, muscle or equipment"
            )
            .task { await search() }
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await search()
            }
            .navigationTitle("Add exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Custom") {
                        customExerciseEditor = .create
                    }
                    .fontWeight(.semibold)
                }
            }
            .tint(HealthTheme.ink)
        }
        .sheet(item: $customExerciseEditor) { editor in
            CustomExerciseSheet(client: client, exercise: editor.exercise) { exercise in
                if editor.exercise == nil {
                    select(exercise)
                } else if let index = results.firstIndex(where: { $0.id == exercise.id }) {
                    results[index] = exercise
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, exercises: [FitnessExercise]) -> some View {
        if !exercises.isEmpty {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(HealthTheme.secondaryInk)
                .padding(.horizontal, 4)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(exercises.enumerated()), id: \.element.id) { index, exercise in
                    if index > 0 {
                        Rectangle()
                            .fill(HealthTheme.hairline)
                            .frame(height: 1)
                            .padding(.leading, 86)
                    }
                    exerciseRow(exercise)
                }
            }
            .panelSurface(cornerRadius: 22)
        }
    }

    private func exerciseRow(_ exercise: FitnessExercise) -> some View {
        HStack(spacing: 0) {
            Button {
                select(exercise)
            } label: {
                HStack(spacing: 12) {
                    exerciseImage(exercise)
                    exerciseDetails(exercise)
                    Spacer(minLength: 4)
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(HealthTheme.ink)
                        .frame(width: 44, height: 44)
                }
                .padding(.leading, 10)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressScale)
            .accessibilityLabel("Add \(exercise.name)")

            if exercise.isCustom {
                Menu {
                    Button {
                        customExerciseEditor = .edit(exercise)
                    } label: {
                        Label("Edit exercise", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(HealthTheme.secondaryInk)
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Custom exercise actions")
            }
        }
        .padding(.trailing, 6)
    }

    private func exerciseImage(_ exercise: FitnessExercise) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return ZStack {
            shape.fill(HealthTheme.track)
            Image(systemName: "dumbbell.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(HealthTheme.secondaryInk)
            if let media = exercise.media.first, let url = URL(string: media.url) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .frame(width: 64, height: 43)
        .clipShape(shape)
    }

    private func exerciseDetails(_ exercise: FitnessExercise) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(exercise.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(HealthTheme.ink)
                    .lineLimit(1)
                if exercise.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(Color(light: 0xB7791F, dark: 0xF2C14E))
                        .accessibilityLabel("Favorite")
                }
            }
            Text(exerciseSummary(exercise))
                .font(.subheadline)
                .foregroundStyle(HealthTheme.secondaryInk)
                .lineLimit(1)
        }
    }

    private func exerciseSummary(_ exercise: FitnessExercise) -> String {
        let base = exerciseSubtitle(exercise)
        guard exercise.useCount > 0 else { return base }
        return "\(base) · \(exercise.useCount) session\(exercise.useCount == 1 ? "" : "s")"
    }

    private func search() async {
        isLoading = true
        defer { isLoading = false }
        do {
            results = try await client.searchExercises(
                query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                includeLongTail: !query.isEmpty
            )
            errorMessage = nil
        } catch {
            errorMessage = "Exercise search is unavailable while offline."
        }
    }

    private func select(_ exercise: FitnessExercise) {
        UISelectionFeedbackGenerator().selectionChanged()
        onSelect(exercise)
        dismiss()
    }

    private func exerciseSubtitle(_ exercise: FitnessExercise) -> String {
        let values = [exercise.primaryMuscles.first?.displayTitle, exercise.equipment?.capitalized]
            .compactMap { $0 }
        return values.isEmpty ? exercise.measurementSchema.displayTitle : values.joined(separator: " · ")
    }
}

private enum CustomExerciseEditor: Identifiable {
    case create
    case edit(FitnessExercise)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let exercise): return exercise.id
        }
    }

    var exercise: FitnessExercise? {
        switch self {
        case .create: return nil
        case .edit(let exercise): return exercise
        }
    }
}

private struct CustomExerciseSheet: View {
    @Environment(\.dismiss) private var dismiss
    let client: FitnessAPIClient
    let exercise: FitnessExercise?
    let onSave: (FitnessExercise) -> Void

    @State private var name: String
    @State private var schema: String
    @State private var equipment: String
    @State private var selectedMuscles: Set<String>
    @State private var isUnilateral: Bool
    @State private var options = FitnessExerciseOptions(equipment: [], muscles: [])
    @State private var isLoadingOptions = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let schemas = [
        ("reps_load", "Reps + weight"),
        ("bodyweight_reps", "Bodyweight reps"),
        ("assisted_reps", "Assisted reps"),
        ("duration", "Time"),
        ("duration_load", "Time + weight"),
        ("carry", "Carry"),
        ("cardio", "Distance + time"),
    ]

    init(
        client: FitnessAPIClient,
        exercise: FitnessExercise?,
        onSave: @escaping (FitnessExercise) -> Void
    ) {
        self.client = client
        self.exercise = exercise
        self.onSave = onSave
        _name = State(initialValue: exercise?.name ?? "")
        _schema = State(initialValue: exercise?.measurementSchema ?? "reps_load")
        _equipment = State(initialValue: exercise?.equipment ?? "")
        _selectedMuscles = State(initialValue: Set(exercise?.primaryMuscles ?? []))
        _isUnilateral = State(initialValue: exercise?.isUnilateral ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Required") {
                    TextField("Exercise name", text: $name)
                    Picker("What do you record?", selection: $schema) {
                        ForEach(schemas, id: \.0) { value, label in
                            Text(label).tag(value)
                        }
                    }
                    if recordsReps {
                        Toggle("Performed per side", isOn: $isUnilateral)
                        if isUnilateral {
                            Text("Enter the reps completed on one side. Each set represents both sides.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Optional") {
                    Picker("Equipment", selection: $equipment) {
                        Text("None").tag("")
                        ForEach(options.equipment, id: \.self) { value in
                            Text(value.displayTitle).tag(value)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    NavigationLink {
                        MuscleSelectionView(
                            muscles: options.muscles,
                            selection: $selectedMuscles
                        )
                    } label: {
                        LabeledContent("Muscles") {
                            Text(muscleSummary)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if isLoadingOptions {
                        Label("Loading exercise options", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(exercise == nil ? "Custom exercise" : "Edit exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(exercise == nil ? "Create" : "Save") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
        }
        .task { await loadOptions() }
    }

    private var recordsReps: Bool {
        ["reps_load", "bodyweight_reps", "assisted_reps"].contains(schema)
    }

    private var muscleSummary: String {
        guard !selectedMuscles.isEmpty else { return "None" }
        if selectedMuscles.count == 1 {
            return selectedMuscles.first?.displayTitle ?? "1 selected"
        }
        return "\(selectedMuscles.count) selected"
    }

    private func loadOptions() async {
        isLoadingOptions = true
        defer { isLoadingOptions = false }
        do {
            options = try await client.loadExerciseOptions()
        } catch {
            errorMessage = "Exercise options are unavailable while offline."
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let saved: FitnessExercise
            if let exercise {
                saved = try await client.updateCustomExercise(
                    exercise: exercise,
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    schema: schema,
                    equipment: equipment.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                    primaryMuscles: selectedMuscles.sorted(),
                    isUnilateral: recordsReps && isUnilateral
                )
            } else {
                saved = try await client.createCustomExercise(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    schema: schema,
                    equipment: equipment.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                    primaryMuscles: selectedMuscles.sorted(),
                    isUnilateral: recordsReps && isUnilateral
                )
            }
            onSave(saved)
            dismiss()
        } catch {
            errorMessage = exercise == nil
                ? "Custom exercises need a connection the first time they’re created."
                : "That custom exercise couldn’t be updated."
        }
    }
}

private struct MuscleSelectionView: View {
    let muscles: [String]
    @Binding var selection: Set<String>

    var body: some View {
        List {
            if muscles.isEmpty {
                ContentUnavailableView(
                    "No muscles available",
                    systemImage: "figure.strengthtraining.traditional",
                    description: Text("Reconnect and try loading the exercise options again.")
                )
            } else {
                ForEach(muscles, id: \.self) { muscle in
                    Button {
                        if selection.contains(muscle) {
                            selection.remove(muscle)
                        } else {
                            selection.insert(muscle)
                        }
                    } label: {
                        HStack {
                            Text(muscle.displayTitle)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selection.contains(muscle) {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(HealthTheme.color(for: .activity))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(muscle.displayTitle), \(selection.contains(muscle) ? "selected" : "not selected")")
                }
            }
        }
        .navigationTitle("Muscles")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension String {
    var nilIfBlank: String? {
        isEmpty ? nil : self
    }
}
