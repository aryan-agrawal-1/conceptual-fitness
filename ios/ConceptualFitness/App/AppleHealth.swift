import Foundation
import HealthKit
import HealthKitUI
import OSLog
import SwiftUI

struct AppleHealthType: Sendable {
    let identifier: String
    let name: String
    let unit: HKUnit?
    let unitLabel: String?

    var sampleType: HKSampleType {
        if identifier == HKWorkoutTypeIdentifier { return .workoutType() }
        if identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue {
            return HKCategoryType(.sleepAnalysis)
        }
        return HKQuantityType(HKQuantityTypeIdentifier(rawValue: identifier))
    }
}

enum AppleHealthCatalog {
    static let beatsPerMinute = HKUnit.count().unitDivided(by: .minute())
    static let vo2Max = HKUnit.literUnit(with: .milli)
        .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))

    static let types: [AppleHealthType] = [
        quantity(.heartRate, "heart_rate", beatsPerMinute, "count/min"),
        quantity(.restingHeartRate, "resting_heart_rate", beatsPerMinute, "count/min"),
        quantity(.heartRateVariabilitySDNN, "heart_rate_variability", .secondUnit(with: .milli), "ms"),
        quantity(.respiratoryRate, "respiratory_rate", beatsPerMinute, "count/min"),
        quantity(.oxygenSaturation, "oxygen_saturation", .percent(), "%"),
        quantity(.appleSleepingWristTemperature, "wrist_temperature", .degreeCelsius(), "degC"),
        quantity(.stepCount, "steps", .count(), "count"),
        quantity(.distanceWalkingRunning, "distance", .meter(), "m"),
        quantity(.activeEnergyBurned, "active_energy", .kilocalorie(), "kcal"),
        quantity(.basalEnergyBurned, "resting_energy", .kilocalorie(), "kcal"),
        quantity(.vo2Max, "vo2_max", vo2Max, "ml/kg*min"),
        quantity(.bodyMass, "weight", .gramUnit(with: .kilo), "kg"),
        quantity(.height, "height", .meter(), "m"),
        AppleHealthType(identifier: HKCategoryTypeIdentifier.sleepAnalysis.rawValue, name: "sleep", unit: nil, unitLabel: nil),
        AppleHealthType(identifier: HKWorkoutTypeIdentifier, name: "workouts", unit: nil, unitLabel: nil),
    ]

    static var readTypes: Set<HKObjectType> { Set(types.map(\.sampleType)) }

    private static func quantity(
        _ identifier: HKQuantityTypeIdentifier, _ name: String, _ unit: HKUnit, _ label: String
    ) -> AppleHealthType {
        AppleHealthType(identifier: identifier.rawValue, name: name, unit: unit, unitLabel: label)
    }
}

struct DeviceSampleSource: Encodable, Equatable {
    let bundleID: String?
    let name: String?
    let deviceName: String?
    let deviceModel: String?
    let productType: String?

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case name
        case deviceName = "device_name"
        case deviceModel = "device_model"
        case productType = "product_type"
    }
}

struct DeviceWorkoutDetails: Encodable, Equatable {
    let activityType: String
    let durationSeconds: Double
    let totalEnergyKcal: Double?
    let totalDistanceMeters: Double?

    enum CodingKeys: String, CodingKey {
        case activityType = "activity_type"
        case durationSeconds = "duration_seconds"
        case totalEnergyKcal = "total_energy_kcal"
        case totalDistanceMeters = "total_distance_m"
    }
}

struct DeviceSampleUpload: Encodable, Equatable {
    let id: String
    let start: String
    let end: String
    var value: Double?
    var unit: String?
    var categoryValue: Int?
    let source: DeviceSampleSource
    var workout: DeviceWorkoutDetails?

    enum CodingKeys: String, CodingKey {
        case id, start, end, value, unit, source, workout
        case categoryValue = "category_value"
    }
}

struct DeviceBatchUpload: Encodable, Equatable {
    let dataType: String
    let phase: String
    let rangeStart: String
    let rangeEnd: String
    let samples: [DeviceSampleUpload]
    let deletedIDs: [String]
    let anchor: String?
    let final: Bool

    enum CodingKeys: String, CodingKey {
        case dataType = "data_type"
        case phase
        case rangeStart = "range_start"
        case rangeEnd = "range_end"
        case samples
        case deletedIDs = "deleted_ids"
        case anchor
        case final
    }
}

