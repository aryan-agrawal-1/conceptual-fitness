import Foundation

struct FitnessOverview: Decodable {
    let activeWorkout: FitnessWorkout?
    let dueRoutines: [FitnessRoutine]
    let routines: [FitnessRoutine]
    let recentWorkouts: [FitnessWorkout]

    enum CodingKeys: String, CodingKey {
        case activeWorkout = "active_workout"
        case dueRoutines = "due_routines"
        case routines
        case recentWorkouts = "recent_workouts"
    }
}

struct FitnessWorkoutMatch: Decodable, Hashable {
    let confidence: String
    let score: Double
    let workout: FitnessWorkout
}

struct FitnessMatchSuggestion: Identifiable, Hashable {
    var id: String { [targetWorkout.id, candidate.workout.id].sorted().joined(separator: "-") }
    let targetWorkout: FitnessWorkout
    let candidate: FitnessWorkoutMatch
}

struct FitnessExerciseMedia: Codable, Hashable {
    let role: String
    let type: String
    let url: String
    let source: String?
}

struct FitnessExercise: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let aliases: [String]
    let instructions: [String]
    let media: [FitnessExerciseMedia]
    let equipment: String?
    let category: String?
    let movementPattern: String?
    let primaryMuscles: [String]
    let secondaryMuscles: [String]
    let measurementSchema: String
    let isUnilateral: Bool
    let defaultRestSeconds: Int?
    let isCurated: Bool
    let isCustom: Bool
    let isFavorite: Bool
    let useCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name, aliases, instructions, media, equipment, category
        case movementPattern = "movement_pattern"
        case primaryMuscles = "primary_muscles"
        case secondaryMuscles = "secondary_muscles"
        case measurementSchema = "measurement_schema"
        case isUnilateral = "is_unilateral"
        case defaultRestSeconds = "default_rest_seconds"
        case isCurated = "is_curated"
        case isCustom = "is_custom"
        case isFavorite = "is_favorite"
        case useCount = "use_count"
    }
}

struct FitnessExerciseOptions: Decodable {
    let equipment: [String]
    let muscles: [String]
}

struct FitnessRoutine: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let notes: String?
    let scheduledWeekdays: [Int]
    let isFavorite: Bool
    let lastPerformedAt: String?
    let exercises: [FitnessRoutineExercise]

    enum CodingKeys: String, CodingKey {
        case id, name, notes, exercises
        case scheduledWeekdays = "scheduled_weekdays"
        case isFavorite = "is_favorite"
        case lastPerformedAt = "last_performed_at"
    }
}

struct FitnessRoutineExercise: Codable, Identifiable, Hashable {
    let id: String
    let exerciseID: String?
    let name: String
    let measurementSchema: String
    let isUnilateral: Bool
    let groupID: String?
    let targetSets: Int?
    let targetRepsMin: Int?
    let targetRepsMax: Int?
    let targetLoadValue: Double?
    let targetLoadUnit: String?
    let targetDurationSeconds: Int?
    let targetDistanceMeters: Double?
    let targetRIR: Double?
    let restSeconds: Int?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case id, name, notes
        case exerciseID = "exercise_id"
        case measurementSchema = "measurement_schema"
        case isUnilateral = "is_unilateral"
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

struct FitnessWorkout: Codable, Identifiable, Hashable {
    let id: String
    let clientID: String?
    let routineID: String?
    let title: String
    let workoutType: String
    let status: String
    let origin: String
    let startTime: String
    let endTime: String?
    let date: String
    let durationSeconds: Int
    let timezone: String
    let notes: String?
    let sessionRPE: Double?
    let revision: Int
    let awaitingWearable: Bool
    let completedAt: String?
    let summary: FitnessWorkoutSummary
    let musclesTrained: [FitnessMuscleLoad]
    let sources: [FitnessWorkoutSource]
    let exercises: [FitnessWorkoutExercise]

    enum CodingKeys: String, CodingKey {
        case id, title, status, origin, date, timezone, notes, revision, summary, sources, exercises
        case clientID = "client_id"
        case routineID = "routine_id"
        case workoutType = "workout_type"
        case startTime = "start_time"
        case endTime = "end_time"
        case durationSeconds = "duration_seconds"
        case sessionRPE = "session_rpe"
        case awaitingWearable = "awaiting_wearable"
        case completedAt = "completed_at"
        case musclesTrained = "muscles_trained"
    }
}

struct FitnessWorkoutSummary: Codable, Hashable {
    let exerciseCount: Int
    let completedSetCount: Int
    let volumeKG: Double

