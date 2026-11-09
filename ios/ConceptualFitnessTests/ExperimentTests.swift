import XCTest
@testable import ConceptualFitness

@MainActor
final class ExperimentTests: XCTestCase {
    private func day(_ date: String, number: Int, kind: String, washout: Bool = false) -> String {
        let plan = kind == "change" ? "Change week: no alcohol" : "Usual week: do what you normally do"
        return #"{"date": "\#(date)", "day_number": \#(number), "week": \#((number - 1) / 7 + 1), "kind": "\#(kind)", "washout": \#(washout), "plan": "\#(plan)"}"#
    }

    private func experiment(status: String = "active", today: String? = nil, result: String = "null",
                            offTrack: String = "null") -> Data {
        let days = [day("2026-11-02", number: 1, kind: "change", washout: true),
                    day("2026-11-09", number: 8, kind: "usual", washout: true)]
        return Data("""
        {"experiment": {"id": "exp", "behaviour_id": "alcohol_free", "input_id": "alcohol", "pair_id": "alcohol:rhr:d1",
         "stratum": "all", "outcome_id": "rhr", "outcome_label": "Overnight resting heart rate",
         "title": "Alcohol-free weeks", "change_text": "Change week: no alcohol",
         "usual_text": "Usual week: do what you normally do", "status": "\(status)",
         "start_date": "2026-11-02", "end_date": "2026-11-29", "result_date": "2026-12-01",
         "started_at": "2026-11-01T10:00:00Z", "stopped_at": null, "completed_at": null,
         "today": \(today ?? "null"), "days": [\(days.joined(separator: ","))],
         "adherence": {"change_days": 3, "logged_days": 3, "followed_days": 2}, "result": \(result),
         "off_track": \(offTrack)}}
        """.utf8)
    }

    private var readyResult: String {
        #"{"status": "ready", "change_days": 10, "usual_days": 9, "minimum_days": 6, "difference": -5.0, "unit": "bpm", "benefit": "helps", "summary": "Overnight resting heart rate was about 5 bpm lower in change weeks than in usual weeks.", "adherence_text": "You logged sticking to the change on 12 of the 14 days in change weeks.", "notes": ["This is one person's result over a short period."]}"#
    }

    private func decodeFinding(testable: String = #", "testable": true"#) throws -> PatternFinding {
            let json = """
            {"pair_id": "alcohol:rhr:d1", "stratum": "all", "outcome_id": "rhr", "outcome_label": "Overnight resting heart rate",
             "outcome_short_label": "Resting HR", "group": "recovery", "impact": null, "tier": "main", "state": "possible",
             "state_label": "Possible", "summary": "Summary", "effects": [], "needs": null,
             "sample": {"exposed_days": 20, "comparison_days": 24, "exposed_label": "days with alcohol",
                        "comparison_label": "days without", "excluded": []},
             "window": {"start": "2026-08-03", "end": "2026-10-31"}, "adjustments": [], "limitations": [],
             "unseen": false, "never_logged": false\(testable)}
            """
            return try JournalCoding.decoder().decode(PatternFinding.self, from: Data(json.utf8))
    }

    private var finding: PatternFinding {
        get throws { try decodeFinding() }
    }

    func testExperimentDecodesWithPlansForEachDay() throws {
        let today = day("2026-11-02", number: 1, kind: "change", washout: true)
        let response = try JournalCoding.decoder().decode(ExperimentResponse.self, from: experiment(today: today))
        let decoded = try XCTUnwrap(response.experiment)
        XCTAssertEqual(decoded.statusText, "Day 1 of 2")
        XCTAssertEqual(decoded.plan(on: "2026-11-02")?.plan, "Change week: no alcohol")
        XCTAssertEqual(decoded.plan(on: "2026-11-09")?.isChange, false)
        XCTAssertNil(decoded.plan(on: "2026-12-25"))
    }

    func testEndedExperimentHasNoPlanAndKeepsItsResult() throws {
        let response = try JournalCoding.decoder().decode(ExperimentResponse.self,
                                                          from: experiment(status: "completed", result: readyResult))
        let decoded = try XCTUnwrap(response.experiment)
        XCTAssertNil(decoded.plan(on: "2026-11-02"))
        XCTAssertEqual(decoded.statusText, "Finished")
        XCTAssertEqual(decoded.result?.isReady, true)
    }

    func testTooFewDaysResultIsNotReady() throws {
        let tooFew = #"{"status": "too_few_days", "change_days": 2, "usual_days": 1, "minimum_days": 6, "difference": null, "unit": "bpm", "benefit": null, "summary": "Not enough days to compare.", "adherence_text": null, "notes": []}"#
        let response = try JournalCoding.decoder().decode(ExperimentResponse.self,
                                                          from: experiment(status: "stopped", result: tooFew))
        XCTAssertEqual(response.experiment?.result?.isReady, false)
    }

    func testSetupDecodesTheUsualWeekAndChanges() throws {
        let json = """
        {"setup": {"pair_id": "alcohol:rhr:d1", "stratum": "all", "input_id": "alcohol",
         "outcome_label": "Overnight resting heart rate",
         "usual": {"logged_days": 28, "used_days": 14, "typical_units": 4.0, "typical_last_use": null,
                   "lines": ["You drank on about 4 days a week.", "Usually about 4 units on those days."],
                   "basis": "Based on the 28 days you logged in the last 4 weeks."},
         "options": [{"id": "alcohol_free", "title": "No alcohol", "change_text": "Change week: no alcohol",
                      "detail": "No alcohol all week."},
                     {"id": "alcohol_week_4", "title": "Up to 4 units a week",
                      "change_text": "Change week: no more than 4 units of alcohol this week",
                      "detail": "Up to 4 units in total across the week."}],
         "start_date": "2026-11-10", "end_date": "2026-12-07", "result_date": "2026-12-09", "weeks": 4,
         "washout_days": 2, "safety_note": "Not advice."}}
        """
        let setup = try JournalCoding.decoder().decode(ExperimentSetupResponse.self, from: Data(json.utf8)).setup
        XCTAssertEqual(setup.usual.lines.count, 2)
        XCTAssertEqual(setup.options.map(\.id), ["alcohol_free", "alcohol_week_4"])
        XCTAssertEqual(setup.weeks, 4)
        XCTAssertEqual(setup.safetyNote, "Not advice.")
    }

