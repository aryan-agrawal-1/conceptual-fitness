from __future__ import annotations

from datetime import UTC, date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import numpy as np
import pytest

from app.services.behaviour_analysis import analyse
from app.services import behaviour_map
from app.services.behaviour_map import (
    BEHAVIOUR_MAP_V1, FORMULA_INPUTS, PHYSIOLOGY, unmapped_journal_inputs,
)
from app.services.behaviour_series import Answer, MainSleep, UserData, turned_off_inputs
from app.services.behaviour_stats import benjamini_hochberg, gls_ar1, shrink


END = date(2026, 10, 31)
DAYS = 90


def moment(day: date, hour: int, minute: int = 0) -> datetime:
    return datetime.combine(day, time(hour, minute), tzinfo=UTC)


def ar_noise(rng, count: int, phi: float, sd: float) -> np.ndarray:
    noise = np.zeros(count)
    noise[0] = rng.normal(0, sd / np.sqrt(1 - phi ** 2))
    for index in range(1, count):
        noise[index] = phi * noise[index - 1] + rng.normal(0, sd)
    return noise


class Fixture:
    def __init__(self, seed: int = 0, phi: float = 0.4):
        self.rng = np.random.default_rng(seed)
        self.start = END - timedelta(days=DAYS - 1)
        self.data = UserData(zone=ZoneInfo("UTC"), start=self.start, end=END,
                             first_day=self.start - timedelta(days=30))
        self.calendar = [self.start + timedelta(days=offset) for offset in range(-3, DAYS + 4)]
        self.rhr = dict(zip(self.calendar, 55 + ar_noise(self.rng, len(self.calendar), phi, 1.5)))
        self.hrv = dict(zip(self.calendar, 60 + ar_noise(self.rng, len(self.calendar), phi, 5)))
        self.sleep = dict(zip(self.calendar, 420 + ar_noise(self.rng, len(self.calendar), phi, 30)))

    def answer(self, day: date, behaviour: str, value, details: dict | None = None,
               recorded: datetime | None = None) -> None:
        numeric = None if value is None else float(value)
        self.data.answers[(day, behaviour)] = Answer(
            value=numeric, details=details or {}, recorded_at=recorded or moment(day, 21),
        )

    def alcohol(self, day: date, units: float) -> None:
        details = {"amount": {"type": "quantity", "value": units * 10, "unit": "mL_ethanol"}} if units else {}
        self.answer(day, "alcohol", units > 0, details)

    def finish(self) -> UserData:
        for day in self.calendar:
            self.data.rhr[day] = float(self.rhr[day])
            self.data.hrv[day] = float(self.hrv[day])
            self.data.sleeps[day] = MainSleep(
                start=moment(day - timedelta(days=1), 23), end=moment(day, 7),
                minutes=float(self.sleep[day]), efficiency=90.0,
            )
        return self.data


def results_for(data: UserData, tracking_day: int = 120) -> dict:
    found = analyse(data, tracking_day=tracking_day, checkpoint=True, previous={}, earlier={})
    return {(result.pair.id, result.stratum): result for result in found}


def term(result, name: str) -> dict:
    return next(item for item in result.estimates if item["term"] == name)


def test_every_journal_input_is_mapped_and_blocked_pairs_are_never_tested() -> None:
    assert unmapped_journal_inputs() == set()
    tested = {(pair.input_id, pair.outcome_id) for pair in behaviour_map.tested_pairs()}
    blocked = {(item.input_id, item.outcome_id) for item in BEHAVIOUR_MAP_V1.blocked
               if item.scope == "any"}
    assert not tested & blocked
    assert all(("readiness" != outcome or item not in FORMULA_INPUTS) for item, outcome in tested)
    assert all(outcome != "sleep_score" for _, outcome in tested)
    assert not any(item.held_reason for item in BEHAVIOUR_MAP_V1.inputs)
    assert {item.id for item in BEHAVIOUR_MAP_V1.inputs if item.favourable_review} == {"alcohol", "nicotine"}
    assert not {item for item, _ in tested} & {"feeling_unwell", "fever", "daily_note"}
    assert len({pair.id for pair in BEHAVIOUR_MAP_V1.pairs}) == len(BEHAVIOUR_MAP_V1.pairs)


