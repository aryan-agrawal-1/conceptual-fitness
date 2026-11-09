from __future__ import annotations

import re
from datetime import UTC, date, datetime
from types import SimpleNamespace

from app.services.behaviour_analysis import PairResult, capped_after_seen
from app.services.behaviour_map import Pair
from app.services.behaviour_presentation import present


RUN = SimpleNamespace(window_start=date(2026, 8, 3), window_end=date(2026, 10, 31), tracking_day=45)
CAUSAL = re.compile(r"\b(caus|because of|leads? to|improv|worsen|harm|boost|makes?)\w*", re.IGNORECASE)


def estimate(term, value, error, prior=10.0, **extra):
    return dict(term=term, estimate=value, standard_error=error, interval=[value - 2 * error, value + 2 * error],
                shrunk=value * prior ** 2 / (prior ** 2 + error ** 2), prior_sd=prior, unit="min", **extra)


def row(input_id="nicotine", outcome_id="sleep_minutes", stage="preliminary", **fields):
    values = dict(
        pair_id=f"{input_id}:{outcome_id}:d1", input_id=input_id, outcome_id=outcome_id, lag_days=1,
        tier="exploratory", stratum="all", stage=stage, suppression_reason=None, held_reason=None,
        coding="binary", exposed_days=12, comparison_days=40, estimates=[estimate("yes", -25.0, 6.0)],
        labels=[], included_dates=["2026-10-01"] * 52, excluded_days=[{"reason": "sick_day", "date": "x"}],
        checks=dict(model=dict(columns=["intercept", "yes", "recent", "drift", "journal_weekend_night"])),
    )
    values.update(fields)
    return SimpleNamespace(**values)


def finding(item, views=None, hidden=frozenset()):
    return present([item], RUN, views or {}, hidden)["stories"][0]["findings"][0]


def test_early_signal_reads_as_an_association_with_a_shrunk_range():
    result = finding(row())
    assert result["state"] == "early_signal" and result["state_label"] == "Early signal"
    assert result["summary"] == "Sleep was about 18 min shorter after days with nicotine than days without."
    assert result["effects"][0]["low"] < result["effects"][0]["value"] < result["effects"][0]["high"] < 0
    assert "the two days before" in result["adjustments"] and "sick days left out" in result["adjustments"]
    assert any(text.startswith("Exploratory") for text in result["limitations"])
    assert result["needs"] == "A firmer result needs more days of data."
    assert result["unseen"] is True
    worked_late = finding(row(input_id="worked_late"))
    assert worked_late["needs"] == "A firmer result needs at least 18 days on each side (6 more on the smaller side)."


def test_no_finding_text_uses_causal_wording():
    items = [
        row(), row(stage="possible", exposed_days=30), row(stage="consistent", exposed_days=30),
        row(stage="no_link", estimates=[estimate("yes", 1.0, 2.0)]),
        row(stage="no_link", estimates=[estimate("yes", 10.0, 20.0)]),
        row(stage="counts", suppression_reason="exposure_days_below_minimum", exposed_days=4),
        row(input_id="caffeine", coding="dose", estimates=[estimate("mg", -0.2, 0.05, prior=1.0),
                                                           estimate("hours_before_bed", 4.0, 1.5)]),
    ]
    for item in items:
        result = finding(item)
        texts = [result["summary"], result["needs"] or "",
                 *(effect["text"] or "" for effect in result["effects"])]
        assert not any(CAUSAL.search(text) for text in texts), texts


def test_no_link_is_neutral_only_when_the_whole_range_is_inside_the_band():
    neutral = finding(row(stage="no_link", estimates=[estimate("yes", 1.0, 2.0)]))
    assert neutral["state"] == "neutral"
    assert neutral["summary"] == "No link larger than 15 min was seen between nicotine and sleep."
    unclear = finding(row(stage="no_link", estimates=[estimate("yes", 10.0, 20.0)]))
    assert unclear["state"] == "inconclusive"
    assert unclear["needs"] == "More days would narrow the range."
    other = finding(row(input_id="travel", stage="no_link", estimates=[estimate("yes", 10.0, 20.0)]))
    assert other["needs"] == "More days on both sides would narrow the range."


