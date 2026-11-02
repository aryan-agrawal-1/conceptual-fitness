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

final class JournalSuggestionTests: XCTestCase {
    private let day = "2026-11-02"

    func testSelectsExactlyFiveAndExcludesFreeText() {
        let ranked = JournalSuggestions.rank(snapshot(), day: day)
        XCTAssertEqual(ranked.count, 5)
        XCTAssertFalse(ranked.contains { $0.id == "daily_note" })
    }

    func testRankingIsStableForADateAndRotatesAcrossDates() {
        let first = JournalSuggestions.rank(snapshot(), day: day).map(\.id)
        XCTAssertEqual(first, JournalSuggestions.rank(snapshot(), day: day).map(\.id))
        let week = ["2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06"]
            .map { JournalSuggestions.rank(snapshot(), day: $0).map(\.id) }
        XCTAssertTrue(week.contains { $0 != first })
    }

    func testPinsRankFirstAndExplainThemselves() {
        let ranked = JournalSuggestions.rank(snapshot(settings: [setting("pin:sauna")]), day: day)
        XCTAssertEqual(ranked.first?.id, "sauna")
        XCTAssertTrue(ranked.first?.reasons.contains("Pinned by you") == true)
    }

    func testMoreThanFivePinsStillSelectsFive() {
        let pins = ["mood", "stress", "energy", "screen_in_bed", "worked_late", "travel", "sauna"]
        let ranked = JournalSuggestions.rank(snapshot(settings: pins.map { setting("pin:\($0)") }), day: day)
        XCTAssertEqual(ranked.count, 5)
        XCTAssertTrue(ranked.allSatisfy { pins.contains($0.id) })
    }

    func testProfileGoalsAddReason() {
        let ranked = JournalSuggestions.rank(snapshot(goals: ["Better mood"]), day: day)
        XCTAssertTrue(ranked.first { $0.id == "mood" }?.reasons.contains("Matches a Profile goal") == true)
    }

    private func suggestsCaffeine(_ value: JournalSnapshot) -> Bool {
        // Pinning guarantees selection whenever the input is eligible.
        var pinned = value
        pinned.preferences.append(setting("pin:caffeine"))
        return JournalSuggestions.rank(pinned, day: day).contains { $0.id == "caffeine" }
    }

    func testPrivateInputNeedsOptInAndDeliberateAnswer() {
        let answered = entry("caffeine", day: "2026-11-01")
        XCTAssertFalse(suggestsCaffeine(snapshot(entries: [answered])))
        XCTAssertFalse(suggestsCaffeine(snapshot(settings: [setting("opt_in:substances")])))
        XCTAssertTrue(suggestsCaffeine(snapshot(entries: [answered], settings: [setting("opt_in:substances")])))
    }

    func testExplicitNoCountsAsDeliberateButMissingAndDeletedDoNot() {
        let optIn = [setting("opt_in:substances")]
        let no = entry("caffeine", day: "2026-11-01", answer: .init(type: "boolean", value: .boolean(false)))
        XCTAssertTrue(suggestsCaffeine(snapshot(entries: [no], settings: optIn)))
        let skipped = entry("caffeine", day: "2026-11-01", answer: nil, missing: "skipped")
        XCTAssertFalse(suggestsCaffeine(snapshot(entries: [skipped], settings: optIn)))
        let deleted = entry("caffeine", day: "2026-11-01", deleted: true)
        XCTAssertFalse(suggestsCaffeine(snapshot(entries: [deleted], settings: optIn)))
    }

    func testPrivateUseAfterTheSelectedDateDoesNotCount() {
        let later = entry("caffeine", day: "2026-11-03")
        XCTAssertFalse(suggestsCaffeine(snapshot(entries: [later], settings: [setting("opt_in:substances")])))
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
    var pullError: Error?
    var extraPageFields: [String: Any] = [:]

    var paths: [String] { requests.compactMap { $0.url?.path } }

    func handle(_ request: URLRequest) async throws -> Data {
        requests.append(request)
        let path = request.url?.path ?? ""
        if path.hasSuffix("/journal/catalogue") {
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