def test_ratings_are_only_tested_against_the_night_after_they_were_recorded() -> None:
    rating_pairs = [pair for pair in behaviour_map.tested_pairs() if pair.input_id in ("mood", "stress", "energy")]
    assert rating_pairs and all(pair.alignment == "after_answer" for pair in rating_pairs)
    assert {pair.outcome_id for pair in rating_pairs} == set(PHYSIOLOGY)


def test_ar1_fit_keeps_false_positives_near_nominal_with_gaps() -> None:
    rng = np.random.default_rng(3)
    rejections = 0
    for _ in range(200):
        days = np.arange(90)
        exposure = np.zeros(90)
        for index in range(1, 90):
            exposure[index] = float(rng.random() < (0.6 if exposure[index - 1] else 0.3))
        outcome = ar_noise(rng, 90, 0.7, 1.0)
        keep = rng.random(90) > 0.25
        design = np.column_stack([np.ones(90), exposure, days / 30])[keep]
        rejections += gls_ar1(outcome[keep], design, days[keep], (1,)).p_value < 0.05
    assert rejections / 200 < 0.09


def test_benjamini_hochberg_and_shrinkage() -> None:
    assert benjamini_hochberg([0.01, 0.04, 0.03, 0.5]) == pytest.approx([0.04, 0.0533, 0.0533, 0.5], abs=1e-3)
    assert shrink(2.0, 1.0, 1.0) == pytest.approx(1.0)
    assert abs(shrink(2.0, 0.1, 1.0)) < 2.0


def test_positive_fixture_finds_a_dose_graded_alcohol_link() -> None:
    fixture = Fixture(seed=1)
    for day in fixture.data.days():
        draw = fixture.rng.random()
        units = 0 if draw < 0.5 else (2 if draw < 0.75 else 4)
        fixture.alcohol(day, units)
        following = day + timedelta(days=1)
        fixture.rhr[following] += {0: 0.0, 2: 1.5, 4: 3.5}[units]
    result = results_for(fixture.finish())[("alcohol:rhr:d1", "all")]
    assert result.coding == "alcohol_bands"
    assert result.stage in ("possible", "consistent")
    high = term(result, "units_3_plus")
    assert high["interval"][0] > 0
    assert 0 < high["shrunk"] <= high["estimate"]
    assert result.checks["previous_value"]["agrees"] is True


def test_null_fixture_reports_no_link_and_keeps_both_groups_counted() -> None:
    fixture = Fixture(seed=2)
    for day in fixture.data.days():
        fixture.alcohol(day, 3 if fixture.rng.random() < 0.4 else 0)
    result = results_for(fixture.finish())[("alcohol:rhr:d1", "all")]
    assert result.tested
    assert result.stage == "no_link"
    assert result.exposed_days >= 18 and result.comparison_days >= 18


def test_confounded_fixture_adjusts_for_same_day_training() -> None:
    fixture = Fixture(seed=4)
    for day in fixture.data.days():
        hard = fixture.rng.random() < 0.4
        fixture.data.training_load[day] = 120.0 if hard else 20.0
        fixture.alcohol(day, 0 if hard else (3 if fixture.rng.random() < 0.7 else 0))
        fixture.rhr[day + timedelta(days=1)] += 4.0 if hard else 0.0
    result = results_for(fixture.finish())[("alcohol:rhr:d1", "all")]
    estimate = term(result, "yes" if result.coding == "binary" else "units_3_plus")
    assert estimate["interval"][0] < 0 < estimate["interval"][1]
    assert "training" in result.checks["model"]["columns"]


def test_lagged_fixture_is_found_by_the_reviewed_second_day_test() -> None:
    fixture = Fixture(seed=5)
    for day in fixture.data.days():
        load = 150.0 if fixture.rng.random() < 0.3 else float(fixture.rng.uniform(10, 60))
        fixture.data.training_load[day] = load
        if load >= 150:
            fixture.hrv[day + timedelta(days=2)] -= 12
    results = results_for(fixture.finish())
    second_day = results[("hard_training:hrv:d2", "all")]
    assert second_day.stage in ("possible", "consistent")
    assert term(second_day, "yes")["estimate"] < 0
    assert "between" in second_day.checks["model"]["columns"]