enum AppleHealthEncoder {
    static func upload(for sample: HKSample, type: AppleHealthType) -> DeviceSampleUpload? {
        var upload = DeviceSampleUpload(
            id: sample.uuid.uuidString,
            start: timestamp(sample.startDate),
            end: timestamp(sample.endDate),
            source: source(for: sample)
        )
        if let quantity = sample as? HKQuantitySample, let unit = type.unit {
            guard quantity.quantity.is(compatibleWith: unit) else { return nil }
            let value = quantity.quantity.doubleValue(for: unit)
            guard value.isFinite else { return nil }
            upload.value = value
            upload.unit = type.unitLabel
        } else if let category = sample as? HKCategorySample {
            upload.categoryValue = category.value
        } else if let workout = sample as? HKWorkout {
            upload.workout = DeviceWorkoutDetails(
                activityType: activityName(workout.workoutActivityType),
                durationSeconds: workout.duration,
                totalEnergyKcal: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                    .sumQuantity()?.doubleValue(for: .kilocalorie()),
                totalDistanceMeters: workout.totalDistance?.doubleValue(for: .meter())
            )
        } else {
            return nil
        }
        return upload
    }

    static func source(for sample: HKSample) -> DeviceSampleSource {
        let revision = sample.sourceRevision
        return DeviceSampleSource(
            bundleID: revision.source.bundleIdentifier,
            name: revision.source.name,
            deviceName: sample.device?.name,
            deviceModel: sample.device?.model,
            productType: revision.productType
        )
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }

    static func activityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: "running"
        case .walking: "walking"
        case .cycling: "cycling"
        case .swimming: "swimming"
        case .rowing: "rowing"
        case .hiking: "hiking"
        case .elliptical: "elliptical"
        case .stairClimbing: "stair_climbing"
        case .traditionalStrengthTraining: "traditional_strength_training"
        case .functionalStrengthTraining: "functional_strength_training"
        case .coreTraining: "core_training"
        case .highIntensityIntervalTraining: "high_intensity_interval_training"
        case .crossTraining: "cross_training"
        case .mixedCardio: "mixed_cardio"
        case .cardioDance: "cardio_dance"
        case .yoga: "yoga"
        case .pilates: "pilates"
        case .soccer: "soccer"
        case .basketball: "basketball"
        case .tennis: "tennis"
        case .cooldown: "cooldown"
        default: "other"
        }
    }
}

enum AppleHealthPhase: String, CaseIterable, Sendable {
    case current
    case historical
}

struct AppleHealthWindow: Equatable, Sendable {
    static let currentDays = 14
    static let totalDays = 90

    let currentStart: Date

    init(currentStart: Date) {
        self.currentStart = currentStart
    }

    init(connectedOn day: Date, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: day)
        currentStart = calendar.date(byAdding: .day, value: -(Self.currentDays - 1), to: today) ?? today
    }

    func historicalStart(calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -(Self.totalDays - Self.currentDays), to: currentStart) ?? currentStart
    }

    func range(for phase: AppleHealthPhase, now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date?) {
        switch phase {
        case .current: (currentStart, nil)
        case .historical: (historicalStart(calendar: calendar), currentStart)
        }
    }

    func dayRange(for phase: AppleHealthPhase, now: Date = Date(), calendar: Calendar = .current) -> (String, String) {
        let formatter = Self.dayFormatter(calendar: calendar)
        switch phase {
        case .current:
            return (formatter.string(from: currentStart), formatter.string(from: max(now, currentStart)))
        case .historical:
            let end = calendar.date(byAdding: .day, value: -1, to: currentStart) ?? currentStart
            return (formatter.string(from: historicalStart(calendar: calendar)), formatter.string(from: end))
        }
    }

    private static func dayFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

struct AppleHealthProgress: Equatable {
    var completed: [String: Set<AppleHealthPhase>] = [:]

    func isComplete(_ type: String, _ phase: AppleHealthPhase) -> Bool {
        completed[type]?.contains(phase) ?? false
    }

    func backfillStatus(window: AppleHealthWindow, failedType: String?) -> HistoricalBackfillStatus {
        let types = AppleHealthCatalog.types
        let range = window.dayRange(for: .historical)
        let current = window.dayRange(for: .current)
        let sources = types.map { type in
            let done = isComplete(type.identifier, .historical)
            return HistoricalBackfillSource(
                dataType: type.name,
                status: done ? "succeeded" : failedType == type.identifier ? "failed" : "running",
                coverageStart: done ? range.0 : nil,
                coverageEnd: done ? current.1 : nil,
                pageInProgress: !done,
                completedAt: nil
            )
        }
        let completedCount = sources.filter { $0.status == "succeeded" }.count
        return HistoricalBackfillStatus(
            status: completedCount == types.count ? "complete" : failedType != nil ? "failed" : "running",
            completedSources: completedCount,
            totalSources: types.count,
            rangeStart: range.0,
            rangeEnd: current.1,
            calibrationState: completedCount == types.count ? "complete" : "calibrating",
            checkpointAt: nil,
            sources: sources
        )
    }
}

