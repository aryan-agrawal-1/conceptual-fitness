import XCTest
@testable import ConceptualFitness

private func booleanField(_ label: String) -> JournalFieldData {
    JournalFieldData(id: "answer", label: label, inputType: "boolean", minimum: nil, maximum: nil,
                     units: [], ratingLabels: [])
}

private func ratingField(_ label: String) -> JournalFieldData {
    JournalFieldData(id: "answer", label: label, inputType: "rating", minimum: 1, maximum: 5, units: [],
                     ratingLabels: ["Very low", "Low", "Okay", "Good", "Very good"])
}

private func behaviour(_ id: String, category: String = "wellbeing", answer: JournalFieldData? = nil,
                       presentation: String = "standard", statistical: Bool = true) -> JournalBehaviourData {
    JournalBehaviourData(id: id, categoryId: category, label: id, question: "\(id)?",
                         answer: answer ?? booleanField(id), details: [], presentation: presentation,
                         discreetLabel: "Private input", statisticalInput: statistical)
}

private let testCatalogue = JournalCatalogueData(
    version: 1, schemaVersion: 1,
    categories: [
        JournalCategoryData(id: "wellbeing", label: "Wellbeing", requiresOptIn: false),
        JournalCategoryData(id: "substances", label: "Substances", requiresOptIn: true),
        JournalCategoryData(id: "reflection", label: "Reflection", requiresOptIn: true),
    ],
    behaviours: [
        behaviour("mood", answer: ratingField("Mood")),
        behaviour("stress", answer: ratingField("Stress")),
        behaviour("energy", answer: ratingField("Energy")),
        behaviour("screen_in_bed"),
        behaviour("worked_late"),
        behaviour("night_shift"),
        behaviour("travel"),
        behaviour("sauna"),
        behaviour("caffeine", category: "substances", presentation: "discreet"),
        behaviour("daily_note", category: "reflection", presentation: "discreet", statistical: false),
    ],
    units: [JournalUnitData(id: "mg", label: "Milligrams", canonicalUnit: "mg", multiplier: 1),
            JournalUnitData(id: "g", label: "Grams", canonicalUnit: "mg", multiplier: 1000)])

private func response(_ id: String, day: String, answer: JournalAnswerData?,
                      missing: String? = nil) -> JournalResponseData {
    JournalResponseData(catalogueVersion: 1, journalDate: day, timezone: "Europe/London",
                        recordedAt: "2026-11-02T08:00:00.000Z", behaviourId: id, answer: answer,
                        missingReason: missing)
}

private func entry(_ id: String, day: String, answer: JournalAnswerData? = .init(type: "boolean", value: .boolean(true)),
                   missing: String? = nil, deleted: Bool = false, stamp: String = "2026-11-02T08:00:00.000Z",
                   mutation: String = UUID().uuidString.lowercased()) -> JournalEntryData {
    JournalEntryData(journalDate: day, behaviourId: id, editedAt: stamp, mutationId: mutation, deleted: deleted,
                     response: deleted ? nil : response(id, day: day, answer: answer, missing: missing))
}

private func setting(_ key: String, _ value: Bool = true) -> JournalSettingData {
    JournalSettingData(key: key, value: value, editedAt: "2026-11-02T08:00:00.000Z",
                       mutationId: UUID().uuidString.lowercased())
}

private func snapshot(entries: [JournalEntryData] = [], settings: [JournalSettingData] = [],
                      goals: [String] = []) -> JournalSnapshot {
    var value = JournalSnapshot()
    value.catalogue = testCatalogue
    value.timezone = "Europe/London"
    value.goals = goals
    value.entries = entries
    value.preferences = settings
    return value
}

final class JournalDailyListTests: XCTestCase {
    private let day = "2026-11-02"
    private let optIn = setting("opt_in:substances")

    private func sections(_ value: JournalSnapshot) -> JournalDailySections {
        JournalDailyList.sections(value, day: day)
    }

    func testDefaultPinsAreFixedAndInOrder() {
        XCTAssertEqual(sections(snapshot()).pinned.map(\.id), ["mood", "stress", "energy", "worked_late", "screen_in_bed"])
    }