    enum CodingKeys: String, CodingKey {
        case exerciseCount = "exercise_count"
        case completedSetCount = "completed_set_count"
        case volumeKG = "volume_kg"
    }
}

struct FitnessMuscleLoad: Codable, Hashable {
    let muscle: String
    let setEquivalents: Double

    enum CodingKeys: String, CodingKey {
        case muscle
        case setEquivalents = "set_equivalents"
    }
}

struct FitnessWorkoutSource: Codable, Hashable {
    let id: String
    let provider: String
    let sourcePlatform: String?
    let sourceDevice: String?

    enum CodingKeys: String, CodingKey {
        case id, provider
        case sourcePlatform = "source_platform"
        case sourceDevice = "source_device"
    }
}

struct FitnessWorkoutExercise: Codable, Identifiable, Hashable {
    let id: String
    let exerciseID: String?
    let name: String
    let measurementSchema: String
    let groupID: String?
    let primaryMuscles: [String]
    let secondaryMuscles: [String]
    let restSeconds: Int?
    let notes: String?
    let sets: [FitnessWorkoutSet]

    enum CodingKeys: String, CodingKey {
        case id, name, notes, sets
        case exerciseID = "exercise_id"
        case measurementSchema = "measurement_schema"
        case groupID = "group_id"
        case primaryMuscles = "primary_muscles"
        case secondaryMuscles = "secondary_muscles"
        case restSeconds = "rest_seconds"
    }
}

struct FitnessWorkoutSet: Codable, Identifiable, Hashable {
    let id: String
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
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case id, status, reps, rir, notes
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
    }
}

struct LocalWorkoutDraft: Codable, Identifiable, Equatable {
    var id: String { clientID }
    var clientID: String
    var serverID: String?
    var routineID: String?
    var revision: Int
    var title: String?
    var startTime: Date
    var endTime: Date?
    var isRetrospective: Bool
    var notes: String
    var sessionRPE: String
    var exercises: [LocalWorkoutExercise]
    var pendingCompletion: Bool
    var editingOriginalRevision: Int?

    var isEditingExistingWorkout: Bool {
        editingOriginalRevision != nil
    }

    init(
        clientID: String,
        serverID: String?,
        routineID: String?,
        revision: Int,
        title: String?,
        startTime: Date,
        endTime: Date?,
        isRetrospective: Bool,
        notes: String,
        sessionRPE: String,
        exercises: [LocalWorkoutExercise],
        pendingCompletion: Bool,
        editingOriginalRevision: Int? = nil
    ) {
        self.clientID = clientID
        self.serverID = serverID
        self.routineID = routineID
        self.revision = revision
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.isRetrospective = isRetrospective
        self.notes = notes
        self.sessionRPE = sessionRPE
        self.exercises = exercises
        self.pendingCompletion = pendingCompletion
        self.editingOriginalRevision = editingOriginalRevision
    }

    static func empty(startTime: Date, retrospective: Bool) -> LocalWorkoutDraft {
        LocalWorkoutDraft(
            clientID: UUID().uuidString.lowercased(),
            serverID: nil,
            routineID: nil,
            revision: 1,
            title: nil,
            startTime: startTime,
            endTime: retrospective ? startTime.addingTimeInterval(60 * 60) : nil,
            isRetrospective: retrospective,
            notes: "",
            sessionRPE: "",
            exercises: [],
            pendingCompletion: false,
            editingOriginalRevision: nil
        )
    }

    init(workout: FitnessWorkout) {
        clientID = workout.clientID ?? UUID().uuidString.lowercased()
        serverID = workout.id
        routineID = workout.routineID
        revision = workout.revision
        title = workout.title == "Strength Workout" ? nil : workout.title
        startTime = FitnessDate.parse(workout.startTime) ?? Date()
        endTime = workout.status == "completed" ? FitnessDate.parse(workout.endTime) : nil
        isRetrospective = workout.status == "completed"
        notes = workout.notes ?? ""
        sessionRPE = workout.sessionRPE.map(FitnessNumber.string) ?? ""
        exercises = workout.exercises.map(LocalWorkoutExercise.init)
        pendingCompletion = false
        editingOriginalRevision = workout.status == "completed" ? workout.revision : nil
    }
}