def test_dose_effects_use_a_readable_step_and_flag_unclear_shape():
    result = finding(row(input_id="caffeine", coding="dose", tier="main",
                         estimates=[estimate("mg", -0.2, 0.05, prior=1.0)]))
    assert result["summary"].endswith("shorter per 100 mg of caffeine.")
    assert "Stronger at higher amounts is assumed; the exact shape is unclear." in result["limitations"]


def favourable_alcohol(review):
    checks = dict(model=dict(columns=["intercept", "units_3_plus", "journal_weekend_night"]))
    if review is not None:
        checks["favourable_review"] = review
    return row(input_id="alcohol", coding="alcohol_bands", labels=["favourable_needs_review"],
               estimates=[estimate("units_3_plus", 30.0, 6.0)], checks=checks)


def test_beneficial_looking_alcohol_results_are_held_without_numbers_until_checked():
    result = finding(favourable_alcohol(None))
    assert (result["state"], result["held_reason"]) == ("held", "favourable_checks_failed")
    assert result["effects"] == [] and result["impact"] is None and "30" not in result["summary"]
    assert result["summary"] == "This result is not shown because the checks could not be run on your data yet."
    failed = finding(favourable_alcohol(dict(passed=False, failed=["before_exposure", "sick_days"])))
    assert failed["state"] == "held" and failed["effects"] == []
    assert failed["summary"] == ("This result is not shown because the difference was already there before you "
                                 "drank and it changed when sick days were counted.")
    worse = finding(row(input_id="alcohol", coding="alcohol_bands", labels=["favourable_needs_review"],
                        estimates=[estimate("units_3_plus", -30.0, 6.0)]))
    assert worse["state"] == "early_signal"
    assert "after 3 or more units than on days without alcohol" in worse["summary"]


def test_beneficial_looking_alcohol_that_passes_the_checks_is_shown_with_the_reviewed_wording():
    story = present([favourable_alcohol(dict(passed=True, failed=[], weekend_adjusted=True))],
                    RUN, {}, frozenset())["stories"][0]
    result = story["findings"][0]
    assert result["state"] == "early_signal" and result["effects"]
    assert any(text.startswith("People often drink on days that are already going well") for text in
               result["limitations"])
    assert story["safety_note"] == "This is an observation from your own logs, not medical advice."


def test_held_results_show_no_numbers():
    result = finding(row(input_id="usual_medication", held_reason="awaiting_review"))
    assert result["state"] == "held" and result["effects"] == [] and result["unseen"] is False
    assert result["summary"] == "This result is not shown yet."


def test_medication_results_are_shown_with_wording_that_never_suggests_changing_treatment():
    taken = row(input_id="usual_medication", estimates=[estimate("yes", 25.0, 6.0, outcome_mean=420.0)])
    story = present([taken], RUN, {}, frozenset())["stories"][0]
    result = story["findings"][0]
    assert result["state"] == "early_signal" and result["effects"]
    assert result["impact"]["benefit"] == "unrated"
    assert "Do not start, stop or change a medication or supplement" in story["safety_note"]
    assert "Only whether you took it is recorded, not what it was or how much." in result["limitations"]
    flat = finding(row(input_id="supplements", stage="suppressed", suppression_reason="insufficient_variation",
                       estimates=[]))
    assert flat["needs"] == "Your answers barely changed, so there is nothing to compare yet."
    short = finding(row(input_id="usual_medication", stage="counts",
                        suppression_reason="exposure_days_below_minimum", exposed_days=3, estimates=[]))
    assert "without" not in short["needs"] and "more days with your usual medication" not in short["needs"]