    func testOffTrackExperimentHasNoPlanAndExplainsWhy() throws {
        let offTrack = #"{"date": "2026-11-04", "summary": "In a change week, you logged alcohol, so this experiment has ended.", "restart_text": "You can restart it."}"#
        let response = try JournalCoding.decoder().decode(ExperimentResponse.self,
                                                          from: experiment(status: "off_track", offTrack: offTrack))
        let decoded = try XCTUnwrap(response.experiment)
        XCTAssertTrue(decoded.isOffTrack)
        XCTAssertFalse(decoded.isActive)
        XCTAssertEqual(decoded.statusText, "Off track")
        XCTAssertNil(decoded.plan(on: "2026-11-02"))
        XCTAssertEqual(decoded.offTrack?.summary, "In a change week, you logged alcohol, so this experiment has ended.")
        let plain = try JournalCoding.decoder().decode(ExperimentResponse.self, from: experiment())
        XCTAssertNil(plain.experiment?.offTrack)
    }

    func testStartSendsTheChosenChangeAndRestartUsesItsOwnEndpoint() async throws {
        var bodies: [String] = []
        var paths: [String] = []
        let started = experiment()
        let store = ExperimentStore(authStore: AuthStore()) { request in
            paths.append(request.url?.path ?? "")
            bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            return started
        }
        let didStart = await store.start(try finding, change: "alcohol_week_4")
        XCTAssertTrue(didStart)
        XCTAssertTrue(bodies[0].contains(#""behaviour_id":"alcohol_week_4""#))
        let didRestart = await store.restart()
        XCTAssertTrue(didRestart)
        XCTAssertTrue(paths[1].hasSuffix("insights/experiment/restart"))
        XCTAssertEqual(ExperimentStore.message(nil, name: "restart"),
                       "Couldn’t restart the experiment. Check your connection and try again.")
    }

    func testFindingsWithoutTheFlagAreNotTestable() throws {
        XCTAssertEqual(try finding.testable, true)
        XCTAssertNil(try decodeFinding(testable: "").testable)
    }

    func testLoadStartAndStop() async throws {
        let started = experiment(today: nil)
        let stopped = experiment(status: "stopped", result: readyResult)
        var bodies: [String] = []
        let store = ExperimentStore(authStore: AuthStore()) { request in
            if request.url?.path.hasSuffix("stop") == true { return stopped }
            if request.httpMethod == "POST" {
                bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
                return started
            }
            return Data(#"{"experiment": null}"#.utf8)
        }
        await store.load()
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertNil(store.experiment)
        let didStart = await store.start(try finding)
        XCTAssertTrue(didStart)
        XCTAssertEqual(store.active?.id, "exp")
        XCTAssertTrue(bodies[0].contains(#""pair_id":"alcohol:rhr:d1""#))
        let didStop = await store.stop()
        XCTAssertTrue(didStop)
        XCTAssertNil(store.active)
        XCTAssertEqual(store.experiment?.status, "stopped")
    }

    func testFailedStartShowsAReasonAndAllowsRetry() async throws {
        var fail = true
        let started = experiment()
        let store = ExperimentStore(authStore: AuthStore()) { request in
            if request.httpMethod == "POST" {
                if fail { throw HTTPResponseError(statusCode: 409, code: "not_testable") }
                return started
            }
            return Data(#"{"experiment": null}"#.utf8)
        }
        let first = await store.start(try finding)
        XCTAssertFalse(first)
        XCTAssertEqual(store.action, .failed(ExperimentStore.message("not_testable", name: "start")))
        fail = false
        let second = await store.start(try finding)
        XCTAssertTrue(second)
        XCTAssertEqual(store.action, .idle)
    }

    func testFirstLoadFailureShowsTheErrorState() async {
        let store = ExperimentStore(authStore: AuthStore()) { _ in throw URLError(.notConnectedToInternet) }
        await store.load()
        XCTAssertEqual(store.phase, .failed)
        XCTAssertNil(store.experiment)
    }

    func testPinRemovesTheBehaviourFromOtherSections() throws {
        let behaviour = try JournalCoding.decoder().decode(JournalBehaviourData.self, from: Data("""
        {"id": "alcohol", "category_id": "substances", "label": "Alcohol", "question": "Did you drink alcohol?",
         "answer": {"id": "answer", "label": "Alcohol", "input_type": "boolean", "minimum": null, "maximum": null,
                    "units": [], "rating_labels": []},
         "details": [], "presentation": "discreet", "discreet_label": "Substances", "statistical_input": true}
        """.utf8))
        let screen = JournalCheckInScreen(pinned: [], privatePinned: [.init(id: "substances", title: "Substances",
                                                                           behaviours: [behaviour])], topUp: [behaviour])
        let pinned = ExperimentPin.screen(screen, removing: "alcohol")
        XCTAssertTrue(pinned.privatePinned.isEmpty)
        XCTAssertTrue(pinned.topUp.isEmpty)
    }
}
