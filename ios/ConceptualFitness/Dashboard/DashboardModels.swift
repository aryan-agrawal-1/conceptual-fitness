import Foundation

struct DashboardBundle: Decodable {
    let snapshot: DashboardSnapshot
    let metricSummaries: [String: MetricDashboardSummary]
    let recentWorkouts: [WorkoutSummary]
    let vo2Max: VO2MaxDetail?
    let connections: DashboardConnections?
    let syncStatus: [DashboardSyncStatus]

    enum CodingKeys: String, CodingKey {
        case snapshot
        case metricSummaries = "metric_summaries"
        case recentWorkouts = "recent_workouts"
        case vo2Max = "vo2_max"
        case connections
        case syncStatus = "sync_status"
    }
}

struct DashboardConnections: Decodable {
    let googleHealth: [GoogleHealthConnection]

    enum CodingKeys: String, CodingKey {
        case googleHealth = "google_health"
    }
}

struct GoogleHealthConnection: Decodable {
    let accountID: String?
    let status: String?
    let lastSyncAt: String?

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case status
        case lastSyncAt = "last_sync_at"
    }
}

struct DashboardSyncStatus: Decodable {
    let googleAccountID: String?
    let dataType: String?
    let status: String
    let lastError: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case googleAccountID = "google_account_id"
        case dataType = "data_type"
        case status
        case lastError = "last_error"
        case updatedAt = "updated_at"
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
    let components: [String: JSONValue]?
    let inputs: [String: JSONValue]?
    let reasons: [ScoreReason]?

    enum CodingKeys: String, CodingKey {
        case value
        case unit
        case status
        case confidencePhase = "confidence_phase"
        case dataQuality = "data_quality"
        case components
        case inputs
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
    let chronicLoadPoints: Double?
    let acuteLoadPoints: Double?
    let progressLoadPoints: Double?
    let progressRatio: Double?
    let loadBand: String?
    let confidencePhase: String?
    let components: [String: JSONValue]?
    let inputs: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case targetLoadPoints = "target_load_points"
        case chronicLoadPoints = "chronic_load_points"
        case acuteLoadPoints = "acute_load_points"
        case progressLoadPoints = "progress_load_points"
        case progressRatio = "progress_ratio"
        case loadBand = "load_band"
        case confidencePhase = "confidence_phase"
        case components
        case inputs
    }
}

enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
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
    let strainLoadPoints: Double?

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
        case strainLoadPoints = "strain_load_points"
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

struct StrainDetail: Decodable {
    let timeframe: String
    let start: String
    let end: String
    let summary: StrainSummary
    let chart: StrainChart
    let components: StrainComponents
    let trainingContext: StrainTrainingContext
    let guidance: StrainGuidance
    let contributors: [WorkoutSummary]
    let dataQuality: StrainDataQuality

    enum CodingKeys: String, CodingKey {
        case timeframe
        case start
        case end
        case summary
        case chart
        case components
        case trainingContext = "training_context"
        case guidance
        case contributors
        case dataQuality = "data_quality"
    }
}

struct StrainSummary: Decodable {
    let title: String?
    let primaryValue: Double?
    let loadPoints: Double?
    let targetLoadPoints: Double?
    let progressRatio: Double?
    let loadBand: String?
    let validDays: Int?
    let status: String?
    let dataQuality: String?
    let progressLoadPoints: Double?
    let chronicLoadPoints: Double?
    let acuteLoadPoints: Double?
    let averageWeeklyLoad: Double?
    let weekCount: Int?
    let periodDays: Int?

    enum CodingKeys: String, CodingKey {
        case title
        case primaryValue = "primary_value"
        case loadPoints = "load_points"
        case targetLoadPoints = "target_load_points"
        case progressRatio = "progress_ratio"
        case loadBand = "load_band"
        case validDays = "valid_days"
        case status
        case dataQuality = "data_quality"
        case progressLoadPoints = "progress_load_points"
        case chronicLoadPoints = "chronic_load_points"
        case acuteLoadPoints = "acute_load_points"
        case averageWeeklyLoad = "average_weekly_load"
        case weekCount = "week_count"
        case periodDays = "period_days"
    }
}

struct StrainChart: Decodable {
    let kind: String
    let targetLoadPoints: Double?
    let progressRatio: Double?
    let points: [StrainChartPoint]

    enum CodingKeys: String, CodingKey {
        case kind
        case targetLoadPoints = "target_load_points"
        case progressRatio = "progress_ratio"
        case points
    }
}

struct StrainChartPoint: Decodable, Identifiable {
    let date: String?
    let weekStartDate: String?
    let monthStartDate: String?
    let loadPoints: Double?
    let targetLoadPoints: Double?
    let progressRatio: Double?
    let loadBand: String?
    let status: String?
    let components: [String: Double]?
    let averageWeeklyLoad: Double?
    let totalLoadPoints: Double?