    func testListDoesNotRotateAcrossDates() {
        let first = sections(snapshot())
        let later = JournalDailyList.sections(snapshot(), day: "2026-11-09")
        XCTAssertEqual(first.pinned.map(\.id), later.pinned.map(\.id))
        XCTAssertEqual(first.others.map(\.id), later.others.map(\.id))
    }

    func testYouCanUnpinADefaultAndPinAnything() {
        let result = sections(snapshot(settings: [setting("pin:stress", false), setting("pin:sauna")]))
        XCTAssertEqual(result.pinned.map(\.id), ["mood", "energy", "worked_late", "screen_in_bed", "sauna"])
        XCTAssertTrue(result.others.contains { $0.id == "stress" })
    }

    func testPrivateCategoryIsHiddenUntilTurnedOn() {
        let off = sections(snapshot())
        XCTAssertTrue(off.privatePinned.isEmpty)
        XCTAssertFalse(off.others.contains { $0.id == "caffeine" })
        XCTAssertEqual(sections(snapshot(settings: [optIn])).privatePinned.map(\.id), ["substances"])
        XCTAssertEqual(sections(snapshot(settings: [optIn])).privatePinned.first?.behaviours.map(\.id), ["caffeine"])
    }

    func testUnpinnedPrivateInputMovesToOthers() {
        let result = sections(snapshot(settings: [optIn, setting("pin:caffeine", false)]))
        XCTAssertTrue(result.privatePinned.isEmpty)
        XCTAssertTrue(result.others.contains { $0.id == "caffeine" })
    }

    func testAnswersInACategoryThatIsOffStayReviewable() {
        let saved = entry("caffeine", day: day)
        XCTAssertEqual(sections(snapshot(entries: [saved])).turnedOff.map(\.id), ["caffeine"])
        XCTAssertTrue(sections(snapshot()).turnedOff.isEmpty)
        let deleted = entry("caffeine", day: day, deleted: true)
        XCTAssertTrue(sections(snapshot(entries: [deleted])).turnedOff.isEmpty)
    }

    func testAnsweringDoesNotMoveRows() {
        let before = sections(snapshot())
        let entries = (before.pinned + before.others).map { entry($0.id, day: day) }
        let after = sections(snapshot(entries: entries))
        XCTAssertEqual(before.pinned.map(\.id), after.pinned.map(\.id))
        XCTAssertEqual(before.others.map(\.id), after.others.map(\.id))
    }

    func testGoalsAndEarlierUseOrderTheOtherInputs() {
        XCTAssertEqual(sections(snapshot(goals: ["Better sleep"])).others.first?.id, "night_shift")
        let used = sections(snapshot(entries: [entry("travel", day: "2026-11-01")]))
        XCTAssertEqual(used.others.first?.id, "travel")
    }

    func testLoggedCountIgnoresSkippedAndDeleted() {
        let entries = [entry("mood", day: day), entry("travel", day: day, answer: .init(type: "boolean", value: .boolean(false))),
                       entry("stress", day: day, answer: nil, missing: "skipped"), entry("energy", day: day, deleted: true),
                       entry("sauna", day: "2026-11-01")]
        XCTAssertEqual(JournalDailyList.loggedCount(snapshot(entries: entries), day: day), 2)
    }

    func testTargetIsReachedAtFiveAnswers() {
        XCTAssertFalse(JournalDailyList.reachedTarget(0))
        XCTAssertFalse(JournalDailyList.reachedTarget(4))
        XCTAssertTrue(JournalDailyList.reachedTarget(5))
        XCTAssertTrue(JournalDailyList.reachedTarget(7))
    }

    func testWeekEndsTodayAndTitlesAreRelative() {
        let week = JournalDay.week(endingOn: "2026-11-02")
        XCTAssertEqual(week.map(\.id).first, "2026-10-27")
        XCTAssertEqual(week.map(\.id).last, "2026-11-02")
        XCTAssertEqual(week.last?.number, "2")
        XCTAssertEqual(JournalDay.title("2026-11-02", today: "2026-11-02"), "Today")
        XCTAssertEqual(JournalDay.title("2026-11-01", today: "2026-11-02"), "Yesterday")
        XCTAssertNotEqual(JournalDay.title("2026-10-20", today: "2026-11-02"), "Today")
    }
}

