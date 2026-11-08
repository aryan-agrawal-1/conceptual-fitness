import XCTest
@testable import ConceptualFitness

@MainActor
final class PatternsTests: XCTestCase {
    private func impact(_ percent: Double, benefit: String = "hurts", better: Int = -1) -> String {
        #"{"percent": \#(percent), "low": \#(percent - 1), "high": \#(percent + 1), "caption": "3+ units", "benefit": "\#(benefit)", "better": \#(better)}"#
    }

    private func finding(_ pair: String, state: String, unseen: Bool = false, neverLogged: Bool = false,
                         group: String = "recovery", short: String = "Resting HR", impact: String = "null") -> String {
        """
        {"pair_id": "\(pair)", "stratum": "all", "outcome_id": "rhr", "outcome_label": "Overnight resting heart rate",
         "outcome_short_label": "\(short)", "group": "\(group)", "impact": \(impact),
         "tier": "main", "state": "\(state)", "state_label": "Label", "held_reason": null,
         "summary": "Overnight resting heart rate was about 2.9 bpm higher after 3 or more units than on days without alcohol.",
         "effects": [{"term": "units_3_plus", "value": 2.9, "low": 2.2, "high": 3.6, "unit": "bpm", "per": "",
                      "text": "Overnight resting heart rate was about 2.9 bpm higher.", "range_text": "Likely range +2.2 to +3.6 bpm."}],
         "needs": null,
         "sample": {"exposed_days": 20, "comparison_days": 24, "exposed_label": "days with alcohol",
                    "comparison_label": "days without", "excluded": [{"reason": "sick_day", "text": "sick days", "days": 2}]},
         "window": {"start": "2026-08-03", "end": "2026-10-31"},
         "adjustments": ["the two days before"], "limitations": ["This is an association in your own data."],
         "unseen": \(unseen), "never_logged": \(neverLogged)}
        """
    }

    private func story(_ input: String, state: String, findings: [String], unseen: Bool = false,
                       neverLogged: Bool = false, safetyNote: String = "null") -> String {
        """
        {"id": "\(input):all", "input_id": "\(input)", "stratum": "all", "title": "\(input.capitalized)",
         "tier": "main", "state": "\(state)", "state_label": "Label", "headline": "Headline",
         "findings": [\(findings.joined(separator: ","))], "unseen": \(unseen), "never_logged": \(neverLogged),
         "safety_note": \(safetyNote)}
        """
    }

    private func payload(_ stories: [String], newFindings: Int = 0) -> Data {
        Data("""
        {"status": "ready", "new_findings": \(newFindings),
         "run": {"id": "run", "algorithm_version": "behaviour_engine_v2", "map_version": "behaviour_map_v1",
                 "presentation_version": "behaviour_presentation_v1", "window_start": "2026-08-03",
                 "window_end": "2026-10-31", "tracking_day": 45, "checkpoint_day": 30, "next_checkpoint_day": 60,
                 "completed_at": "2026-11-01T03:00:00Z", "current": true, "last_attempt_failed": false},
         "stories": [\(stories.joined(separator: ","))]}
        """.utf8)
    }

    private var sample: Data {
        payload([
            story("alcohol", state: "possible", findings: [finding("alcohol:rhr:d1", state: "possible", unseen: true,
                                                                    impact: impact(5.3))],
                  unseen: true),
            story("caffeine", state: "neutral", findings: [finding("caffeine:rhr:d1", state: "neutral")]),
            story("sauna", state: "collecting", findings: [finding("sauna:rhr:d1", state: "collecting")]),
            story("nicotine", state: "collecting", findings: [finding("nicotine:rhr:d1", state: "collecting",
                                                                      neverLogged: true)], neverLogged: true),
        ], newFindings: 1)
    }

    func testPayloadDecodesIntoFindingsCheckedWaitingAndNotLogged() throws {
        let response = try JournalCoding.decoder().decode(PatternsResponse.self, from: sample)
        XCTAssertEqual(response.run?.nextCheckpointDay, 60)
        XCTAssertEqual(response.stories[0].findings[0].effects[0].rangeText, "Likely range +2.2 to +3.6 bpm.")
        let sections = PatternSections(response.stories)
        XCTAssertEqual(sections.findings.map(\.inputId), ["alcohol"])
        XCTAssertEqual(sections.checked.map(\.inputId), ["caffeine"])
        XCTAssertEqual(sections.waiting.map(\.inputId), ["sauna"])
        XCTAssertEqual(sections.notLogged.map(\.inputId), ["nicotine"])
    }

    func testSafetyNotesDecodeAndStayOptional() throws {
        let note = "This is an observation from your own logs, not medical advice."
        let data = Data("""
        {"status": "not_started", "run": null, "stories": [], "new_findings": 0,
         "general_note": "Patterns are observations from your own data, not medical advice."}
        """.utf8)
        let empty = try JournalCoding.decoder().decode(PatternsResponse.self, from: data)
        XCTAssertEqual(empty.generalNote, "Patterns are observations from your own data, not medical advice.")
        let response = try JournalCoding.decoder().decode(PatternsResponse.self, from: payload([
            story("usual_medication", state: "possible", findings: [finding("usual_medication:rhr:d1", state: "possible")],
                  safetyNote: "\"\(note)\""),
            story("sauna", state: "collecting", findings: [finding("sauna:rhr:d1", state: "collecting")]),
        ]))
        XCTAssertEqual(response.stories[0].safetyNote, note)
        XCTAssertNil(response.stories[1].safetyNote)
        XCTAssertNil(response.generalNote)
    }