    enum CodingKeys: String, CodingKey {
        case date
        case weekStartDate = "week_start_date"
        case monthStartDate = "month_start_date"
        case loadPoints = "load_points"
        case targetLoadPoints = "target_load_points"
        case progressRatio = "progress_ratio"
        case loadBand = "load_band"
        case status
        case components
        case averageWeeklyLoad = "average_weekly_load"
        case totalLoadPoints = "total_load_points"
    }

    var id: String {
        date ?? weekStartDate ?? monthStartDate ?? "\(loadPoints ?? -1)-\(averageWeeklyLoad ?? -1)"
    }
}

struct StrainComponents: Decodable {
    let items: [StrainComponentItem]
    let totalLoadPoints: Double?

    enum CodingKeys: String, CodingKey {
        case items
        case totalLoadPoints = "total_load_points"
    }
}

struct StrainComponentItem: Decodable, Identifiable {
    let key: String
    let label: String
    let loadPoints: Double
    let share: Double?

    enum CodingKeys: String, CodingKey {
        case key
        case label
        case loadPoints = "load_points"
        case share
    }

    var id: String { key }
}

struct StrainTrainingContext: Decodable {
    let timeframe: String?
    let totalLoadPoints: Double?
    let averageDailyLoad: Double?
    let latestTargetLoadPoints: Double?
    let latestChronicLoadPoints: Double?
    let latestLoadBand: String?
    let targetBandCounts: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case timeframe
        case totalLoadPoints = "total_load_points"
        case averageDailyLoad = "average_daily_load"
        case latestTargetLoadPoints = "latest_target_load_points"
        case latestChronicLoadPoints = "latest_chronic_load_points"
        case latestLoadBand = "latest_load_band"
        case targetBandCounts = "target_band_counts"
    }
}

struct StrainGuidance: Decodable {
    let message: String?
}

struct StrainDataQuality: Decodable {
    let expectedDays: Int?
    let scoredDays: Int?
    let completeness: Double?
    let qualityCounts: [String: Int]?
    let confidenceCounts: [String: Int]?
    let heartRateCoveredMinutes: Double?
    let longGapCount: Int?

    enum CodingKeys: String, CodingKey {
        case expectedDays = "expected_days"
        case scoredDays = "scored_days"
        case completeness
        case qualityCounts = "quality_counts"
        case confidenceCounts = "confidence_counts"
        case heartRateCoveredMinutes = "heart_rate_covered_minutes"
        case longGapCount = "long_gap_count"
    }
}

struct ReadinessDetail: Decodable {
    let timeframe: String
    let start: String
    let end: String
    let summary: ReadinessSummary
    let chart: ReadinessChart
    let components: ReadinessComponents
    let context: ReadinessContext
    let guidance: StrainGuidance
    let reasons: [ScoreReason]
    let dataQuality: ReadinessDataQuality

    enum CodingKeys: String, CodingKey {
        case timeframe
        case start
        case end
        case summary
        case chart
        case components
        case context
        case guidance
        case reasons
        case dataQuality = "data_quality"
    }
}

struct ReadinessSummary: Decodable {
    let title: String?
    let primaryValue: Double?
    let averageScore: Double?
    let latestScore: Double?
    let status: String?
    let readinessBand: String?
    let trend: String?
    let validDays: Int?
    let periodDays: Int?
    let lowDays: Int?
    let highDays: Int?
    let dataQuality: String?

    enum CodingKeys: String, CodingKey {
        case title
        case primaryValue = "primary_value"
        case averageScore = "average_score"
        case latestScore = "latest_score"
        case status
        case readinessBand = "readiness_band"
        case trend
        case validDays = "valid_days"
        case periodDays = "period_days"
        case lowDays = "low_days"
        case highDays = "high_days"
        case dataQuality = "data_quality"
    }
}

struct ReadinessChart: Decodable {
    let kind: String
    let points: [ReadinessChartPoint]
}

struct ReadinessChartPoint: Decodable, Identifiable {
    let date: String?
    let monthStartDate: String?
    let score: Double?
    let averageScore: Double?
    let lowDays: Int?
    let highDays: Int?
    let scoredDays: Int?
    let status: String?
    let readinessBand: String?
    let dataQuality: String?
    let key: String?
    let label: String?
    let weight: Double?
    let message: String?
    let detail: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case date
        case monthStartDate = "month_start_date"
        case score
        case averageScore = "average_score"
        case lowDays = "low_days"
        case highDays = "high_days"
        case scoredDays = "scored_days"
        case status
        case readinessBand = "readiness_band"
        case dataQuality = "data_quality"
        case key
        case label
        case weight
        case message
        case detail
    }

    var id: String {
        date ?? monthStartDate ?? key ?? "\(score ?? -1)-\(averageScore ?? -1)"
    }
}

struct ReadinessComponents: Decodable {
    let items: [ReadinessComponentItem]
    let averageItems: [ReadinessComponentItem]

    enum CodingKeys: String, CodingKey {
        case items
        case averageItems = "average_items"
    }
}

struct ReadinessComponentItem: Decodable, Identifiable {
    let key: String
    let label: String
    let score: Double
    let weight: Double?
    let message: String?
    let detail: [String: JSONValue]?

    var id: String { key }
}

