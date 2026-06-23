import Foundation

struct DashboardBundle: Decodable {
    let snapshot: DashboardSnapshot
    let metricSummaries: [String: MetricDashboardSummary]
    let recentWorkouts: [WorkoutSummary]
    let vo2Max: VO2MaxDetail?

    enum CodingKeys: String, CodingKey {
        case snapshot
        case metricSummaries = "metric_summaries"
        case recentWorkouts = "recent_workouts"
        case vo2Max = "vo2_max"
    }
}

struct MetricDashboardSummary: Decodable {
    let current: MetricPoint?
    let dataQuality: String?

    enum CodingKeys: String, CodingKey {
        case current
        case dataQuality = "data_quality"
    }
}

struct DashboardSnapshot: Decodable {
    let userID: String
    let date: String
    let dataQuality: String?
    let metrics: DashboardMetrics?
    let scores: DashboardScores
    let strainTarget: StrainTarget?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case date
        case dataQuality = "data_quality"
        case metrics
        case scores
        case strainTarget = "strain_target"
    }
}

struct DashboardMetrics: Decodable {
    let steps: Int?
    let activeCalories: Double?
    let totalCalories: Double?
    let distanceMeters: Double?
    let restingHeartRate: Double?
    let heartRateVariability: Double?
    let oxygenSaturation: Double?
    let respiratoryRate: Double?
    let sleepMinutes: Int?
    let workoutCount: Int?
    let dataQuality: String?

    enum CodingKeys: String, CodingKey {
        case steps
        case activeCalories = "active_calories"
        case totalCalories = "total_calories"
        case distanceMeters = "distance_meters"
        case restingHeartRate = "resting_heart_rate"
        case heartRateVariability = "heart_rate_variability"
        case oxygenSaturation = "oxygen_saturation"
        case respiratoryRate = "respiratory_rate"
        case sleepMinutes = "sleep_minutes"
        case workoutCount = "workout_count"
        case dataQuality = "data_quality"
    }
}

struct DashboardScores: Decodable {
    let sleep: DailyScore?
    let strain: DailyScore?
    let readiness: DailyScore?
}

struct DailyScore: Decodable {
    let value: Double?
    let unit: String?
    let status: String?
    let confidencePhase: String?
    let dataQuality: String?
    let reasons: [ScoreReason]?

    enum CodingKeys: String, CodingKey {
        case value
        case unit
        case status
        case confidencePhase = "confidence_phase"
        case dataQuality = "data_quality"
        case reasons
    }
}

struct ScoreReason: Decodable {
    let code: String?
    let severity: String?
    let message: String?
    let direction: String?
}

struct StrainTarget: Decodable {
    let targetLoadPoints: Double?
    let progressLoadPoints: Double?
    let progressRatio: Double?
    let loadBand: String?
    let confidencePhase: String?

    enum CodingKeys: String, CodingKey {
        case targetLoadPoints = "target_load_points"
        case progressLoadPoints = "progress_load_points"
        case progressRatio = "progress_ratio"
        case loadBand = "load_band"
        case confidencePhase = "confidence_phase"
    }
}

struct WorkoutSummary: Decodable, Identifiable {
    let id: String
    let workoutType: String?
    let startTime: String?
    let endTime: String?
    let date: String?
    let durationSeconds: Int?
    let distanceMeters: Double?
    let activeCalories: Double?
    let heartRate: HeartRateSummary?
    let intensity: String?

    enum CodingKeys: String, CodingKey {
        case id
        case workoutType = "workout_type"
        case startTime = "start_time"
        case endTime = "end_time"
        case date
        case durationSeconds = "duration_seconds"
        case distanceMeters = "distance_meters"
        case activeCalories = "active_calories"
        case heartRate = "heart_rate"
        case intensity
    }
}

struct HeartRateSummary: Decodable {
    let averageBPM: Double?
    let minBPM: Double?
    let maxBPM: Double?

