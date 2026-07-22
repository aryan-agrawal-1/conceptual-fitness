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
            List {
                if isLoading && results.isEmpty {
                    ForEach(0..<5, id: \.self) { _ in
                        exercisePlaceholder.redacted(reason: .placeholder)
                    }
                } else if results.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "No exercises available" : "No exercises found",
                        systemImage: "dumbbell",
                        description: Text(errorMessage ?? "Try another name or create a private custom exercise.")
                    )
                } else {
                    if query.isEmpty {
                        let favorites = results.filter(\.isFavorite)
                        if !favorites.isEmpty {
                            Section("Favorites") {
                                ForEach(favorites) { exerciseRow($0) }
                            }
                        }
                    }
                    Section(query.isEmpty ? "Popular exercises" : "Results") {
                        ForEach(results.filter { query.isEmpty ? !$0.isFavorite : true }) { exercise in
                            exerciseRow(exercise)
                        }
                    }
                }
            }
            .listStyle(.plain)
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
                    Button {
                        customExerciseEditor = .create
                    } label: {
                        Label("Custom", systemImage: "plus")
                    }
                }
            }
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
    private func exerciseRow(_ exercise: FitnessExercise) -> some View {
        HStack(spacing: 8) {
            Button {
                select(exercise)
            } label: {
                HStack(spacing: 13) {
                    exerciseImage(exercise)
                    exerciseDetails(exercise)
                    Spacer()
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(HealthTheme.color(for: .activity))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Adds this exercise to the workout")

            if exercise.isCustom {
                Menu {
                    Button {
                        customExerciseEditor = .edit(exercise)
                    } label: {
                        Label("Edit exercise", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 44)
                }
                .accessibilityLabel("Custom exercise actions")
            }
        }
    }

    @ViewBuilder
    private func exerciseImage(_ exercise: FitnessExercise) -> some View {
        if let media = exercise.media.first, let url = URL(string: media.url) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    Image(systemName: "figure.strengthtraining.traditional")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 58, height: 58)
            .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        } else {
            Image(systemName: "figure.strengthtraining.traditional")
                .foregroundStyle(HealthTheme.color(for: .activity))
                .frame(width: 58, height: 58)
                .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func exerciseDetails(_ exercise: FitnessExercise) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(exercise.name)
                    .font(.body.weight(.semibold))
                if exercise.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }
            Text(exerciseSubtitle(exercise))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if exercise.useCount > 0 {
                Text("Used \(exercise.useCount) time\(exercise.useCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(HealthTheme.color(for: .activity))
            }
        }
    }

    private var exercisePlaceholder: some View {
        HStack {
            RoundedRectangle(cornerRadius: 12).frame(width: 58, height: 58)
            VStack(alignment: .leading) {
                Text("Exercise name")
                Text("Equipment · muscle")
            }
        }
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
        let values = [exercise.equipment?.capitalized, exercise.primaryMuscles.first?.displayTitle]
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
