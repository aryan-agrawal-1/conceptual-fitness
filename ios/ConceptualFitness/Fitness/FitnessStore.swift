import Foundation
import SwiftUI

@MainActor
final class FitnessStore: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var overview: FitnessOverview?
    @Published var draft: LocalWorkoutDraft?
    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var isSyncing = false
    @Published private(set) var syncMessage: String?
    @Published private(set) var matchSuggestions: [FitnessMatchSuggestion] = []

    let client: FitnessAPIClient
    private let persistenceURL: URL?
    private var syncTask: Task<Void, Never>?

    init(authStore: AuthStore, userID: String) {
        client = FitnessAPIClient(authStore: authStore)
        persistenceURL = Self.persistenceURL(userID: userID)
        draft = Self.loadDraft(from: persistenceURL)
    }

    var sourceRoutine: FitnessRoutine? {
        guard let routineID = draft?.routineID else { return nil }
        return overview?.routines.first { $0.id == routineID }
    }

    func load() async {
        guard loadState != .loading else { return }
        loadState = .loading
        do {
            let response = try await client.loadOverview()
            overview = response
            if draft == nil, let active = response.activeWorkout {
                draft = LocalWorkoutDraft(workout: active)
                persist()
            }
            loadState = .loaded
            await loadMatchSuggestions(from: response)
            if draft?.pendingCompletion == true {
                await retryPendingCompletion()
            } else if draft?.serverID == nil {
                scheduleSync()
            }
        } catch {
            loadState = overview == nil ? .failed("Fitness is offline. Your workout draft is still available.") : .loaded
        }
    }

    func refresh() async {
        loadState = .idle
        await load()
    }

    @discardableResult
    func startWorkout(at date: Date = Date(), retrospective: Bool = false) -> Bool {
        guard draft == nil else { return false }
        draft = .empty(startTime: date, retrospective: retrospective)
        persist()
        scheduleSync()
        return true
    }

    func startRoutine(_ routine: FitnessRoutine) async {
        guard draft == nil else { return }
        var local = LocalWorkoutDraft.empty(startTime: Date(), retrospective: false)
        local.routineID = routine.id
        local.title = routine.name
        local.exercises = routine.exercises.map(LocalWorkoutExercise.init)
        draft = local
        persist()
        do {
            let remote = try await client.startRoutine(id: routine.id, clientID: local.clientID)
            var merged = local
            merged.serverID = remote.id
            merged.revision = remote.revision
            if !remote.exercises.isEmpty {
                merged.exercises = remote.exercises.map(LocalWorkoutExercise.init)
            }
            draft = merged
            syncMessage = nil
            persist()
        } catch {
            syncMessage = "Saved offline — it will sync when the backend is available."
        }
    }

    func repeatWorkout(_ workout: FitnessWorkout) async {
        guard draft == nil else { return }
        do {
            let detail = try await client.loadWorkout(id: workout.id)
            var repeated = LocalWorkoutDraft.empty(startTime: Date(), retrospective: false)
            repeated.title = detail.title == "Strength Workout" ? nil : detail.title
            repeated.exercises = detail.exercises.map { exercise in
                var copy = LocalWorkoutExercise(workoutExercise: exercise)
                copy.sets = copy.sets.map { set in
                    var planned = set
                    planned.id = UUID()
                    planned.isCompleted = false
                    planned.completedAt = nil
                    return planned
                }
                return copy
            }
            draft = repeated
            persist()
            scheduleSync()
        } catch {
            syncMessage = "Couldn’t load that workout to repeat."
        }
    }

    func editWorkout(_ workout: FitnessWorkout) async {
        guard draft == nil else { return }
        do {
            let detail = try await client.loadWorkout(id: workout.id)
            draft = LocalWorkoutDraft(workout: detail)
            persist()
        } catch {
            syncMessage = "Couldn’t open that workout for editing."
        }
    }

    func merge(_ suggestion: FitnessMatchSuggestion) async {
        do {
            _ = try await client.mergeWorkouts(
                targetID: suggestion.targetWorkout.id,
                candidateID: suggestion.candidate.workout.id
            )
            await refresh()
        } catch {
            syncMessage = "Those workouts could not be combined."
        }
    }

    func keepSeparate(_ suggestion: FitnessMatchSuggestion) async {
        do {
            try await client.rejectMatch(
                targetID: suggestion.targetWorkout.id,
                candidateID: suggestion.candidate.workout.id
            )
            matchSuggestions.removeAll { $0.id == suggestion.id }
        } catch {
            syncMessage = "The match choice could not be saved."
        }
    }

    func addExercise(_ exercise: FitnessExercise) {
        mutateDraft { draft in
            draft.exercises.append(LocalWorkoutExercise(exercise: exercise))
        }
    }

    func addSet(to exerciseID: UUID) {
        mutateDraft { draft in
            guard let index = draft.exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
            var next = draft.exercises[index].sets.last ?? LocalWorkoutSet()
            next.id = UUID()
            next.isCompleted = false
            next.completedAt = nil
            draft.exercises[index].sets.append(next)
        }
    }

    func removeSet(_ setID: UUID, from exerciseID: UUID) {
        mutateDraft { draft in
            guard let exerciseIndex = draft.exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
            guard draft.exercises[exerciseIndex].sets.count > 1 else { return }
            draft.exercises[exerciseIndex].sets.removeAll { $0.id == setID }
        }
    }

    func removeExercise(_ exerciseID: UUID) {
        mutateDraft { draft in
            draft.exercises.removeAll { $0.id == exerciseID }
        }
    }

    func updateDraft(_ change: (inout LocalWorkoutDraft) -> Void) {
        mutateDraft(change)
    }

    func syncNow() async {
        guard var current = draft,
              !current.pendingCompletion,
              !current.isEditingExistingWorkout else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let remote: FitnessWorkout
            if current.serverID == nil {
                remote = try await client.createWorkout(current, completed: current.isRetrospective)
            } else {
                remote = try await client.updateWorkout(current, completed: current.isRetrospective)
            }
            guard draft?.clientID == current.clientID else { return }
            current = draft ?? current
            current.serverID = remote.id
            current.revision = remote.revision
            draft = current
            syncMessage = nil
            persist()
        } catch {
            syncMessage = "Saved on this device — waiting to sync."
        }
    }

    func finish(
        saveRoutineName: String?,
        weekdays: [Int],
        updateSourceRoutine: Bool = false
    ) async throws {
        guard var current = draft else { return }
        current.endTime = current.endTime ?? Date()
        current.pendingCompletion = true
        draft = current
        persist()
        isSyncing = true
        defer { isSyncing = false }
        do {
            let remote: FitnessWorkout
            if current.serverID == nil {
                remote = try await client.createWorkout(current, completed: true)
            } else {
                remote = try await client.updateWorkout(current, completed: true)
            }
            var secondaryWarning: String?
            if updateSourceRoutine, let routine = sourceRoutine {
                do {
                    _ = try await client.updateRoutine(routine, from: current)
                } catch {
                    secondaryWarning = "Workout saved, but the routine could not be updated."
                }
            }
            if let name = saveRoutineName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                do {
                    _ = try await client.saveRoutine(from: remote.id, name: name, weekdays: weekdays)
                } catch {
                    secondaryWarning = "Workout saved, but the new routine could not be created."
                }
            }
            draft = nil
            persist()
            await refresh()
            syncMessage = secondaryWarning
        } catch {
            syncMessage = "Completion is saved on this device and will retry later."
            throw error
        }
    }

    func discardDraft() async -> Bool {
        syncTask?.cancel()
        let isEditingExistingWorkout = draft?.isEditingExistingWorkout == true
        if !isEditingExistingWorkout, let serverID = draft?.serverID {
            do {
                try await client.deleteWorkout(id: serverID)
            } catch {
                syncMessage = "Couldn’t discard while offline. The draft is still safe on this device."
                return false
            }
        }
        draft = nil
        syncMessage = nil
        persist()
        return true
    }

    private func retryPendingCompletion() async {
        do {
            try await finish(saveRoutineName: nil, weekdays: [])
        } catch {
            return
        }
    }

    private func loadMatchSuggestions(from overview: FitnessOverview) async {
        var suggestions: [FitnessMatchSuggestion] = []
        for workout in overview.recentWorkouts.prefix(8) {
            guard let matches = try? await client.workoutMatches(id: workout.id) else { continue }
            suggestions.append(contentsOf: matches.compactMap { match in
                guard match.confidence == "medium" else { return nil }
                return FitnessMatchSuggestion(targetWorkout: workout, candidate: match)
            })
        }
        var seen: Set<String> = []
        matchSuggestions = suggestions.filter { seen.insert($0.id).inserted }
    }

    private func mutateDraft(_ change: (inout LocalWorkoutDraft) -> Void) {
        guard var value = draft else { return }
        change(&value)
        draft = value
        persist()
        if !value.isEditingExistingWorkout {
            scheduleSync()
        }
    }

    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    private func persist() {
        guard let persistenceURL else { return }
        if let draft {
            guard let data = try? JSONEncoder().encode(draft) else { return }
            try? data.write(to: persistenceURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: persistenceURL)
        }
    }

    private static func persistenceURL(userID: String) -> URL? {
        guard let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let fitnessDirectory = directory.appending(path: "FitnessDrafts", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: fitnessDirectory, withIntermediateDirectories: true)
        return fitnessDirectory.appending(path: "\(userID).json")
    }

    private static func loadDraft(from url: URL?) -> LocalWorkoutDraft? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LocalWorkoutDraft.self, from: data)
    }
}