final class JournalAnswerUpdateTests: XCTestCase {
    private let yes = JournalAnswerData(type: "boolean", value: .boolean(true))
    private let no = JournalAnswerData(type: "boolean", value: .boolean(false))
    private let time = JournalAnswerData(type: "time", value: .text("14:30"))

    private func update(_ existing: JournalResponseData?, _ answer: JournalAnswerData?,
                        details: [String: JournalAnswerData] = [:], missing: String? = nil) -> JournalResponseData {
        .updating(existing, behaviourId: "caffeine", day: "2026-11-02", catalogueVersion: 1, timezone: "UTC",
                  answer: answer, details: details, missingReason: missing)
    }

    func testChangingAnAnswerKeepsOriginalTimezoneAndRecordingTime() {
        let original = response("caffeine", day: "2026-11-02", answer: yes)
        let updated = update(original, no)
        XCTAssertEqual(updated.timezone, "Europe/London")
        XCTAssertEqual(updated.recordedAt, original.recordedAt)
    }

    func testAnsweringNoClearsDetails() {
        XCTAssertEqual(update(nil, yes, details: ["last_use": time]).details["last_use"]?.value, .text("14:30"))
        XCTAssertTrue(update(nil, no, details: ["last_use": time]).details.isEmpty)
    }

    func testSkippingClearsTheAnswerAndKeepsTheReason() {
        let skipped = update(response("caffeine", day: "2026-11-02", answer: yes), nil, details: ["last_use": time], missing: "skipped")
        XCTAssertNil(skipped.answer)
        XCTAssertTrue(skipped.details.isEmpty)
        XCTAssertEqual(skipped.missingReason, "skipped")
    }

    func testRowsKeepOneMainDetailInline() {
        func field(_ id: String, _ type: String) -> JournalFieldData {
            JournalFieldData(id: id, label: id, inputType: type, minimum: 0, maximum: 10, units: [], ratingLabels: [])
        }
        let caffeine = [field("amount", "quantity"), field("servings", "count"), field("last_use", "time")]
        XCTAssertEqual(JournalDetailPanel.inlineFields(caffeine).map(\.id), ["servings"])
        let alcohol = [field("amount", "quantity"), field("last_use", "time")]
        XCTAssertEqual(JournalDetailPanel.inlineFields(alcohol).map(\.id), ["amount"])
        XCTAssertEqual(JournalDetailPanel.inlineFields([field("severity", "rating")]).map(\.id), ["severity"])
        XCTAssertTrue(JournalDetailPanel.inlineFields([field("last_use", "time")]).isEmpty)
    }

    func testSliderSpecsCoverEveryUnitField() {
        func field(_ units: [String]) -> JournalFieldData {
            JournalFieldData(id: "amount", label: "Amount", inputType: "quantity", minimum: 0, maximum: 100_000, units: units, ratingLabels: [])
        }
        XCTAssertEqual(JournalSliderSpec.spec(behaviour: "alcohol", field: field(["uk_alcohol_unit", "mL_ethanol"]))?.unit, "uk_alcohol_unit")
        XCTAssertEqual(JournalSliderSpec.spec(behaviour: "caffeine", field: field(["mg", "g"]))?.unit, "mg")
        XCTAssertEqual(JournalSliderSpec.spec(behaviour: "sauna", field: field(["s", "min", "h"]))?.unit, "min")
        XCTAssertEqual(JournalSliderSpec.spec(behaviour: "cold_exposure", field: field(["s", "min", "h"]))?.range.upperBound, 30)
    }
}

final class JournalDraftTests: XCTestCase {
    private func field(_ type: String, minimum: Double? = nil, maximum: Double? = nil,
                       units: [String] = []) -> JournalFieldData {
        JournalFieldData(id: "answer", label: "Field", inputType: type, minimum: minimum, maximum: maximum,
                         units: units, ratingLabels: [])
    }

    private func draft(_ field: JournalFieldData, _ text: String, unit: String? = nil) -> JournalFieldDraft {
        var value = JournalFieldDraft(field: field, answer: nil)
        value.text = text
        if let unit { value.unit = unit }
        return value
    }