struct AppleHealthState {
    private let defaults: UserDefaults
    private let userID: String

    init(userID: String, defaults: UserDefaults = .standard) {
        self.userID = userID
        self.defaults = defaults
    }

    static let keyPrefix = "appleHealth."

    private func key(_ name: String) -> String { "\(Self.keyPrefix)\(userID).\(name)" }

    func window(now: Date = Date()) -> AppleHealthWindow {
        if let stored = defaults.object(forKey: key("currentStart")) as? Date {
            return AppleHealthWindow(currentStart: stored)
        }
        let window = AppleHealthWindow(connectedOn: now)
        defaults.set(window.currentStart, forKey: key("currentStart"))
        return window
    }

    func anchor(_ type: String, _ phase: AppleHealthPhase) -> HKQueryAnchor? {
        guard let data = defaults.data(forKey: key("anchor.\(phase.rawValue).\(type)")) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    func save(_ anchor: HKQueryAnchor?, _ type: String, _ phase: AppleHealthPhase) {
        guard let anchor, let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else { return }
        defaults.set(data, forKey: key("anchor.\(phase.rawValue).\(type)"))
    }

    var progress: AppleHealthProgress {
        var progress = AppleHealthProgress()
        for type in AppleHealthCatalog.types {
            for phase in AppleHealthPhase.allCases where defaults.bool(forKey: key("done.\(phase.rawValue).\(type.identifier)")) {
                progress.completed[type.identifier, default: []].insert(phase)
            }
        }
        return progress
    }

    func markComplete(_ type: String, _ phase: AppleHealthPhase) {
        defaults.set(true, forKey: key("done.\(phase.rawValue).\(type)"))
    }

    var samplesReceived: Int { defaults.integer(forKey: key("samplesReceived")) }

    func addReceived(_ count: Int) {
        defaults.set(samplesReceived + count, forKey: key("samplesReceived"))
    }

    static func anchorString(_ anchor: HKQueryAnchor?) -> String? {
        guard let anchor, let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else { return nil }
        return data.base64EncodedString()
    }
}

enum AppleHealthSyncError: Error {
    case unavailable
    case notConnected
}

@MainActor
final class AppleHealthSync {
    static let shared = AppleHealthSync()
    static let batchLimit = 500
    private static let backgroundUserKey = "appleHealth.backgroundUser"

    let store = HKHealthStore()
    private let logger = Logger(subsystem: "ConceptualFitness", category: "AppleHealth")
    private var running: Task<Void, Error>?
    private var observers: [HKObserverQuery] = []
    private weak var authStore: AuthStore?

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        guard Self.isAvailable else { throw AppleHealthSyncError.unavailable }
        try await AppleHealthAccessPrompt.shared.request()
    }

    func enable(authStore: AuthStore, userID: String) {
        UserDefaults.standard.set(userID, forKey: Self.backgroundUserKey)
        startObserving(authStore: authStore)
    }

    func disable() {
        UserDefaults.standard.removeObject(forKey: Self.backgroundUserKey)
        observers.forEach(store.stop)
        observers = []
        store.disableAllBackgroundDelivery { _, _ in }
    }

    func resumeIfEnabled(authStore: AuthStore) {
        guard UserDefaults.standard.string(forKey: Self.backgroundUserKey) != nil else { return }
        startObserving(authStore: authStore)
    }

    func state(for userID: String) -> AppleHealthState { AppleHealthState(userID: userID) }

    func sync(authStore: AuthStore, userID: String, types: [AppleHealthType] = AppleHealthCatalog.types) async throws {
        while let running {
            _ = try? await running.value
        }
        let task = Task {
            defer { self.running = nil }
            try await self.performSync(authStore: authStore, userID: userID, types: types)
        }
        running = task
        try await task.value
    }

    private func performSync(authStore: AuthStore, userID: String, types: [AppleHealthType]) async throws {
        let state = state(for: userID)
        let window = state.window()
        for phase in AppleHealthPhase.allCases {
            for type in types where phase == .current || !state.progress.isComplete(type.identifier, .historical) {
                try await sync(type, phase: phase, window: window, state: state, authStore: authStore)
            }
        }
    }