def test_missing_answers_are_never_counted_as_no() -> None:
    fixture = Fixture(seed=6)
    explicit_no = 0
    for day in fixture.data.days():
        draw = fixture.rng.random()
        if draw < 0.3:
            continue
        drank = draw > 0.65
        explicit_no += not drank
        fixture.alcohol(day, 2 if drank else 0)
    result = results_for(fixture.finish())[("alcohol:rhr:d1", "all")]
    reasons = {item["reason"] for item in result.excluded_days}
    assert "input_not_answered" in reasons
    assert result.comparison_days == explicit_no


def test_autocorrelated_null_is_not_reported() -> None:
    fixture = Fixture(seed=7, phi=0.85)
    drinking = False
    for day in fixture.data.days():
        drinking = fixture.rng.random() < (0.8 if drinking else 0.2)
        fixture.alcohol(day, 3 if drinking else 0)
    result = results_for(fixture.finish())[("alcohol:rhr:d1", "all")]
    assert result.checks["model"]["phi"] > 0.4
    assert result.stage in ("no_link", "preliminary")


def test_rating_answered_after_the_night_is_not_credited_for_it() -> None:
    fixture = Fixture(seed=8)
    for day in fixture.data.days():
        night = fixture.sleep[day + timedelta(days=1)]
        mood = 5 if night > 420 else 2
        fixture.answer(day, "mood", mood, recorded=moment(day + timedelta(days=1), 9))
    results = results_for(fixture.finish())
    morning = results[("last_night_sleep_minutes:mood_morning:d0", "all")]
    assert morning.stage in ("possible", "consistent")
    following = results[("mood:sleep_minutes:d1", "all")]
    assert following.stage in ("no_link", "preliminary")


def test_strongly_overlapping_inputs_are_suppressed_and_partial_overlap_is_labelled() -> None:
    fixture = Fixture(seed=9)
    for day in fixture.data.days():
        late = fixture.rng.random() < 0.4
        fixture.answer(day, "worked_late", late)
        fixture.answer(day, "screen_in_bed", late)
        fixture.answer(day, "travel", late if fixture.rng.random() < 0.75 else not late)
    results = results_for(fixture.finish())
    assert results[("worked_late:sleep_minutes:d1", "all")].suppression_reason.startswith("overlaps_with:")
    assert results[("screen_in_bed:sleep_minutes:d1", "all")].stage == "suppressed"


def test_carry_over_is_modelled_rather_than_biasing_the_next_day_effect() -> None:
    fixture = Fixture(seed=10)
    for day in fixture.data.days():
        units = 4 if fixture.rng.random() < 0.45 else 0
        fixture.alcohol(day, units)
        if units:
            fixture.rhr[day + timedelta(days=1)] += 3.0
            fixture.rhr[day + timedelta(days=2)] += 1.5
    result = results_for(fixture.finish())[("alcohol:rhr:d1", "all")]
    high = term(result, "units_3_plus")
    assert high["interval"][0] < 3.0 < high["interval"][1]
    assert result.checks["d2_sensitivity"]["status"] == "fitted"


def test_sick_days_and_the_day_before_are_removed_but_hangovers_are_kept() -> None:
    fixture = Fixture(seed=11)
    fever_day = fixture.start + timedelta(days=40)
    hangover_day = fixture.start + timedelta(days=60)
    for day in fixture.data.days():
        fixture.alcohol(day, 3 if day == hangover_day - timedelta(days=1) or fixture.rng.random() < 0.4 else 0)
    fixture.answer(fever_day, "fever", True)
    fixture.answer(hangover_day, "feeling_unwell", True)
    result = results_for(fixture.finish())[("alcohol:rhr:d1", "all")]
    sick = {item["date"] for item in result.excluded_days if item["reason"] == "sick_day"}
    assert {fever_day.isoformat(), (fever_day - timedelta(days=1)).isoformat()} <= sick
    assert hangover_day.isoformat() not in sick
    assert result.checks["without_sick_day_removal"]["status"] == "fitted"