    func testRatingBoundsAndWholeNumbers() {
        let rating = field("rating", minimum: 1, maximum: 5)
        XCTAssertTrue(draft(rating, "5").valid(for: rating, units: []))
        XCTAssertFalse(draft(rating, "6").valid(for: rating, units: []))
        XCTAssertFalse(draft(rating, "2.5").valid(for: rating, units: []))
    }

    func testQuantityLimitsApplyAfterUnitConversion() {
        let quantity = field("quantity", minimum: 0, maximum: 1000, units: ["mg", "g"])
        XCTAssertTrue(draft(quantity, "1", unit: "g").valid(for: quantity, units: testCatalogue.units))
        XCTAssertFalse(draft(quantity, "2", unit: "g").valid(for: quantity, units: testCatalogue.units))
        XCTAssertTrue(draft(quantity, "2", unit: "mg").valid(for: quantity, units: testCatalogue.units))
    }

    func testDecimalCommaIsAccepted() {
        let quantity = field("quantity", minimum: 0, maximum: 1000, units: ["mg"])
        XCTAssertEqual(draft(quantity, "1,5", unit: "mg").answer(for: quantity)?.value, .number(1.5))
        XCTAssertEqual(draft(quantity, "1.5", unit: "mg").answer(for: quantity)?.value, .number(1.5))
        XCTAssertTrue(draft(quantity, "1,5", unit: "mg").valid(for: quantity, units: testCatalogue.units))
        XCTAssertNil(draft(quantity, "1,5,5", unit: "mg").answer(for: quantity))
    }

    func testTimeFormat() {
        let time = field("time")
        XCTAssertTrue(draft(time, "23:59").valid(for: time, units: []))
        XCTAssertFalse(draft(time, "24:00").valid(for: time, units: []))
        XCTAssertFalse(draft(time, "7:30").valid(for: time, units: []))
    }

    func testZeroAndNoAreAnswersButBlankIsNot() {
        let count = field("count", minimum: 0, maximum: 10)
        XCTAssertEqual(draft(count, "0").answer(for: count)?.value, .number(0))
        XCTAssertNil(draft(count, "").answer(for: count))
        let boolean = field("boolean")
        XCTAssertEqual(draft(boolean, "no").answer(for: boolean)?.value, .boolean(false))
        XCTAssertNil(draft(boolean, "").answer(for: boolean))
    }

    func testFreeTextLimit() {
        let text = field("text")
        XCTAssertTrue(draft(text, String(repeating: "a", count: 2000)).valid(for: text, units: []))
        XCTAssertFalse(draft(text, String(repeating: "a", count: 2001)).valid(for: text, units: []))
        XCTAssertNil(draft(text, "   ").answer(for: text))
    }
}

final class JournalCodingTests: XCTestCase {
    func testNewerComparesInstantsThenMutationIds() {
        XCTAssertTrue(JournalCoding.newer("2026-11-02T08:00:01Z", "a", than: "2026-11-02T08:00:00Z", "b"))
        XCTAssertTrue(JournalCoding.newer("2026-11-02T08:00:00.000Z", "b", than: "2026-11-02T08:00:00Z", "a"))
        XCTAssertFalse(JournalCoding.newer("2026-11-02T08:00:00Z", "a", than: "2026-11-02T08:00:00Z", "b"))
    }

    func testServerTimestampFormatsParse() {
        XCTAssertNotEqual(JournalCoding.instant("2026-10-28T12:00:00.123000+00:00"), .distantPast)
        XCTAssertNotEqual(JournalCoding.instant("2026-10-28T12:00:00+00:00"), .distantPast)
    }

    func testDayFollowsProfileTimezoneAcrossDST() {
        // 00:30 UTC on 25 Oct 2026 is still the previous evening in New York.
        let instant = JournalCoding.instant("2026-10-25T00:30:00Z")
        XCTAssertEqual(JournalCoding.day(instant, timezone: "America/New_York"), "2026-10-24")
        XCTAssertEqual(JournalCoding.day(instant, timezone: "Europe/London"), "2026-10-25")
    }

