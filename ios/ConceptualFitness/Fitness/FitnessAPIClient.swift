import Foundation

struct FitnessAPIClient {
    let authStore: AuthStore

    func loadOverview() async throws -> FitnessOverview {
        try await request(path: "/fitness/overview", method: "GET")
    }

    func searchExercises(query: String, includeLongTail: Bool = false) async throws -> [FitnessExercise] {
        var components = URLComponents()
        components.path = "/fitness/exercises"
        components.queryItems = [
            URLQueryItem(name: "query", value: query.isEmpty ? nil : query),
            URLQueryItem(name: "include_long_tail", value: includeLongTail ? "true" : "false"),
            URLQueryItem(name: "limit", value: "120"),
        ].filter { $0.value != nil }
        return try await request(path: components.string ?? "/fitness/exercises", method: "GET")
    }

    func loadExerciseOptions() async throws -> FitnessExerciseOptions {
        try await request(path: "/fitness/exercise-options", method: "GET")
    }

    func loadWorkout(id: String) async throws -> FitnessWorkout {
        try await request(path: "/fitness/workouts/\(id)", method: "GET")
    }

    func createCustomExercise(
        name: String,
        schema: String,
        equipment: String?,
        primaryMuscles: [String]
    ) async throws -> FitnessExercise {
        try await request(
            path: "/fitness/exercises",
            method: "POST",
            body: CustomExerciseBody(
                name: name,
                equipment: equipment,
                primaryMuscles: primaryMuscles,
                measurementSchema: schema
            )
        )
    }

    func startRoutine(id: String, clientID: String) async throws -> FitnessWorkout {
        let encoded = clientID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? clientID
        return try await request(
            path: "/fitness/routines/\(id)/start?client_id=\(encoded)",
            method: "POST"
        )
    }

    func createWorkout(_ draft: LocalWorkoutDraft, completed: Bool = false) async throws -> FitnessWorkout {
        let body = FitnessWorkoutCreateBody(draft: draft, completed: completed)
        return try await request(path: "/fitness/workouts", method: "POST", body: body)
    }

    func updateWorkout(_ draft: LocalWorkoutDraft, completed: Bool = false) async throws -> FitnessWorkout {
        guard let serverID = draft.serverID else {
            return try await createWorkout(draft, completed: completed)
        }
        let body = FitnessWorkoutUpdateBody(draft: draft, completed: completed)
        return try await request(path: "/fitness/workouts/\(serverID)", method: "PUT", body: body)
    }

    func deleteWorkout(id: String) async throws {
        guard let url = URL(string: "/fitness/workouts/\(id)", relativeTo: authStore.baseURL)?.absoluteURL else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await authStore.authenticatedData(for: request)
    }

    func updateRoutine(_ routine: FitnessRoutine, from draft: LocalWorkoutDraft) async throws -> FitnessRoutine {
        try await request(
            path: "/fitness/routines/\(routine.id)",
            method: "PUT",
            body: FitnessRoutineWriteBody(routine: routine, draft: draft)
        )
    }

    func workoutMatches(id: String) async throws -> [FitnessWorkoutMatch] {
        try await request(path: "/fitness/workouts/\(id)/matches", method: "GET")
    }

    func mergeWorkouts(targetID: String, candidateID: String) async throws -> FitnessWorkout {
        try await request(
            path: "/fitness/workouts/\(targetID)/merge/\(candidateID)",
            method: "POST"
        )
    }

    func rejectMatch(targetID: String, candidateID: String) async throws {
        guard let url = URL(
            string: "/fitness/workouts/\(targetID)/reject-match/\(candidateID)",
            relativeTo: authStore.baseURL
        )?.absoluteURL else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try await authStore.authenticatedData(for: request)
    }

    func saveRoutine(from workoutID: String, name: String, weekdays: [Int]) async throws -> FitnessRoutine {
        try await request(
            path: "/fitness/workouts/\(workoutID)/save-as-routine",
            method: "POST",
            body: SaveRoutineBody(name: name, scheduledWeekdays: weekdays)
        )
    }

    private func request<Response: Decodable>(path: String, method: String) async throws -> Response {
        try await request(path: path, method: method, body: Optional<EmptyBody>.none)
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body?
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: authStore.baseURL)?.absoluteURL else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data = try await authStore.authenticatedData(for: request)
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

private struct EmptyBody: Encodable {}

private struct CustomExerciseBody: Encodable {
    let name: String
    let aliases: [String] = []
    let instructions: [String] = []
    let equipment: String?
    let category: String = "strength"
    let movementPattern: String? = nil
    let primaryMuscles: [String]
    let secondaryMuscles: [String] = []
    let measurementSchema: String
    let defaultRestSeconds: Int = 90