def test_every_sensitive_category_gets_a_fixed_note_and_others_get_none():
    notes = {input_id: present([row(input_id=input_id)], RUN, {}, frozenset())["stories"][0]["safety_note"]
             for input_id in ("headache", "mood", "menstrual_cramps", "cannabis", "supplements", "worked_late")}
    assert notes["headache"].endswith("If you feel seriously unwell, contact a doctor or emergency services.")
    assert "not a mental health assessment" in notes["mood"]
    assert "Cycle-related changes" in notes["menstrual_cramps"]
    assert notes["cannabis"] == "This is an observation from your own logs, not medical advice."
    assert "pharmacist" in notes["supplements"]
    assert notes["worked_late"] is None
    assert all(note.startswith("This is an observation from your own logs, not medical advice.")
               for note in notes.values() if note)
    mood_link = present([row(input_id="screen_in_bed", outcome_id="mood_next",
                             estimates=[estimate("yes", -0.8, 0.2, prior=1.0)])], RUN, {}, frozenset())
    assert "not a mental health assessment" in mood_link["stories"][0]["safety_note"]
    assert mood_link["general_note"] == "Patterns are observations from your own data, not medical advice."


def test_sensitive_text_never_recommends_starting_stopping_or_changing():
    advice = re.compile(r"\b(try|consider|should|skip|stop taking|start taking|take more|take less|"
                        r"cut down|increase|reduce)\b", re.IGNORECASE)
    states = [dict(), dict(stage="possible", exposed_days=30), dict(stage="no_link", estimates=[estimate("yes", 10.0, 20.0)]),
              dict(stage="counts", suppression_reason="exposure_days_below_minimum", exposed_days=3, estimates=[]),
              dict(stage="suppressed", suppression_reason="insufficient_variation", estimates=[]),
              dict(stage="suppressed", suppression_reason="overlaps_with:caffeine", estimates=[])]
    for input_id in ("usual_medication", "supplements", "pain", "fever", "mood", "menstrual_bleeding",
                     "nicotine", "alcohol"):
        for fields in states:
            story = present([row(input_id=input_id, **fields)], RUN, {}, frozenset())["stories"][0]
            texts = [story["safety_note"] or "", *(item["summary"] for item in story["findings"]),
                     *(item["needs"] or "" for item in story["findings"])]
            assert not any(advice.search(text) for text in texts), (input_id, fields, texts)


def test_collecting_states_say_what_is_needed():
    short = finding(row(input_id="worked_late", stage="counts", suppression_reason="exposure_days_below_minimum",
                        exposed_days=4, comparison_days=8, estimates=[]))
    assert short["state"] == "collecting"
    assert short["needs"] == "Needs 6 more days you worked late and 2 more other days, each with sleep data."
    never = finding(row(stage="counts", suppression_reason="outcome_days_below_minimum", estimates=[],
                        exposed_days=0, comparison_days=0, included_dates=[],
                        excluded_days=[{"reason": "input_not_answered", "date": "x"}]))
    assert never["needs"] == "Log nicotine in your journal to start comparing it with sleep."
    assert never["never_logged"] is True
    waiting = finding(row(stage="awaiting_checkpoint"))
    assert waiting["needs"] == "Your first result for this appears at the day 60 check."


def test_overlap_and_variation_states_never_name_turned_off_inputs():
    overlapping = finding(row(stage="suppressed", suppression_reason="overlaps_with:cannabis,worked_late",
                              estimates=[]), hidden={"cannabis"})
    assert overlapping["state"] == "overlapping"
    assert "cannabis" not in overlapping["summary"] and "worked late" in overlapping["summary"]
    assert "another input" in overlapping["summary"]
    flat = finding(row(stage="suppressed", suppression_reason="insufficient_variation", estimates=[]))
    assert flat["state"] == "insufficient_variation" and flat["effects"] == []