    func testSnakeCaseDetailKeysSurviveARoundTrip() throws {
        var value = response("caffeine", day: "2026-11-02", answer: .init(type: "boolean", value: .boolean(true)))
        value.details = ["last_use": .init(type: "time", value: .text("14:30"))]
        let data = try JournalCoding.encoder().encode(value)
        let decoded = try JournalCoding.decoder().decode(JournalResponseData.self, from: data)
        XCTAssertEqual(decoded.details["last_use"]?.value, .text("14:30"))
    }
}

@MainActor
final class FakeJournalServer {
    var requests: [URLRequest] = []
    var catalogue = testCatalogue
    var pageChanges: [[String: Any]] = []
    var pageCursor = 0
    var syncError: Error?
    var catalogueError: Error?
    var pullError: Error?
    var extraPageFields: [String: Any] = [:]

    var paths: [String] { requests.compactMap { $0.url?.path } }

    func handle(_ request: URLRequest) async throws -> Data {
        requests.append(request)
        let path = request.url?.path ?? ""
        if path.hasSuffix("/journal/catalogue") {
            if let catalogueError { throw catalogueError }
            return try JournalCoding.encoder().encode(catalogue)
        }
        if path.hasSuffix("/journal/changes") {
            if let pullError { throw pullError }
            var page: [String: Any] = ["changes": pageChanges, "cursor": pageCursor, "has_more": false,
                                       "timezone": "Europe/London", "today": "2026-11-02", "goals": [],
                                       "analysis_revision": 0]
            page.merge(extraPageFields) { $1 }
            pageChanges = []
            return try JSONSerialization.data(withJSONObject: page)
        }
        if let syncError { throw syncError }
        // Echoes every mutation as accepted, as the server does for winning edits.
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        let entries = (body["entries"] as? [[String: Any]] ?? []).map { $0.merging(["kind": "entry"]) { $1 } }
        let settings = (body["preferences"] as? [[String: Any]] ?? []).map { $0.merging(["kind": "preference"]) { $1 } }
        return try JSONSerialization.data(withJSONObject: ["acknowledgements": entries + settings])
    }
}