    enum CodingKeys: String, CodingKey {
        case name, aliases, instructions, equipment, category
        case movementPattern = "movement_pattern"
        case primaryMuscles = "primary_muscles"
        case secondaryMuscles = "secondary_muscles"
        case measurementSchema = "measurement_schema"
        case defaultRestSeconds = "default_rest_seconds"
    }
}

private struct SaveRoutineBody: Encodable {
    let name: String
    let scheduledWeekdays: [Int]

    enum CodingKeys: String, CodingKey {
        case name
        case scheduledWeekdays = "scheduled_weekdays"
    }
}

private struct FitnessRoutineWriteBody: Encodable {
    let name: String
    let notes: String?
    let scheduledWeekdays: [Int]
    let isFavorite: Bool
    let exercises: [FitnessRoutineExerciseBody]

    init(routine: FitnessRoutine, draft: LocalWorkoutDraft) {
        name = routine.name
        notes = routine.notes
        scheduledWeekdays = routine.scheduledWeekdays
        isFavorite = routine.isFavorite
        exercises = draft.exercises.map(FitnessRoutineExerciseBody.init)
    }

    enum CodingKeys: String, CodingKey {
        case name, notes, exercises
        case scheduledWeekdays = "scheduled_weekdays"
        case isFavorite = "is_favorite"
    }
}

private struct FitnessRoutineExerciseBody: Encodable {
    let exerciseID: String?
    let name: String
    let measurementSchema: String
    let groupID: String?
    let targetSets: Int
    let targetRepsMin: Int?
    let targetRepsMax: Int?
    let targetLoadValue: Double?
    let targetLoadUnit: String?
    let targetDurationSeconds: Int?
    let targetDistanceMeters: Double?
    let targetRIR: Double?
    let restSeconds: Int
    let notes: String?

    init(_ exercise: LocalWorkoutExercise) {
        let completed = exercise.sets.filter(\.isCompleted)
        let targetSets = completed.isEmpty ? exercise.sets : completed
        let reps = targetSets.compactMap { Int($0.reps) }
        let last = targetSets.last
        let enteredLoad = last.flatMap { Double($0.load) }
        exerciseID = exercise.catalogID
        name = exercise.name
        measurementSchema = exercise.measurementSchema
        groupID = exercise.groupID
        self.targetSets = max(1, targetSets.count)
        targetRepsMin = reps.min()
        targetRepsMax = reps.max()
        targetLoadValue = exercise.recordsPerImplement ? enteredLoad.map { $0 * 2 } : enteredLoad
        targetLoadUnit = enteredLoad == nil ? nil : "kg"
        targetDurationSeconds = last.flatMap { Int($0.durationSeconds) }
        targetDistanceMeters = last.flatMap { Double($0.distanceMeters) }
        targetRIR = last.flatMap { Double($0.rir) }
        restSeconds = exercise.restSeconds
        notes = exercise.notes.nilIfBlank
    }

    enum CodingKeys: String, CodingKey {
        case name, notes
        case exerciseID = "exercise_id"
        case measurementSchema = "measurement_schema"
        case groupID = "group_id"
        case targetSets = "target_sets"
        case targetRepsMin = "target_reps_min"
        case targetRepsMax = "target_reps_max"
        case targetLoadValue = "target_load_value"
        case targetLoadUnit = "target_load_unit"
        case targetDurationSeconds = "target_duration_seconds"
        case targetDistanceMeters = "target_distance_meters"
        case targetRIR = "target_rir"
        case restSeconds = "rest_seconds"
    }
}

private struct FitnessWorkoutCreateBody: Encodable {
    let clientID: String
    let workoutType = "strength"
    let title: String?
    let startTime: String
    let endTime: String?
    let timezone: String
    let status: String
    let notes: String?
    let sessionRPE: Double?
    let exercises: [FitnessWorkoutExerciseBody]

    init(draft: LocalWorkoutDraft, completed: Bool) {
        clientID = draft.clientID
        title = draft.title?.nilIfBlank
        startTime = FitnessDate.string(draft.startTime)
        endTime = completed ? FitnessDate.string(draft.endTime ?? Date()) : nil
        timezone = TimeZone.current.identifier
        status = completed ? "completed" : "active"
        notes = draft.notes.nilIfBlank
        sessionRPE = Double(draft.sessionRPE)
        exercises = draft.exercises.map(FitnessWorkoutExerciseBody.init)
    }