    enum CodingKeys: String, CodingKey {
        case averageBPM = "average_bpm"
        case minBPM = "min_bpm"
        case maxBPM = "max_bpm"
    }
}

struct VO2MaxDetail: Decodable {
    let current: MetricPoint?
    let dataQuality: String?

    enum CodingKeys: String, CodingKey {
        case current
        case dataQuality = "data_quality"
    }
}

struct MetricPoint: Decodable {
    let value: Double?
    let date: String?
}

struct DashboardData {
    let snapshot: DashboardSnapshot
    let metricSummaries: [String: MetricDashboardSummary]
    let workouts: [WorkoutSummary]
    let vo2Max: VO2MaxDetail?
    let dateContext: DashboardDateContext
    let dailyBrief: String
    let insight: String

    static let sample = preview()

    static func preview(dailyBrief: String? = nil, insight: String? = nil) -> DashboardData {
        DashboardData(
            snapshot: .sample,
            metricSummaries: [:],
            workouts: WorkoutSummary.samples,
            vo2Max: VO2MaxDetail(current: MetricPoint(value: 48.2, date: "2026-06-22"), dataQuality: "strong"),
            dateContext: .today,
            dailyBrief: dailyBrief ?? "Recovery looks strong after 7 hours 48 minutes of sleep last night, with readiness and sleep both in a good range. Use today for a purposeful push if it fits your plan: build strain steadily, warm up properly, and stop short of turning a good recovery day into unnecessary fatigue. Keep the evening calm so the sleep win carries forward.",
            insight: insight ?? "Strong recovery supports a purposeful push today. Build strain steadily."
        )
    }
}

extension DashboardSnapshot {
    static let sample = DashboardSnapshot(
        userID: "preview",
        date: "2026-06-22",
        dataQuality: "strong",
        metrics: DashboardMetrics(
            steps: 8420,
            activeCalories: 525,
            totalCalories: 2310,
            distanceMeters: 6400,
            restingHeartRate: 51,
            heartRateVariability: 68,
            oxygenSaturation: 97,
            respiratoryRate: 14.6,
            sleepMinutes: 468,
            workoutCount: 1,
            dataQuality: "strong"
        ),
        scores: DashboardScores(
            sleep: DailyScore(value: 88, unit: "score_0_100", status: "ready", confidencePhase: "strong", dataQuality: "strong", reasons: nil),
            strain: DailyScore(value: 18, unit: "load_points", status: "ready", confidencePhase: "strong", dataQuality: "strong", reasons: nil),
            readiness: DailyScore(value: 82, unit: "score_0_100", status: "ready", confidencePhase: "strong", dataQuality: "strong", reasons: nil)
        ),
        strainTarget: StrainTarget(
            targetLoadPoints: 21,
            progressLoadPoints: 18,
            progressRatio: 0.86,
            loadBand: "productive",
            confidencePhase: "strong"
        )
    )
}

extension WorkoutSummary {
    static let samples = [
        WorkoutSummary(
            id: "run-1",
            workoutType: "Run",
            startTime: "2026-06-22T06:42:00Z",
            endTime: "2026-06-22T07:22:00Z",
            date: "2026-06-22",
            durationSeconds: 2400,
            distanceMeters: 7200,
            activeCalories: 540,
            heartRate: HeartRateSummary(averageBPM: 151, minBPM: 96, maxBPM: 178),
            intensity: "high"
        ),
        WorkoutSummary(
            id: "ride-1",
            workoutType: "Cycling",
            startTime: "2026-06-20T17:15:00Z",
            endTime: "2026-06-20T18:08:00Z",
            date: "2026-06-20",
            durationSeconds: 3180,
            distanceMeters: 18300,
            activeCalories: 610,
            heartRate: HeartRateSummary(averageBPM: 139, minBPM: 84, maxBPM: 166),
            intensity: "moderate"
        )
    ]
}