@MainActor
final class JournalStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("journal.json") }
    private let server = FakeJournalServer()
    private var stores: [JournalStore] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        stores.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> JournalStore {
        let server = server
        let store = JournalStore(authStore: AuthStore(), userID: "test", fileURL: fileURL,
                                 perform: { try await server.handle($0) })
        stores.append(store)
        return store
    }

    private func answer(_ id: String = "worked_late", value: Bool = true) -> JournalResponseData {
        response(id, day: "2026-11-02", answer: .init(type: "boolean", value: .boolean(value)))
    }

    func testFirstSyncDownloadsCatalogueAndTimezone() async {
        let store = makeStore()
        await store.synchronize()
        XCTAssertEqual(store.snapshot.catalogue?.version, 1)
        XCTAssertEqual(store.timezone, "Europe/London")
        XCTAssertNil(store.message)
    }

    func testSaveSurvivesRestartWhileOffline() async {
        let store = makeStore()
        await store.synchronize()
        server.pullError = URLError(.notConnectedToInternet)
        XCTAssertTrue(store.save(answer()))
        await store.synchronize()
        XCTAssertEqual(store.pendingCount, 1)
        XCTAssertNotNil(store.message)

        let restarted = makeStore()
        XCTAssertEqual(restarted.entry("worked_late", day: "2026-11-02")?.response?.answer?.value, .boolean(true))
        XCTAssertEqual(restarted.pendingCount, 1)
    }

    func testAcknowledgementClearsTheQueue() async {
        let store = makeStore()
        await store.synchronize()
        XCTAssertTrue(store.save(answer()))
        await store.synchronize()
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertNil(store.message)
        XCTAssertTrue(server.paths.contains { $0.hasSuffix("/journal/sync") })
    }

    func testDeleteKeepsATombstone() async {
        let store = makeStore()
        await store.synchronize()
        XCTAssertTrue(store.save(answer()))
        XCTAssertTrue(store.delete("worked_late", day: "2026-11-02"))
        XCTAssertNil(store.entry("worked_late", day: "2026-11-02"))
        XCTAssertEqual(store.snapshot.entries.filter(\.deleted).count, 1)
    }

    private func remoteChange(_ id: String, value: Bool, stamp: String, mutation: String, revision: Int) throws -> [String: Any] {
        let data = try JournalCoding.encoder().encode(JournalEntryWrite(entry(
            id, day: "2026-11-02", answer: .init(type: "boolean", value: .boolean(value)), stamp: stamp, mutation: mutation)))
        var change = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        change["kind"] = "entry"
        change["revision"] = revision
        return change
    }

    func testNewerRemoteEditWinsAndOlderRemoteEditLoses() async throws {
        let store = makeStore()
        await store.synchronize()
        XCTAssertTrue(store.save(answer(value: true)))
        server.syncError = URLError(.notConnectedToInternet)

        server.pageChanges = [try remoteChange("worked_late", value: false, stamp: "2020-01-01T00:00:00.000Z", mutation: "a", revision: 1)]
        server.pageCursor = 1
        await store.synchronize()
        XCTAssertEqual(store.entry("worked_late", day: "2026-11-02")?.response?.answer?.value, .boolean(true))

        server.pageChanges = [try remoteChange("worked_late", value: false, stamp: "2099-01-01T00:00:00.000Z", mutation: "b", revision: 2)]
        server.pageCursor = 2
        await store.synchronize()
        XCTAssertEqual(store.entry("worked_late", day: "2026-11-02")?.response?.answer?.value, .boolean(false))
        XCTAssertEqual(store.pendingCount, 0)
    }

    func testPrivateChangesStayOnDeviceAndDoNotBlockOthers() async {
        let store = makeStore()
        await store.synchronize()
        XCTAssertTrue(store.save(answer("caffeine")))
        XCTAssertTrue(store.save(answer("worked_late")))
        await store.synchronize()
        XCTAssertEqual(store.entry("worked_late", day: "2026-11-02")?.pending, false)
        XCTAssertEqual(store.entry("caffeine", day: "2026-11-02")?.pending, true)
        XCTAssertNotNil(store.message)
    }

    func testClockErrorIsActionableAndKeepsTheEntryQueued() async {
        let store = makeStore()
        await store.synchronize()
        XCTAssertTrue(store.save(answer()))
        server.syncError = HTTPResponseError(statusCode: 422, code: "clock_ahead")
        await store.synchronize()
        XCTAssertTrue(store.message?.contains("clock") == true)
        XCTAssertEqual(store.pendingCount, 1)

        server.syncError = nil
        await store.synchronize()
        XCTAssertNil(store.message)
        XCTAssertEqual(store.pendingCount, 0)
    }

    func testOtherFailuresKeepTheirMessages() {
        XCTAssertTrue(JournalStore.failureMessage(for: HTTPResponseError(statusCode: 422, code: nil)).contains("attention"))
        XCTAssertTrue(JournalStore.failureMessage(for: URLError(.notConnectedToInternet)).contains("offline"))
    }

    private func backdateFile() throws -> Date {
        let past = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: fileURL.path)
        return past
    }

    private func modified() throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
    }

    func testIdleSyncMakesOnePullAndLeavesTheFileAlone() async throws {
        let store = makeStore()
        await store.synchronize()
        let past = try backdateFile()
        server.requests = []
        await store.synchronize()
        XCTAssertEqual(server.paths.filter { $0.hasSuffix("/journal/changes") }.count, 1)
        XCTAssertEqual(server.paths.count, 1)
        XCTAssertEqual(try modified(), past)
    }

    func testProfileChangesAreStillPersisted() async throws {
        let store = makeStore()
        await store.synchronize()
        let past = try backdateFile()
        server.extraPageFields = ["timezone": "America/New_York"]
        await store.synchronize()
        XCTAssertEqual(store.timezone, "America/New_York")
        XCTAssertNotEqual(try modified(), past)
    }

    func testPushPullsAgainToAdvanceTheCursor() async {
        let store = makeStore()
        await store.synchronize()
        XCTAssertTrue(store.save(answer()))
        server.requests = []
        await store.synchronize()
        XCTAssertEqual(server.paths.filter { $0.hasSuffix("/journal/changes") }.count, 2)
        XCTAssertEqual(server.paths.filter { $0.hasSuffix("/journal/sync") }.count, 1)
    }

    func testNeedsRetryOnlyWhenThereIsSomethingToRetry() async {
        let store = makeStore()
        XCTAssertTrue(store.needsRetry)
        await store.synchronize()
        XCTAssertFalse(store.needsRetry)

        XCTAssertTrue(store.save(answer("caffeine")))
        await store.synchronize()
        XCTAssertFalse(store.needsRetry, "Private changes wait for category access, not the timer")

        XCTAssertTrue(store.save(answer()))
        XCTAssertTrue(store.needsRetry)
        server.pullError = URLError(.notConnectedToInternet)
        await store.synchronize()
        XCTAssertTrue(store.needsRetry)
        server.pullError = nil
        await store.synchronize()
        XCTAssertFalse(store.needsRetry)
    }

    private var catalogueRequests: [URLRequest] {
        server.requests.filter { $0.url?.path.hasSuffix("/journal/catalogue") == true }
    }

    func testNewerCatalogueIsDownloadedOnceAndKeepsAnswers() async {
        let store = makeStore()
        await store.synchronize()
        XCTAssertTrue(store.save(answer()))
        server.requests = []
        server.extraPageFields = ["catalogue_version": 2]
        server.catalogue = JournalCatalogueData(
            version: 2, schemaVersion: 1, categories: testCatalogue.categories,
            behaviours: testCatalogue.behaviours + [behaviour("hydration")], units: testCatalogue.units)
        await store.synchronize()
        XCTAssertEqual(store.snapshot.catalogue?.version, 2)
        XCTAssertTrue(store.snapshot.catalogue?.behaviours.contains { $0.id == "hydration" } == true)
        XCTAssertEqual(catalogueRequests.count, 1)
        XCTAssertEqual(catalogueRequests.first?.url?.query, "version=2")
        XCTAssertNotNil(store.entry("worked_late", day: "2026-11-02"))

        server.requests = []
        await store.synchronize()
        XCTAssertTrue(catalogueRequests.isEmpty)
    }

    func testMatchingOrMissingCatalogueVersionDoesNotDownload() async {
        let store = makeStore()
        await store.synchronize()
        server.requests = []
        server.extraPageFields = ["catalogue_version": 1]
        await store.synchronize()
        XCTAssertTrue(catalogueRequests.isEmpty)
    }

    func testCatalogueFailureKeepsTheCachedCatalogue() async {
        let store = makeStore()
        await store.synchronize()
        server.extraPageFields = ["catalogue_version": 2]
        server.catalogueError = URLError(.notConnectedToInternet)
        await store.synchronize()
        XCTAssertEqual(store.snapshot.catalogue?.version, 1)
        XCTAssertTrue(store.needsRetry)
    }

    func testTurningACategoryBackOnPinsEverythingAgain() async {
        let store = makeStore()
        await store.synchronize()
        store.setCategory("substances", enabled: true)
        let caffeine = testCatalogue.behaviours.first { $0.id == "caffeine" }!
        XCTAssertTrue(store.isPinned(caffeine))

        store.set("pin:caffeine", value: false)
        XCTAssertFalse(store.isPinned(caffeine))
        store.setCategory("substances", enabled: false)
        XCTAssertFalse(store.isPinned(caffeine))
        store.setCategory("substances", enabled: true)
        XCTAssertTrue(store.isPinned(caffeine))
    }

    func testRowAnswersSaveAndClear() async {
        let store = makeStore()
        await store.synchronize()
        let item = testCatalogue.behaviours.first { $0.id == "worked_late" }!
        XCTAssertTrue(store.answer(item, day: "2026-11-02", answer: .init(type: "boolean", value: .boolean(true))))
        XCTAssertEqual(store.entry("worked_late", day: "2026-11-02")?.response?.answer?.value, .boolean(true))
        XCTAssertTrue(store.delete("worked_late", day: "2026-11-02"))
        XCTAssertNil(store.entry("worked_late", day: "2026-11-02"))
    }

    func testCorruptFileIsPreservedAndBlocksWrites() async throws {
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: fileURL)
        let store = makeStore()
        XCTAssertTrue(store.storageBlocked)
        XCTAssertFalse(store.save(answer()))
        await store.synchronize()
        XCTAssertEqual(try Data(contentsOf: fileURL), corrupt)
    }
}