struct ReadinessContext: Decodable {
    let sleepDebtMinutes: Double?
    let sleepDebtMinutes7d: Double?
    let sleepDebtPeriodDays: Int?
    let hrvScore: Double?
    let hrvBaselineRelation: String?
    let rhrScore: Double?
    let rhrBaselineRelation: String?
    let loadRatio: Double?
    let yesterdayLoad: Double?
    let validStrainDays: Int?
    let anomalies: [String]
    let readinessCap: Double?
    let confidencePhase: String?
    let dataQuality: String?

    enum CodingKeys: String, CodingKey {
        case sleepDebtMinutes = "sleep_debt_minutes"
        case sleepDebtMinutes7d = "sleep_debt_minutes_7d"
        case sleepDebtPeriodDays = "sleep_debt_period_days"
        case hrvScore = "hrv_score"
        case hrvBaselineRelation = "hrv_baseline_relation"
        case rhrScore = "rhr_score"
        case rhrBaselineRelation = "rhr_baseline_relation"
        case loadRatio = "load_ratio"
        case yesterdayLoad = "yesterday_load"
        case validStrainDays = "valid_strain_days"
        case anomalies
        case readinessCap = "readiness_cap"
        case confidencePhase = "confidence_phase"
        case dataQuality = "data_quality"
    }

    var sleepDebtValue: Double? {
        sleepDebtMinutes ?? sleepDebtMinutes7d
    }
}

struct ReadinessDataQuality: Decodable {
    let expectedDays: Int?
    let scoredDays: Int?
    let completeness: Double?
    let qualityCounts: [String: Int]?
    let confidenceCounts: [String: Int]?
    let statusCounts: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case expectedDays = "expected_days"
        case scoredDays = "scored_days"
        case completeness
        case qualityCounts = "quality_counts"
        case confidenceCounts = "confidence_counts"
        case statusCounts = "status_counts"
    }
}

struct DashboardData {
    let snapshot: DashboardSnapshot
    let metricSummaries: [String: MetricDashboardSummary]
    let workouts: [WorkoutSummary]
    let vo2Max: VO2MaxDetail?
    let connections: DashboardConnections?
    let syncStatus: [DashboardSyncStatus]
    let dateContext: DashboardDateContext
    let dailyBrief: String?
    let insight: String?
    let aiDebugStatus: String?

    static let sample = preview()

    static func preview(
        dailyBrief: String? = Self.previewDailyBrief,
        insight: String? = Self.previewShortInsight,
        dateContext: DashboardDateContext = .today
    ) -> DashboardData {
        DashboardData(
            snapshot: .sample,
            metricSummaries: [:],
            workouts: WorkoutSummary.samples,
            vo2Max: VO2MaxDetail(current: MetricPoint(value: 48.2, date: "2026-06-22"), dataQuality: "strong"),
            connections: DashboardConnections(googleHealth: [
                GoogleHealthConnection(accountID: "preview", status: "connected", lastSyncAt: "2026-06-22T18:42:00Z")
            ]),
            syncStatus: [],
            dateContext: dateContext,
            dailyBrief: dailyBrief,
            insight: insight,
            aiDebugStatus: nil
        )
    }

    static func previewWithoutInsights(dateContext: DashboardDateContext = .today) -> DashboardData {
        preview(dailyBrief: nil, insight: nil, dateContext: dateContext)
    }

    private static let previewDailyBrief = "Recovery looks strong after 7 hours 48 minutes of sleep last night, with readiness and sleep both in a good range. Use today for a purposeful push if it fits your plan: build strain steadily, warm up properly, and stop short of turning a good recovery day into unnecessary fatigue. Keep the evening calm so the sleep win carries forward."
    private static let previewShortInsight = "Strong recovery supports a purposeful push today. Build strain steadily."
}

extension DashboardData {
    var lastSyncAt: Date? {
        connections?.googleHealth
            .compactMap { DashboardFormatters.parseBackendDateTime($0.lastSyncAt) }
            .max()
    }

    var hasRunningSyncStatus: Bool {
        syncStatus.contains { $0.status == "running" }
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
            sleep: DailyScore(value: 88, unit: "score_0_100", status: "ready", confidencePhase: "strong", dataQuality: "strong", components: nil, inputs: nil, reasons: nil),
            strain: DailyScore(value: 18, unit: "load_points", status: "ready", confidencePhase: "strong", dataQuality: "strong", components: nil, inputs: nil, reasons: nil),
            readiness: DailyScore(value: 82, unit: "score_0_100", status: "ready", confidencePhase: "strong", dataQuality: "strong", components: nil, inputs: nil, reasons: nil)
        ),
        strainTarget: StrainTarget(
            targetLoadPoints: 21,
            chronicLoadPoints: 21,
            acuteLoadPoints: 18,
            progressLoadPoints: 18,
            progressRatio: 0.86,
            loadBand: "productive",
            confidencePhase: "strong",
            components: nil,
            inputs: nil
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
            intensity: "high",
            strainLoadPoints: 12.4
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
            intensity: "moderate",
            strainLoadPoints: 9.8
        )
    ]
}