    private func sync(
        _ type: AppleHealthType,
        phase: AppleHealthPhase,
        window: AppleHealthWindow,
        state: AppleHealthState,
        authStore: AuthStore
    ) async throws {
        let range = window.range(for: phase)
        let days = window.dayRange(for: phase)
        let predicate = HKQuery.predicateForSamples(withStart: range.start, end: range.end)
        var anchor = state.anchor(type.identifier, phase)
        logger.info("Reading type=\(type.name, privacy: .public) phase=\(phase.rawValue, privacy: .public)")
        while true {
            let page = try await anchoredPage(type: type.sampleType, predicate: predicate, anchor: anchor)
            let samples = page.samples.compactMap { AppleHealthEncoder.upload(for: $0, type: type) }
            let final = page.samples.count + page.deleted.count < Self.batchLimit
            let batch = DeviceBatchUpload(
                dataType: type.identifier,
                phase: phase.rawValue,
                rangeStart: days.0,
                rangeEnd: days.1,
                samples: samples,
                deletedIDs: page.deleted.map(\.uuid.uuidString),
                anchor: AppleHealthState.anchorString(page.anchor),
                final: final
            )
            do {
                let _: DeviceBatchResult = try await authStore.authenticatedJSON(
                    path: "/ingest/apple-health/batches", method: "POST", body: batch
                )
            } catch let error as HTTPResponseError where error.statusCode == 409 {
                throw AppleHealthSyncError.notConnected
            } catch {
                logger.error("Upload failed type=\(type.name, privacy: .public) phase=\(phase.rawValue, privacy: .public) error=\(String(describing: Swift.type(of: error)), privacy: .public)")
                throw error
            }
            state.save(page.anchor, type.identifier, phase)
            state.addReceived(samples.count)
            anchor = page.anchor
            logger.info("Uploaded type=\(type.name, privacy: .public) phase=\(phase.rawValue, privacy: .public) samples=\(samples.count) deleted=\(page.deleted.count) final=\(final)")
            if final {
                state.markComplete(type.identifier, phase)
                return
            }
        }
    }

    private func anchoredPage(
        type: HKSampleType, predicate: NSPredicate, anchor: HKQueryAnchor?
    ) async throws -> (samples: [HKSample], deleted: [HKDeletedObject], anchor: HKQueryAnchor?) {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: type, predicate: predicate, anchor: anchor, limit: Self.batchLimit
            ) { _, samples, deleted, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples ?? [], deleted ?? [], newAnchor))
                }
            }
            store.execute(query)
        }
    }

    private func startObserving(authStore: AuthStore) {
        guard Self.isAvailable, observers.isEmpty else { return }
        self.authStore = authStore
        for type in AppleHealthCatalog.types {
            let query = HKObserverQuery(sampleType: type.sampleType, predicate: nil) { [weak self] _, completion, error in
                guard error == nil else {
                    completion()
                    return
                }
                Task { @MainActor in
                    await self?.backgroundSync(type)
                    completion()
                }
            }
            store.execute(query)
            observers.append(query)
            store.enableBackgroundDelivery(for: type.sampleType, frequency: .hourly) { [logger] success, _ in
                if !success { logger.error("Background delivery unavailable type=\(type.name, privacy: .public)") }
            }
        }
    }

    private func backgroundSync(_ type: AppleHealthType) async {
        guard let authStore, let userID = UserDefaults.standard.string(forKey: Self.backgroundUserKey) else { return }
        do {
            try await sync(authStore: authStore, userID: userID, types: [type])
        } catch {
            logger.error("Background sync failed type=\(type.name, privacy: .public)")
        }
    }
}

private struct DeviceBatchResult: Decodable {}

@MainActor
final class AppleHealthAccessPrompt: ObservableObject {
    static let shared = AppleHealthAccessPrompt()
    @Published private(set) var trigger = 0
    private var continuation: CheckedContinuation<Void, Error>?

    func request() async throws {
        continuation?.resume(throwing: CancellationError())
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            trigger += 1
        }
    }

    func finish(_ result: Result<Bool, Error>) {
        switch result {
        case .success: continuation?.resume()
        case .failure(let error): continuation?.resume(throwing: error)
        }
        continuation = nil
    }
}

struct AppleHealthAccessModifier: ViewModifier {
    @ObservedObject private var prompt = AppleHealthAccessPrompt.shared

    func body(content: Content) -> some View {
        content.healthDataAccessRequest(
            store: AppleHealthSync.shared.store,
            readTypes: AppleHealthCatalog.readTypes,
            trigger: prompt.trigger
        ) { result in
            prompt.finish(result)
        }
    }
}