struct LocalWorkoutExercise: Codable, Identifiable, Equatable {
    var id: UUID
    var catalogID: String?
    var name: String
    var measurementSchema: String
    var isUnilateral: Bool?
    var equipment: String?
    var groupID: String?
    var primaryMuscles: [String]
    var secondaryMuscles: [String]
    var restSeconds: Int
    var notes: String
    var media: [FitnessExerciseMedia]
    var instructions: [String]
    var sets: [LocalWorkoutSet]

    init(exercise: FitnessExercise) {
        id = UUID()
        catalogID = exercise.id
        name = exercise.name
        measurementSchema = exercise.measurementSchema
        isUnilateral = exercise.isUnilateral
        equipment = exercise.equipment
        groupID = nil
        primaryMuscles = exercise.primaryMuscles
        secondaryMuscles = exercise.secondaryMuscles
        restSeconds = exercise.defaultRestSeconds ?? 90
        notes = ""
        media = exercise.media
        instructions = exercise.instructions
        sets = [LocalWorkoutSet()]
    }

    init(routineExercise: FitnessRoutineExercise) {
        id = UUID()
        catalogID = routineExercise.exerciseID
        name = routineExercise.name
        measurementSchema = routineExercise.measurementSchema
        isUnilateral = routineExercise.isUnilateral
        equipment = nil
        groupID = routineExercise.groupID
        primaryMuscles = []
        secondaryMuscles = []
        restSeconds = routineExercise.restSeconds ?? 90
        notes = routineExercise.notes ?? ""
        media = []
        instructions = []
        let count = max(1, routineExercise.targetSets ?? 1)
        sets = (0..<count).map { _ in
            LocalWorkoutSet(
                reps: routineExercise.targetRepsMin.map(String.init) ?? "",
                load: routineExercise.targetLoadValue.map(FitnessNumber.string) ?? "",
                durationSeconds: routineExercise.targetDurationSeconds.map(String.init) ?? "",
                distanceMeters: routineExercise.targetDistanceMeters.map(FitnessNumber.string) ?? "",
                rir: routineExercise.targetRIR.map(FitnessNumber.string) ?? ""
            )
        }
    }

    init(workoutExercise: FitnessWorkoutExercise) {
        id = UUID()
        catalogID = workoutExercise.exerciseID
        name = workoutExercise.name
        measurementSchema = workoutExercise.measurementSchema
        isUnilateral = workoutExercise.sets.contains { $0.sideCount == 2 }
        equipment = nil
        groupID = workoutExercise.groupID
        primaryMuscles = workoutExercise.primaryMuscles
        secondaryMuscles = workoutExercise.secondaryMuscles
        restSeconds = workoutExercise.restSeconds ?? 90
        notes = workoutExercise.notes ?? ""
        media = []
        instructions = []
        sets = workoutExercise.sets.map { LocalWorkoutSet(remote: $0) }
    }

    var recordsPerImplement: Bool {
        let value = equipment?.lowercased() ?? ""
        return value.contains("dumbbell") || value.contains("kettlebell")
    }

    var recordsPerSide: Bool {
        isUnilateral == true
    }
}

struct LocalWorkoutSet: Codable, Identifiable, Equatable {
    var id = UUID()
    var setType = "working"
    var reps = ""
    var load = ""
    var durationSeconds = ""
    var distanceMeters = ""
    var rir = ""
    var isCompleted = false
    var completedAt: Date?

    init(
        reps: String = "",
        load: String = "",
        durationSeconds: String = "",
        distanceMeters: String = "",
        rir: String = ""
    ) {
        self.reps = reps
        self.load = load
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.rir = rir
    }

    init(remote: FitnessWorkoutSet) {
        id = UUID()
        setType = remote.setType
        reps = remote.reps.map(String.init) ?? ""
        load = (remote.loadPerImplement ?? remote.assistanceKG ?? remote.loadValue)
            .map(FitnessNumber.string) ?? ""
        durationSeconds = remote.durationSeconds.map(String.init) ?? ""
        distanceMeters = remote.distanceMeters.map(FitnessNumber.string) ?? ""
        rir = remote.rir.map(FitnessNumber.string) ?? ""
        isCompleted = remote.status == "completed"
        completedAt = nil
    }
}

enum FitnessDate {
    static func string(_ date: Date) -> String {
        formatter.string(from: date)
    }

    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        return formatter.date(from: value) ?? fractionalFormatter.date(from: value)
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

enum FitnessNumber {
    static func string(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
