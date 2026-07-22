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
    @State private var showCustomExercise = false

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
                        showCustomExercise = true
                    } label: {
                        Label("Custom", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showCustomExercise) {
            CustomExerciseSheet(client: client) { exercise in
                select(exercise)
            }
        }
    }

    private func exerciseRow(_ exercise: FitnessExercise) -> some View {
        Button {
            select(exercise)
        } label: {
            HStack(spacing: 13) {
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
                Spacer()
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(HealthTheme.color(for: .activity))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Adds this exercise to the workout")
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

private struct CustomExerciseSheet: View {
    @Environment(\.dismiss) private var dismiss
    let client: FitnessAPIClient
    let onCreate: (FitnessExercise) -> Void

    @State private var name = ""
    @State private var schema = "reps_load"
    @State private var equipment = ""
    @State private var muscles = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let schemas = [
        ("reps_load", "Reps + load"),
        ("bodyweight_reps", "Bodyweight reps"),
        ("assisted_reps", "Assisted reps"),
        ("duration", "Time"),
        ("duration_load", "Time + load"),
        ("carry", "Carry"),
        ("cardio", "Distance + time"),
    ]

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
                }
                Section("Optional") {
                    TextField("Equipment", text: $equipment)
                    TextField("Primary muscles, comma separated", text: $muscles)
                        .textInputAutocapitalization(.never)
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Custom exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
        }
    }

    private func create() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let exercise = try await client.createCustomExercise(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                schema: schema,
                equipment: equipment.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                primaryMuscles: muscles.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }.filter { !$0.isEmpty }
            )
            onCreate(exercise)
            dismiss()
        } catch {
            errorMessage = "Custom exercises need a connection the first time they’re created."
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        isEmpty ? nil : self
    }
}
