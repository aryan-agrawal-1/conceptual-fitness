import Foundation

struct DashboardAPIClient {
    var baseURL: URL = URL(string: "http://127.0.0.1:8000")!
    var session: URLSession = .shared
    var authStore: AuthStore?

    func loadDashboard(now: Date = Date(), calendar: Calendar = .current) async throws -> DashboardDisplayBundle {
        let today = try await loadDashboard(for: now)
        if shouldUseYesterdayFallback(now: now, calendar: calendar, bundle: today) {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
            return DashboardDisplayBundle(
                bundle: try await loadDashboard(for: yesterday),
                dateContext: .yesterday
            )
        }
        return DashboardDisplayBundle(bundle: today, dateContext: .today)
    }

    func syncCurrent() async throws -> CurrentSyncResponse {
        try await request("/sync/current", method: "POST")
    }

    func currentSyncStatus() async throws -> CurrentSyncStatus {
        try await fetch("/sync/current/status")
    }

    func loadStrainDetail(date: Date = Date(), timeframe: StrainTimeframe) async throws -> StrainDetail {
        let dateString = Self.apiDate.string(from: date)
        return try await fetch("/strain/detail?date=\(dateString)&timeframe=\(timeframe.rawValue)")
    }

    func loadReadinessDetail(date: Date = Date(), timeframe: ScoreTimeframe) async throws -> ReadinessDetail {
        let dateString = Self.apiDate.string(from: date)
        return try await fetch("/readiness/detail?date=\(dateString)&timeframe=\(timeframe.rawValue)")
    }

    func loadSleepDetail(date: Date = Date(), timeframe: ScoreTimeframe) async throws -> SleepDetail {
        let dateString = Self.apiDate.string(from: date)
        return try await fetch("/sleep/detail?date=\(dateString)&timeframe=\(timeframe.rawValue)")
    }

    func loadHRVDetail(date: Date = Date(), timeframe: ScoreTimeframe) async throws -> HRVDetail {
        let dateString = Self.apiDate.string(from: date)
        return try await fetch("/metrics/heart_rate_variability/detail?date=\(dateString)&timeframe=\(timeframe.rawValue)")
    }

    func loadRestingHeartRateDetail(date: Date = Date(), timeframe: ScoreTimeframe) async throws -> RestingHeartRateDetail {
        let dateString = Self.apiDate.string(from: date)
        return try await fetch("/metrics/resting_heart_rate/detail?date=\(dateString)&timeframe=\(timeframe.rawValue)")
    }

    func loadSkinTemperatureVariationDetail(date: Date = Date(), timeframe: ScoreTimeframe) async throws -> SkinTemperatureVariationDetail {
        let dateString = Self.apiDate.string(from: date)
        return try await fetch("/metrics/skin_temperature_variation/detail?date=\(dateString)&timeframe=\(timeframe.rawValue)")
    }

    func loadHeartRateDetail(date: Date = Date(), timeframe: ScoreTimeframe) async throws -> HeartRateDetail {
        let dateString = Self.apiDate.string(from: date)
        return try await fetch("/metrics/heart_rate/detail?date=\(dateString)&timeframe=\(timeframe.rawValue)")
    }

    func loadWorkoutDetail(id: String) async throws -> WorkoutDetail {
        try await fetch("/workouts/\(id)")
    }

    private func loadDashboard(for date: Date) async throws -> DashboardBundle {
        let dateString = Self.apiDate.string(from: date)
        return try await fetch("/dashboard/bundle?date=\(dateString)")
    }

    private func shouldUseYesterdayFallback(
        now: Date,
        calendar: Calendar,
        bundle: DashboardBundle
    ) -> Bool {
        let hour = calendar.component(.hour, from: now)
        guard hour < 4 else { return false }
        return !bundle.hasMeaningfulCurrentRecovery
    }

    private func fetch<T: Decodable>(_ path: String) async throws -> T {
        try await request(path, method: "GET")
    }

    private func request<T: Decodable>(_ path: String, method: String) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        if let authStore {
            data = try await authStore.authenticatedData(for: request)
        } else {
            let (rawData, response) = try await session.data(for: request)
            try validate(response: response)
            data = rawData
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private static let apiDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct DashboardDisplayBundle {
    let bundle: DashboardBundle
    let dateContext: DashboardDateContext
}

enum DashboardDateContext {
    case today
    case yesterday
}

struct CurrentSyncResponse: Decodable {
    let status: CurrentSyncResponseStatus
    let accountID: String?
    let isRunning: Bool?
    let isFresh: Bool?
    let lastSyncAt: String?

    enum CodingKeys: String, CodingKey {
        case status
        case accountID = "account_id"
        case isRunning = "is_running"
        case isFresh = "is_fresh"
        case lastSyncAt = "last_sync_at"
    }
}

enum CurrentSyncResponseStatus: String, Decodable {
    case synced
    case skippedFresh = "skipped_fresh"
    case alreadyRunning = "already_running"
}

struct CurrentSyncStatus: Decodable {
    let accountID: String
    let isRunning: Bool
    let isFresh: Bool
    let lastSyncAt: String?
    let cursors: [DashboardSyncStatus]

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case isRunning = "is_running"
        case isFresh = "is_fresh"
        case lastSyncAt = "last_sync_at"
        case cursors
    }
}

private extension DashboardBundle {
    var hasMeaningfulCurrentRecovery: Bool {
        snapshot.scores.sleep?.value != nil
            || snapshot.scores.readiness?.value != nil
            || snapshot.metrics?.sleepMinutes != nil
    }
}