def test_one_story_per_input_led_by_its_strongest_state_with_readiness_explained():
    items = [row(outcome_id="readiness", stage="no_link", estimates=[estimate("yes", 1.0, 1.0)]),
             row(outcome_id="sleep_minutes", stage="no_link", estimates=[estimate("yes", 1.0, 1.0)]),
             row(outcome_id="hrv", stage="possible", exposed_days=30, estimates=[estimate("yes", -6.0, 1.5)]),
             row(input_id="sauna", stage="counts", estimates=[])]
    stories = present(items, RUN, {}, frozenset())["stories"]
    assert [story["title"] for story in stories] == ["Nicotine", "Sauna"]
    nicotine = stories[0]
    assert nicotine["state"] == "possible" and [item["outcome_id"] for item in nicotine["findings"]] == [
        "hrv", "sleep_minutes", "readiness"]
    readiness = nicotine["findings"][2]
    assert any(text.startswith("Readiness is calculated from") for text in readiness["limitations"])


def test_seen_patterns_are_no_longer_new_and_explain_capped_confidence():
    seen_at = datetime(2026, 10, 2, tzinfo=UTC)
    views = {("nicotine:sleep_minutes:d1", "all"): SimpleNamespace(first_seen_at=seen_at)}
    presented = present([row(labels=["capped_after_seen"])], RUN, views, frozenset())
    result = presented["stories"][0]["findings"][0]
    assert presented["new_findings"] == 0 and result["unseen"] is False
    assert any(text.startswith("First shown on 2 October.") for text in result["limitations"])


def test_seen_stage_caps_later_rises_but_not_falls():
    result = PairResult(pair=Pair("nicotine", "sleep_minutes", "exploratory"), stratum="all", coding="binary")
    assert capped_after_seen(result, "consistent", "preliminary") == "preliminary"
    assert "capped_after_seen" in result.labels
    lower = PairResult(pair=Pair("nicotine", "hrv", "exploratory"), stratum="all", coding="binary")
    assert capped_after_seen(lower, "no_link", "possible") == "no_link" and lower.labels == []
    assert capped_after_seen(lower, "possible", None) == "possible"


def test_impact_is_a_share_of_the_usual_value_coloured_by_what_counts_as_better():
    sleep = finding(row(estimates=[estimate("yes", -25.0, 6.0, outcome_mean=420.0)]))
    assert sleep["group"] == "sleep" and sleep["outcome_short_label"] == "Duration"
    assert sleep["impact"]["benefit"] == "hurts" and sleep["impact"]["caption"] is None
    assert sleep["impact"]["percent"] == sleep["effects"][0]["value"] / 420.0 * 100
    assert sleep["impact"]["low"] < sleep["impact"]["percent"] < sleep["impact"]["high"]
    heart = finding(row(outcome_id="rhr", estimates=[estimate("yes", -3.0, 0.5, outcome_mean=55.0)]))
    assert heart["group"] == "recovery" and heart["impact"]["benefit"] == "helps"
    assert (sleep["impact"]["better"], heart["impact"]["better"]) == (1, -1)


def test_impact_uses_the_strongest_band_and_skips_unclear_or_unmeasured_results():
    drinks = finding(row(input_id="alcohol", outcome_id="rhr", coding="band", tier="main", estimates=[
        estimate("units_1_to_2", 1.0, 0.4, outcome_mean=55.0),
        estimate("units_3_plus", 3.0, 0.5, outcome_mean=55.0),
    ]))
    assert drinks["impact"]["caption"] == "3+ units" and drinks["impact"]["benefit"] == "hurts"
    neutral = finding(row(stage="no_link", estimates=[estimate("yes", 1.0, 2.0, outcome_mean=420.0)]))
    assert neutral["impact"]["benefit"] == "none"
    unclear = finding(row(stage="no_link", estimates=[estimate("yes", 10.0, 20.0, outcome_mean=420.0)]))
    assert unclear["impact"] is None
    assert finding(row())["impact"] is None
