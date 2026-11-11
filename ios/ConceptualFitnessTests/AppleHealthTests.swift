import HealthKit
import XCTest
@testable import ConceptualFitness

final class AppleHealthTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func day(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: "\(value)T12:00:00Z")!
    }

    func testWindowImportsFourteenDaysThenNinetyInTotal() {
        let window = AppleHealthWindow(connectedOn: day("2026-11-11"), calendar: calendar)

        XCTAssertEqual(window.dayRange(for: .current, now: day("2026-11-11"), calendar: calendar).0, "2026-10-29")
        XCTAssertEqual(window.dayRange(for: .current, now: day("2026-11-11"), calendar: calendar).1, "2026-11-11")
        XCTAssertEqual(window.dayRange(for: .historical, calendar: calendar).0, "2026-08-14")
        XCTAssertEqual(window.dayRange(for: .historical, calendar: calendar).1, "2026-10-28")
        XCTAssertNil(window.range(for: .current, calendar: calendar).end)
        XCTAssertEqual(window.range(for: .historical, calendar: calendar).end, window.currentStart)
    }

    func testCatalogReadsOnlyTheTypesTheServerAccepts() {
        let identifiers = Set(AppleHealthCatalog.types.map(\.identifier))

        XCTAssertEqual(identifiers.count, 15)
        XCTAssertTrue(identifiers.contains("HKQuantityTypeIdentifierHeartRateVariabilitySDNN"))
        XCTAssertTrue(identifiers.contains("HKCategoryTypeIdentifierSleepAnalysis"))
        XCTAssertTrue(identifiers.contains("HKWorkoutTypeIdentifier"))
        XCTAssertEqual(AppleHealthCatalog.readTypes.count, 15)
    }

    func testQuantitySamplesUploadInServerUnits() throws {
        let type = try XCTUnwrap(AppleHealthCatalog.types.first { $0.name == "oxygen_saturation" })
        let sample = HKQuantitySample(
            type: HKQuantityType(.oxygenSaturation),
            quantity: HKQuantity(unit: .percent(), doubleValue: 0.97),
            start: day("2026-11-10"),
            end: day("2026-11-10")
        )

        let upload = try XCTUnwrap(AppleHealthEncoder.upload(for: sample, type: type))

        XCTAssertEqual(upload.value, 0.97)
        XCTAssertEqual(upload.unit, "%")
        XCTAssertEqual(upload.id, sample.uuid.uuidString)
        XCTAssertTrue(upload.start.hasPrefix("2026-11-10T12:00:00"))
    }

    func testSleepStagesUploadTheirCategoryValue() throws {
        let type = try XCTUnwrap(AppleHealthCatalog.types.first { $0.name == "sleep" })
        let sample = HKCategorySample(
            type: HKCategoryType(.sleepAnalysis),
            value: HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            start: day("2026-11-10"),
            end: day("2026-11-10").addingTimeInterval(1800)
        )

        let upload = try XCTUnwrap(AppleHealthEncoder.upload(for: sample, type: type))

        XCTAssertEqual(upload.categoryValue, 4)
        XCTAssertNil(upload.value)
    }

    func testBatchesEncodeTheServerFieldNames() throws {
        let batch = DeviceBatchUpload(
            dataType: "HKQuantityTypeIdentifierHeartRate", phase: "current",
            rangeStart: "2026-10-29", rangeEnd: "2026-11-11", samples: [], deletedIDs: ["A"],
            anchor: nil, final: true
        )

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as? [String: Any])

        XCTAssertEqual(Set(json.keys), ["data_type", "phase", "range_start", "range_end", "samples", "deleted_ids", "final"])
    }

    func testWorkoutNamesUseTheServerVocabulary() {
        XCTAssertEqual(AppleHealthEncoder.activityName(.traditionalStrengthTraining), "traditional_strength_training")
        XCTAssertEqual(AppleHealthEncoder.activityName(.highIntensityIntervalTraining), "high_intensity_interval_training")
        XCTAssertEqual(AppleHealthEncoder.activityName(.archery), "other")
    }

    func testProgressReportsEachTypeUntilHistoryIsComplete() {
        let window = AppleHealthWindow(connectedOn: day("2026-11-11"), calendar: calendar)
        var progress = AppleHealthProgress()
        progress.completed["HKWorkoutTypeIdentifier"] = [.current, .historical]

        let partial = progress.backfillStatus(window: window, failedType: "HKQuantityTypeIdentifierHeartRate")

        XCTAssertEqual(partial.completedSources, 1)
        XCTAssertEqual(partial.totalSources, 15)
        XCTAssertEqual(partial.status, "failed")
        XCTAssertEqual(partial.sources.first { $0.dataType == "heart_rate" }?.status, "failed")

        for type in AppleHealthCatalog.types { progress.completed[type.identifier] = [.historical] }
        XCTAssertEqual(progress.backfillStatus(window: window, failedType: nil).status, "complete")
    }

    func testStateRemembersAnchorsAndCompletionPerUser() {
        let defaults = UserDefaults(suiteName: "AppleHealthTests")!
        defaults.removePersistentDomain(forName: "AppleHealthTests")
        let first = AppleHealthState(userID: "one", defaults: defaults)
        let second = AppleHealthState(userID: "two", defaults: defaults)

        first.markComplete("HKWorkoutTypeIdentifier", .historical)
        first.addReceived(3)

        XCTAssertTrue(first.progress.isComplete("HKWorkoutTypeIdentifier", .historical))
        XCTAssertFalse(second.progress.isComplete("HKWorkoutTypeIdentifier", .historical))
        XCTAssertEqual(first.samplesReceived, 3)
        XCTAssertEqual(second.samplesReceived, 0)
        XCTAssertEqual(first.window(now: day("2026-11-11")), first.window(now: day("2026-12-25")))
    }
}