    enum CodingKeys: String, CodingKey {
        case title, timezone, status, notes, exercises
        case clientID = "client_id"
        case workoutType = "workout_type"
        case startTime = "start_time"
        case endTime = "end_time"
        case sessionRPE = "session_rpe"
    }
}

private struct FitnessWorkoutUpdateBody: Encodable {
    let revision: Int
    let workoutType = "strength"
    let title: String?
    let startTime: String
    let endTime: String?
    let timezone: String
    let status: String
    let notes: String?
    let sessionRPE: Double?
    let exercises: [FitnessWorkoutExerciseBody]

    init(draft: LocalWorkoutDraft, completed: Bool) {
        revision = draft.revision
        title = draft.title?.nilIfBlank
        startTime = FitnessDate.string(draft.startTime)
        endTime = completed ? FitnessDate.string(draft.endTime ?? Date()) : nil
        timezone = TimeZone.current.identifier
        status = completed ? "completed" : "active"
        notes = draft.notes.nilIfBlank
        sessionRPE = Double(draft.sessionRPE)
        exercises = draft.exercises.map(FitnessWorkoutExerciseBody.init)
    }

    enum CodingKeys: String, CodingKey {
        case revision, title, timezone, status, notes, exercises
        case workoutType = "workout_type"
        case startTime = "start_time"
        case endTime = "end_time"
        case sessionRPE = "session_rpe"
    }
}

private struct FitnessWorkoutExerciseBody: Encodable {
    let exerciseID: String?
    let name: String
    let measurementSchema: String
    let groupID: String?
    let primaryMuscles: [String]
    let secondaryMuscles: [String]
    let restSeconds: Int
    let notes: String?
    let sets: [FitnessWorkoutSetBody]

    init(_ exercise: LocalWorkoutExercise) {
        exerciseID = exercise.catalogID
        name = exercise.name
        measurementSchema = exercise.measurementSchema
        groupID = exercise.groupID
        primaryMuscles = exercise.primaryMuscles
        secondaryMuscles = exercise.secondaryMuscles
        restSeconds = exercise.restSeconds
        notes = exercise.notes.nilIfBlank
        sets = exercise.sets.map { FitnessWorkoutSetBody($0, exercise: exercise) }
    }

    enum CodingKeys: String, CodingKey {
        case name, notes, sets
        case exerciseID = "exercise_id"
        case measurementSchema = "measurement_schema"
        case groupID = "group_id"
        case primaryMuscles = "primary_muscles"
        case secondaryMuscles = "secondary_muscles"
        case restSeconds = "rest_seconds"
    }
}

private struct FitnessWorkoutSetBody: Encodable {
    let setType: String
    let status: String
    let reps: Int?
    let loadValue: Double?
    let loadUnit: String?
    let loadPerImplement: Double?
    let implementCount: Int?
    let sideCount: Int?
    let durationSeconds: Int?
    let distanceMeters: Double?
    let assistanceKG: Double?
    let addedLoadKG: Double?
    let rir: Double?
    let completedAt: String?

    init(_ set: LocalWorkoutSet, exercise: LocalWorkoutExercise) {
        let enteredLoad = Double(set.load)
        setType = set.setType
        status = set.isCompleted ? "completed" : "planned"
        reps = Int(set.reps)
        loadUnit = enteredLoad == nil ? nil : "kg"
        durationSeconds = Int(set.durationSeconds)
        distanceMeters = Double(set.distanceMeters)
        rir = Double(set.rir)
        completedAt = set.completedAt.map(FitnessDate.string)

        if exercise.measurementSchema == "assisted_reps" {
            assistanceKG = enteredLoad
            addedLoadKG = nil
            loadValue = nil
            loadPerImplement = nil
            implementCount = nil
        } else if exercise.measurementSchema == "bodyweight_reps" {
            assistanceKG = nil
            addedLoadKG = enteredLoad
            loadPerImplement = nil
            implementCount = nil
            loadValue = nil
        } else if exercise.recordsPerImplement, let enteredLoad {
            assistanceKG = nil
            addedLoadKG = nil
            loadPerImplement = enteredLoad
            implementCount = 2
            loadValue = enteredLoad * 2
        } else {
            assistanceKG = nil
            addedLoadKG = nil
            loadPerImplement = nil
            implementCount = nil
            loadValue = enteredLoad
        }
        sideCount = exercise.name.lowercased().contains("single") ? 2 : nil
    }

    enum CodingKeys: String, CodingKey {
        case status, reps, rir
        case setType = "set_type"
        case loadValue = "load_value"
        case loadUnit = "load_unit"
        case loadPerImplement = "load_per_implement"
        case implementCount = "implement_count"
        case sideCount = "side_count"
        case durationSeconds = "duration_seconds"
        case distanceMeters = "distance_meters"
        case assistanceKG = "assistance_kg"
        case addedLoadKG = "added_load_kg"
        case completedAt = "completed_at"
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