def test_occasional_night_shifts_remove_shift_and_rest_days_from_other_inputs() -> None:
    fixture = Fixture(seed=12)
    shift = fixture.start + timedelta(days=20)
    for day in fixture.data.days():
        fixture.answer(day, "night_shift", day == shift)
        fixture.alcohol(day, 3 if fixture.rng.random() < 0.4 else 0)
    result = results_for(fixture.finish())[("alcohol:rhr:d1", "all")]
    removed = {item["date"] for item in result.excluded_days if item["reason"] == "shift_recovery"}
    assert removed == {(shift + timedelta(days=offset)).isoformat() for offset in range(3)}


def test_frequent_night_shifts_are_analysed_in_separate_strata() -> None:
    fixture = Fixture(seed=13)
    for day in fixture.data.days():
        fixture.answer(day, "night_shift", day.weekday() < 2)
        fixture.alcohol(day, 3 if fixture.rng.random() < 0.5 else 0)
    results = results_for(fixture.finish())
    assert ("alcohol:rhr:d1", "shift") in results and ("alcohol:rhr:d1", "off") in results
    assert ("night_shift:rhr:d1", "all") in results


def test_turned_off_private_inputs_are_not_analysed() -> None:
    fixture = Fixture(seed=14)
    for day in fixture.data.days():
        fixture.alcohol(day, 3 if fixture.rng.random() < 0.4 else 0)
    fixture.data.turned_off = turned_off_inputs({"opt_in:substances": True, "pin:alcohol": False})
    results = results_for(fixture.finish())
    assert not any(key[0].startswith("alcohol:") for key in results)


def test_turned_off_inputs_cover_categories_and_single_switches() -> None:
    assert "alcohol" in turned_off_inputs({"opt_in:substances": False})
    assert "caffeine" in turned_off_inputs({"opt_in:substances": False})
    assert turned_off_inputs({"opt_in:substances": True, "pin:caffeine": False}) & {"caffeine", "alcohol"} == {"caffeine"}
    assert "sauna" not in turned_off_inputs({"pin:sauna": False})


def test_too_few_days_show_counts_and_early_results_need_the_stricter_bar() -> None:
    fixture = Fixture(seed=15)
    for day in fixture.data.days()[-35:]:
        fixture.alcohol(day, 4 if fixture.rng.random() < 0.15 else 0)
    result = results_for(fixture.finish(), tracking_day=35)[("alcohol:rhr:d1", "all")]
    assert result.stage == "counts"
    assert result.suppression_reason == "exposure_days_below_minimum"


def test_medication_results_are_calculated_and_not_held() -> None:
    fixture = Fixture(seed=16)
    for day in fixture.data.days():
        fixture.answer(day, "usual_medication", fixture.rng.random() < 0.6)
    result = results_for(fixture.finish())[("usual_medication:rhr:d1", "all")]
    assert result.tested and result.held_reason is None
    assert "favourable_review" not in result.checks


def nicotine_fixture(seed: int, already_higher: bool) -> UserData:
    fixture = Fixture(seed=seed)
    for day in fixture.data.days():
        used = fixture.rng.random() < 0.4
        fixture.answer(day, "nicotine", used)
        if used:
            fixture.hrv[day + timedelta(days=1)] += 12
            if already_higher:
                fixture.hrv[day] += 12
    return fixture.finish()


def test_favourable_looking_nicotine_passes_the_extra_checks_when_nothing_came_before() -> None:
    result = results_for(nicotine_fixture(31, already_higher=False))[("nicotine:hrv:d1", "all")]
    assert term(result, "yes")["estimate"] > 0
    review = result.checks["favourable_review"]
    assert review == dict(passed=True, failed=[], weekend_adjusted=True)
    assert result.checks["before_exposure"]["status"] == "fitted"


def test_favourable_looking_nicotine_fails_when_the_outcome_was_already_higher_before() -> None:
    result = results_for(nicotine_fixture(32, already_higher=True))[("nicotine:hrv:d1", "all")]
    assert term(result, "yes")["estimate"] > 0
    review = result.checks["favourable_review"]
    assert review["passed"] is False and "before_exposure" in review["failed"]