    func testEveryBackendStateDecodes() throws {
        for state in ["consistent", "possible", "early_signal", "inconclusive", "neutral", "overlapping",
                      "insufficient_variation", "collecting", "held"] {
            let data = payload([story("x", state: state, findings: [finding("x:rhr:d1", state: state)])])
            XCTAssertNoThrow(try JournalCoding.decoder().decode(PatternsResponse.self, from: data), state)
        }
    }

    func testFailedRefreshKeepsTheLastResults() async {
        var fail = false
        let good = sample
        let store = PatternsStore(authStore: AuthStore()) { _ in
            if fail { throw HTTPResponseError(statusCode: 503, code: nil) }
            return good
        }
        await store.load()
        XCTAssertEqual(store.phase, .loaded)
        fail = true
        await store.load()
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertTrue(store.refreshFailed)
        XCTAssertEqual(store.response?.stories.count, 4)
    }

    func testFirstLoadFailureShowsTheErrorState() async {
        let store = PatternsStore(authStore: AuthStore()) { _ in throw URLError(.notConnectedToInternet) }
        await store.load()
        XCTAssertEqual(store.phase, .failed)
        XCTAssertNil(store.response)
    }

    func testSeeingAFindingReportsItOnceAndClearsTheBanner() async throws {
        var posted: [Data] = []
        let good = sample
        let store = PatternsStore(authStore: AuthStore()) { request in
            if request.httpMethod == "POST" {
                posted.append(request.httpBody ?? Data())
                return Data(#"{"recorded": 1}"#.utf8)
            }
            return good
        }
        await store.load()
        XCTAssertEqual(store.newFindings, 1)
        let alcohol = try XCTUnwrap(store.response?.stories.first)
        await store.markSeen(alcohol)
        await store.markSeen(alcohol)
        XCTAssertEqual(posted.count, 1)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: posted[0]) as? [String: [[String: String]]])
        XCTAssertEqual(body, ["patterns": [["pair_id": "alcohol:rhr:d1", "stratum": "all"]]])
        XCTAssertEqual(store.newFindings, 0)
    }

    func testFailedSeenReportIsRetriedLater() async throws {
        var attempts = 0
        let good = sample
        let store = PatternsStore(authStore: AuthStore()) { request in
            guard request.httpMethod == "POST" else { return good }
            attempts += 1
            if attempts == 1 { throw URLError(.timedOut) }
            return Data(#"{"recorded": 1}"#.utf8)
        }
        await store.load()
        let alcohol = try XCTUnwrap(store.response?.stories.first)
        await store.markSeen(alcohol)
        XCTAssertEqual(store.newFindings, 1)
        await store.markSeen(alcohol)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(store.newFindings, 0)
    }

    func testBoardsGroupFindingsByInputAndSortHelpsAboveHurts() throws {
        let data = payload([
            story("alcohol", state: "possible", findings: [
                finding("alcohol:rhr:d1", state: "possible", impact: impact(5.3)),
                finding("alcohol:hrv:d1", state: "possible", short: "HRV", impact: impact(-14.6, better: 1)),
                finding("alcohol:sleep:d1", state: "neutral", group: "sleep", short: "Sleep",
                        impact: impact(0.3, benefit: "none", better: 1)),
            ]),
            story("steps", state: "early_signal", findings: [
                finding("steps:hrv:d1", state: "early_signal", short: "HRV", impact: impact(6, benefit: "helps", better: 1)),
            ]),
            story("caffeine", state: "inconclusive", findings: [finding("caffeine:rhr:d1", state: "inconclusive")]),
        ])
        let stories = try JournalCoding.decoder().decode(PatternsResponse.self, from: data).stories
        let recovery = PatternBoard(stories, group: .recovery)
        XCTAssertEqual(recovery.cards.map(\.story.inputId), ["steps", "alcohol"])
        XCTAssertEqual(recovery.cards[1].rows.map(\.finding.outcomeShortLabel), ["Resting HR", "HRV"])
        XCTAssertEqual(recovery.cards[1].lead.finding.outcomeShortLabel, "HRV")
        XCTAssertEqual(recovery.cards[1].subtitle, "3+ units · Possible")
        XCTAssertEqual(recovery.reach, 20)
        let sleep = PatternBoard(stories, group: .sleep)
        XCTAssertTrue(sleep.cards.isEmpty)
        XCTAssertEqual(sleep.neutral.map(\.story.inputId), ["alcohol"])
        XCTAssertEqual(PatternBoard.preferredGroup(stories), .recovery)
    }

    func testImpactTextAndDirection() throws {
        let data = Data(impact(-14.6, better: 1).utf8)
        let hurts = try JournalCoding.decoder().decode(PatternImpact.self, from: data)
        XCTAssertEqual(hurts.percentText, "−15%")
        XCTAssertFalse(hurts.helps)
        XCTAssertEqual(hurts.scaled(hurts.percent), -14.6)
        let heart = try JournalCoding.decoder().decode(PatternImpact.self, from: Data(impact(5.3).utf8))
        XCTAssertEqual(heart.scaled(heart.percent), -5.3)
        let tiny = try JournalCoding.decoder().decode(PatternImpact.self, from: Data(impact(0.4, benefit: "helps", better: 1).utf8))
        XCTAssertEqual(tiny.percentText, "+<1%")
    }

    func testUpdatedLabelSaysWhenResultsWereLastWorkedOut() {
        let today = ISO8601DateFormatter().date(from: "2026-11-08T12:00:00Z")!
        XCTAssertEqual(PatternDates.updated("2026-11-08T03:00:00Z", today: today), "Updated today")
        XCTAssertEqual(PatternDates.updated("2026-11-07T03:00:00Z", today: today), "Updated yesterday")
        XCTAssertEqual(PatternDates.updated("2026-11-01T03:00:00Z", today: today), "Updated \(PatternDates.display("2026-11-01"))")
        XCTAssertEqual(PatternDates.updated(nil, today: today), "Not updated yet")
    }
}
