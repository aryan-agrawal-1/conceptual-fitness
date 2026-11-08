from __future__ import annotations

import math
from collections import Counter
from dataclasses import dataclass
from datetime import date, timedelta

from app.services.behaviour_analysis import (
    CHECKPOINT_DAYS, FINDING_DAYS, MIN_OUTCOME_DAYS, MIN_RECENT_OUTCOME_DAYS, PRELIMINARY_DAYS, RECENT_DAYS,
)
from app.services.behaviour_map import BEHAVIOUR_MAP_V1, OUTCOMES
from app.services.behaviour_safety import (
    FAVOURABLE_LIMITATIONS, GENERAL_NOTE, MEDICATION_LIMITATION, MENTAL_HEALTH_OUTCOMES, SAFETY_VERSION,
    SENSITIVE_INPUTS, category_for, held_back_text, note_for,
)


PRESENTATION_VERSION = "behaviour_presentation_v3"
FINDING_STATES = ("early_signal", "possible", "consistent")
STATE_PRIORITY = ("consistent", "possible", "early_signal", "inconclusive", "neutral", "overlapping",
                  "insufficient_variation", "collecting", "held")
STATE_LABELS = dict(
    consistent="Consistent association", possible="Possible association", early_signal="Early signal",
    inconclusive="Inconclusive", neutral="Neutral", overlapping="Overlapping inputs",
    insufficient_variation="Not enough variation", collecting="Collecting data", held="Not shown yet",
)
OUTCOME_ORDER = tuple(outcome.id for outcome in OUTCOMES)
NEUTRAL_BANDS = dict(
    sleep_minutes=15.0, sleep_efficiency=2.0, rhr=2.0, hrv=3.0, readiness=5.0,
    mood_next=0.5, stress_next=0.5, energy_next=0.5,
    mood_morning=0.5, stress_morning=0.5, energy_morning=0.5,
)
BETTER_DIRECTION = dict(
    sleep_minutes=1, sleep_efficiency=1, rhr=-1, hrv=1, readiness=1,
    mood_next=1, stress_next=-1, energy_next=1, mood_morning=1, stress_morning=-1, energy_morning=1,
)
OUTCOME_GROUPS = dict(
    sleep_minutes="sleep", sleep_efficiency="sleep", rhr="recovery", hrv="recovery", readiness="recovery",
    mood_next="feel", stress_next="feel", energy_next="feel",
    mood_morning="feel", stress_morning="feel", energy_morning="feel",
)
OUTCOME_SHORT_LABELS = dict(
    sleep_minutes="Duration", sleep_efficiency="Efficiency", rhr="Resting HR", hrv="HRV", readiness="Readiness",
    mood_next="Next-day mood", stress_next="Next-day stress", energy_next="Next-day energy",
    mood_morning="Morning mood", stress_morning="Morning stress", energy_morning="Morning energy",
)
UNIT_TEXT = dict(min="min", percent="points", bpm="bpm", ms="ms", score="points", rating="points")
OUTCOME_SUBJECTS = dict(
    sleep_minutes="Sleep", sleep_efficiency="Sleep efficiency", rhr="Overnight resting heart rate",
    hrv="Overnight HRV", readiness="Readiness", mood_next="Next-day mood", stress_next="Next-day stress",
    energy_next="Next-day energy", mood_morning="Morning mood", stress_morning="Morning stress",
    energy_morning="Morning energy",
)
OUTCOME_NOUNS = dict(
    sleep_minutes="sleep", sleep_efficiency="sleep efficiency", rhr="resting heart rate", hrv="HRV",
    readiness="readiness", mood_next="mood", stress_next="stress", energy_next="energy",
    mood_morning="morning mood", stress_morning="morning stress", energy_morning="morning energy",
)
ADJUSTMENT_TEXT = dict(
    recent="the two days before", drift="slow change over the window",
    journal_weekend_night="Friday and Saturday nights", training="same-day training load",
    between="the day in between",
)
EXCLUSION_TEXT = dict(
    sick_day="sick days", shift_recovery="shift recovery days", input_not_answered="days without an answer",
    outcome_missing="days without outcome data",
)


@dataclass(frozen=True)
class InputWords:
    label: str
    with_days: str
    without_days: str
    step: float | None = None
    step_text: str = ""
    timing_text: str = ""


INPUT_WORDS = dict(
    alcohol=InputWords("Alcohol", "days with alcohol", "days without",
                       timing_text="each extra hour between your last drink and bedtime"),
    caffeine=InputWords("Caffeine", "days with caffeine", "days without", 100.0, "per 100 mg of caffeine",
                        "each extra hour between your last caffeine and bedtime"),
    nicotine=InputWords("Nicotine", "days with nicotine", "days without"),
    cannabis=InputWords("Cannabis", "days with cannabis", "days without"),
    other_substances=InputWords("Other substances", "days with other substances", "days without"),
    headache=InputWords("Headache", "days with a headache", "days without", 1.0,
                        "per step up in headache severity"),
    muscle_soreness=InputWords("Muscle soreness", "days with muscle soreness", "days without", 1.0,
                               "per step up in soreness"),
    pain=InputWords("Pain", "days with pain", "days without", 1.0, "per step up in pain"),
    digestive_symptoms=InputWords("Digestive symptoms", "days with digestive symptoms", "days without", 1.0,
                                  "per step up in digestive symptoms"),
    allergy_symptoms=InputWords("Allergy symptoms", "days with allergy symptoms", "days without", 1.0,
                                "per step up in allergy symptoms"),
    mood=InputWords("Mood", "days with a higher mood rating", "days with a lower one", 1.0,
                    "per point higher mood rating"),
    stress=InputWords("Stress", "days with a higher stress rating", "days with a lower one", 1.0,
                      "per point higher stress rating"),
    energy=InputWords("Energy", "days with a higher energy rating", "days with a lower one", 1.0,
                      "per point higher energy rating"),
    worked_late=InputWords("Worked late", "days you worked late", "other days"),
    night_shift=InputWords("Night shift", "shift days", "other days"),
    travel=InputWords("Travel", "travel days", "other days"),
    screen_in_bed=InputWords("Screens in bed", "nights with screens in bed", "nights without"),
    sleep_mask=InputWords("Sleep mask", "nights with a sleep mask", "nights without"),
    sauna=InputWords("Sauna", "days with sauna", "days without", 10.0, "per 10 min of sauna"),
    cold_exposure=InputWords("Cold exposure", "days with cold exposure", "days without", 1.0,
                             "per minute of cold exposure"),
    usual_medication=InputWords("Usual medication", "days with your usual medication", "days without"),
    supplements=InputWords("Supplements", "days with supplements", "days without"),
    menstrual_bleeding=InputWords("Period flow", "days with a period", "days without", 1.0,
                                  "per step up in flow"),
    menstrual_cramps=InputWords("Cramps", "days with cramps", "days without", 1.0, "per step up in cramps"),
    training_load=InputWords("Training load", "days with higher training load", "days with lower load",
                             None, "per {step} points of training load"),
    hard_training=InputWords("Hard training", "hard training days", "other days"),
    workout_duration=InputWords("Workout length", "days with longer workouts", "days with shorter ones",
                                30.0, "per 30 min of workout"),
    longest_session=InputWords("Longest sessions", "days with your longest sessions", "other days"),
    workout_end_before_bed=InputWords("Workout timing", "days with earlier workouts", "days with later ones",
                                      1.0, "per extra hour between workout and bedtime"),
    workout_type_strength=InputWords("Strength vs cardio", "strength days", "cardio days"),
    steps=InputWords("Steps", "days with more steps", "days with fewer", 1000.0, "per 1,000 steps"),
    last_night_sleep_minutes=InputWords("Last night's sleep", "mornings after longer sleep",
                                        "mornings after shorter sleep", 60.0, "per extra hour of sleep"),
    last_night_sleep_efficiency=InputWords("Last night's sleep efficiency", "mornings after more efficient sleep",
                                           "mornings after less efficient sleep", 5.0,
                                           "per 5 points of sleep efficiency"),
)
BAND_TEXT = dict(units_1_to_2="after 1–2 units", units_3_plus="after 3 or more units")
BAND_CAPTIONS = dict(units_1_to_2="1–2 units", units_3_plus="3+ units")
IMPACT_STATES = ("consistent", "possible", "early_signal", "neutral")


def number(value):
    size = abs(value)
    if size >= 10:
        return f"{round(size):,}"
    return f"{size:.1f}".rstrip("0").rstrip(".") if size >= 0.05 else "0"


def nice_step(value):
    if value <= 0:
        return 1.0
    magnitude = 10 ** math.floor(math.log10(value))
    return min((1, 2, 5, 10), key=lambda item: abs(item * magnitude - value)) * magnitude


def step_for(words, estimate):
    if estimate["term"] in BAND_TEXT or estimate["term"] == "yes":
        return 1.0, ""
    if estimate["term"] == "hours_before_bed":
        return 1.0, words.timing_text
    if words.step is None:
        step = nice_step(estimate.get("exposure_sd") or 1.0)
        return step, words.step_text.format(step=number(step))
    if not words.step_text:
        return 1.0, "per unit"
    return words.step, words.step_text


def effect_for(estimate, outcome_id, words):
    step, step_text = step_for(words, estimate)
    shrunk = estimate.get("shrunk", estimate["estimate"])
    prior, error = estimate.get("prior_sd"), estimate["standard_error"]
    if prior and error:
        spread = 1.96 / math.sqrt(1 / prior ** 2 + 1 / error ** 2)
        low, high = shrunk - spread, shrunk + spread
    else:
        low, high = estimate["interval"]
    unit = BEHAVIOUR_MAP_V1.outcome(outcome_id).unit
    usual = estimate.get("outcome_mean")
    def percent(value):
        return value * step / usual * 100 if usual and usual > 0 else None
    return dict(term=estimate["term"], value=shrunk * step, low=low * step, high=high * step,
                unit=UNIT_TEXT.get(unit, unit), per=step_text,
                percent=percent(shrunk), percent_low=percent(low), percent_high=percent(high))


def impact_for(row, state, effects):
    if state not in IMPACT_STATES:
        return None
    measured = [effect for effect in exposure_effects(effects) if effect.get("percent") is not None]
    if not measured:
        return None
    effect = max(measured, key=lambda item: abs(item["percent"]))
    benefit = effect["percent"] * BETTER_DIRECTION.get(row.outcome_id, 0)
    return dict(
        percent=effect["percent"], low=effect["percent_low"], high=effect["percent_high"],
        caption=BAND_CAPTIONS.get(effect["term"]) or effect["per"] or None,
        benefit="none" if state == "neutral" else ("helps" if benefit > 0 else "hurts"),
        better=BETTER_DIRECTION.get(row.outcome_id, 1),
    )


def direction_word(outcome_id, value):
    if outcome_id == "sleep_minutes":
        return "longer" if value > 0 else "shorter"
    return "higher" if value > 0 else "lower"


def comparison_text(row, words, effect):
    if effect["term"] in BAND_TEXT:
        return f"{BAND_TEXT[effect['term']]} than on days without alcohol"
    if effect["per"]:
        return effect["per"]
    when = "two days after" if row.lag_days == 2 else "after"
    if row.input_id in ("screen_in_bed", "sleep_mask", "workout_type_strength", "night_shift"):
        when = "on"
    return f"{when} {words.with_days} than {words.without_days}"


def effect_sentence(row, words, effect):
    subject = OUTCOME_SUBJECTS[row.outcome_id]
    size = number(effect['value'])
    unit = "point" if size == "1" and effect["unit"] == "points" else effect["unit"]
    amount = f"{size} {unit}"
    return f"{subject} was about {amount} {direction_word(row.outcome_id, effect['value'])} " \
           f"{comparison_text(row, words, effect)}."


def range_sentence(effect):
    def signed(value):
        return ("−" if value < 0 else "+") + number(value)
    return f"Likely range {signed(effect['low'])} to {signed(effect['high'])} {effect['unit']}."


def exposure_effects(effects):
    main = [effect for effect in effects if effect["term"] != "hours_before_bed"]
    return main or effects


def within_band(effects, band):
    return all(-band <= effect["low"] and effect["high"] <= band for effect in exposure_effects(effects))


def looks_favourable(row, effects):
    better = BETTER_DIRECTION.get(row.outcome_id, 0)
    return any(effect["value"] * better > 0 for effect in exposure_effects(effects))


def overlapping_names(reason, hidden):
    names = reason.split(":", 1)[1].split(",") if ":" in reason else []
    shown = [INPUT_WORDS[name].label.lower() if name in INPUT_WORDS else name
             for name in names if name not in hidden]
    return shown + (["another input"] if len(shown) < len(names) else [])


def joined(names):
    if len(names) <= 1:
        return "".join(names)
    return ", ".join(names[:-1]) + " and " + names[-1]


def state_for(row, effects):
    if row.held_reason is not None:
        return "held", row.held_reason
    if row.stage == "suppressed":
        if (row.suppression_reason or "").startswith("overlaps_with"):
            return "overlapping", None
        return "insufficient_variation", None
    if row.stage in ("counts", "awaiting_checkpoint"):
        return "collecting", None
    if row.stage == "no_link":
        return ("neutral" if effects and within_band(effects, NEUTRAL_BANDS[row.outcome_id])
                else "inconclusive"), None
    state = dict(preliminary="early_signal", possible="possible", consistent="consistent").get(row.stage)
    if state is None:
        return "collecting", None
    if "favourable_needs_review" in row.labels and looks_favourable(row, effects):
        if not favourable_review_for(row).get("passed"):
            return "held", "favourable_checks_failed"
    return state, None


def favourable_review_for(row):
    return (row.checks or {}).get("favourable_review") or {}


def shown_favourable(row, state, effects):
    return (state in FINDING_STATES and "favourable_needs_review" in row.labels
            and looks_favourable(row, effects))


def outcome_day_counts(row, window_end):
    days = [date.fromisoformat(item) for item in row.included_dates]
    recent = [day for day in days if day > window_end - timedelta(days=RECENT_DAYS)]
    return len(days), len(recent)


def never_answered(row):
    return not row.included_dates and all(item["reason"] == "input_not_answered" for item in row.excluded_days)


def sensitive_needs(row, state, next_checkpoint):
    if state == "collecting" and row.stage == "awaiting_checkpoint":
        return f"Your first result for this appears at the day {next_checkpoint} check."
    if state == "collecting":
        return "Needs more days with both an answer and a reading before a comparison can be made."
    if state == "insufficient_variation":
        return "Your answers barely changed, so there is nothing to compare yet."
    if state == "overlapping":
        return "These are usually logged on the same days, so they can't be told apart yet."
    if state == "inconclusive":
        return "More days would narrow the range."
    if state in ("early_signal", "possible") and min(row.exposed_days, row.comparison_days) < FINDING_DAYS:
        return "A firmer result needs more days of data."
    return None


def needs_for(row, state, words, run, next_checkpoint):
    noun = OUTCOME_NOUNS[row.outcome_id]
    if state == "collecting" and never_answered(row):
        return f"Log {words.label.lower()} in your journal to start comparing it with {noun}."
    if row.input_id in SENSITIVE_INPUTS:
        return sensitive_needs(row, state, next_checkpoint)
    if state == "collecting" and row.stage == "awaiting_checkpoint":
        return f"Your first result for this appears at the day {next_checkpoint} check."
    if state == "collecting" and row.suppression_reason == "exposure_days_below_minimum":
        parts = []
        if row.exposed_days < PRELIMINARY_DAYS:
            parts.append(f"{PRELIMINARY_DAYS - row.exposed_days} more {words.with_days}")
        if row.comparison_days < PRELIMINARY_DAYS:
            parts.append(f"{PRELIMINARY_DAYS - row.comparison_days} more {words.without_days}")
        return f"Needs {' and '.join(parts)}, each with {noun} data."
    if state == "collecting":
        total, recent = outcome_day_counts(row, run.window_end)
        if total < MIN_OUTCOME_DAYS:
            return f"Needs {MIN_OUTCOME_DAYS - total} more days with both an answer and a reading."
        return f"Needs {MIN_RECENT_OUTCOME_DAYS - recent} more days with a reading in the last 30 days."
    if state == "insufficient_variation":
        return f"Your answers barely changed, so there is nothing to compare. " \
               f"A mix of {words.with_days} and {words.without_days} would help."
    if state == "overlapping":
        return "Logging days with one but not the other would let them be told apart."
    if state == "inconclusive":
        return "More days on both sides would narrow the range."
    if state in ("early_signal", "possible") and min(row.exposed_days, row.comparison_days) < FINDING_DAYS:
        smallest = min(row.exposed_days, row.comparison_days)
        return f"A firmer result needs at least {FINDING_DAYS} days on each side " \
               f"({FINDING_DAYS - smallest} more on the smaller side)."
    return None


def summary_for(row, state, held_reason, words, effects, hidden):
    noun = OUTCOME_NOUNS[row.outcome_id]
    if state == "held" and held_reason == "favourable_checks_failed":
        return held_back_text(row.input_id, favourable_review_for(row).get("failed") or ["unavailable"])
    if state == "held":
        return "This result is not shown yet."
    if state == "collecting":
        return f"Still collecting days to compare {words.label.lower()} with {noun}."
    if state == "insufficient_variation":
        return f"Not enough variation in {words.label.lower()} to compare with {noun}."
    if state == "overlapping":
        others = joined(overlapping_names(row.suppression_reason or "", hidden))
        return f"{words.label} is usually logged on the same days as {others}, so their links to {noun} " \
               f"can't be separated."
    if state == "neutral":
        band = NEUTRAL_BANDS[row.outcome_id]
        unit = effects[0]["unit"] if effects else ""
        return f"No link larger than {number(band)} {unit} was seen between {words.label.lower()} and {noun}."
    if state == "inconclusive":
        return f"No clear link between {words.label.lower()} and {noun} yet."
    lead = max(exposure_effects(effects), key=lambda effect: abs(effect["value"]))
    return effect_sentence(row, words, lead)


def adjustments_for(row):
    columns = row.checks.get("model", {}).get("columns", []) if row.checks else []
    adjustments = [ADJUSTMENT_TEXT[name] for name in columns if name in ADJUSTMENT_TEXT]
    if any(item["reason"] == "sick_day" for item in row.excluded_days):
        adjustments.append("sick days left out")
    return adjustments


def limitations_for(row, state, words, effects, seen_at, hidden):
    noun = OUTCOME_NOUNS[row.outcome_id]
    items = ["This is an association in your own data. It does not show that one causes the other."]
    if shown_favourable(row, state, effects) and row.input_id in FAVOURABLE_LIMITATIONS:
        items.append(FAVOURABLE_LIMITATIONS[row.input_id])
    if category_for(row.input_id) == "medication":
        items.append(MEDICATION_LIMITATION)
    if row.tier == "exploratory":
        items.append("Exploratory: there is little published research on this link, so treat it with extra care.")
    if state == "early_signal":
        items.append("Based on few days, so it may not hold as more days come in.")
    for label in row.labels:
        if label == "may_run_both_ways":
            items.append(f"This may run both ways: {noun} may also be linked to later {words.label.lower()}.")
        elif label.startswith("could_be_explained_by:"):
            others = joined(overlapping_names(label, hidden))
            items.append(f"Often logged together with {others}, which could explain some of this.")
        elif label == "models_disagree":
            items.append("A second model gave a different answer, so confidence was lowered.")
        elif label == "weaker_since_checkpoint":
            items.append("Weaker in recent data than at the last check.")
        elif label == "capped_after_seen" and seen_at is not None:
            items.append(f"First shown on {seen_at:%-d %B}. Later data can lower confidence but not raise it, "
                         "because knowing about a pattern can change behaviour and how you rate your day.")
    terms = {effect["term"] for effect in exposure_effects(effects)}
    if state in FINDING_STATES and (row.coding == "dose" or terms == set(BAND_TEXT)):
        items.append("Stronger at higher amounts is assumed; the exact shape is unclear.")
    if row.outcome_id == "readiness":
        items.append("Readiness is calculated from sleep, HRV and resting heart rate, so read it alongside those.")
    if row.stratum in ("shift", "off"):
        items.append("Shift days and days off are analysed separately.")
    return items


def sample_for(row, words):
    excluded = Counter(item["reason"] for item in row.excluded_days)
    return dict(
        exposed_days=row.exposed_days, comparison_days=row.comparison_days,
        exposed_label=words.with_days, comparison_label=words.without_days,
        excluded=[dict(reason=reason, text=EXCLUSION_TEXT.get(reason, reason), days=count)
                  for reason, count in sorted(excluded.items())],
    )


def finding_for(row, run, views, hidden, next_checkpoint):
    words = INPUT_WORDS.get(row.input_id, InputWords(row.input_id, "days with it", "days without"))
    effects = [] if row.held_reason else [effect_for(item, row.outcome_id, words) for item in row.estimates]
    state, held_reason = state_for(row, effects)
    view = views.get((row.pair_id, row.stratum))
    shown_effects = effects if state in (*FINDING_STATES, "neutral", "inconclusive") else []
    return dict(
        pair_id=row.pair_id, stratum=row.stratum, outcome_id=row.outcome_id,
        outcome_label=OUTCOME_SUBJECTS[row.outcome_id], outcome_short_label=OUTCOME_SHORT_LABELS[row.outcome_id],
        group=OUTCOME_GROUPS[row.outcome_id], impact=impact_for(row, state, effects), tier=row.tier, state=state,
        state_label=STATE_LABELS[state], held_reason=held_reason,
        summary=summary_for(row, state, held_reason, words, effects, hidden),
        effects=[dict(effect, text=(effect_sentence(row, words, effect) if state in FINDING_STATES else None),
                      range_text=range_sentence(effect)) for effect in shown_effects],
        needs=needs_for(row, state, words, run, next_checkpoint),
        sample=sample_for(row, words),
        window=dict(start=run.window_start, end=run.window_end),
        adjustments=adjustments_for(row) if shown_effects else [],
        limitations=limitations_for(row, state, words, effects, view.first_seen_at if view else None, hidden),
        unseen=state in FINDING_STATES and view is None,
        never_logged=never_answered(row),
    )


def story_title(input_id, stratum):
    label = INPUT_WORDS[input_id].label if input_id in INPUT_WORDS else input_id
    return {"shift": f"{label} on shift days", "off": f"{label} on days off"}.get(stratum, label)


def next_checkpoint_day(run):
    if run.tracking_day < CHECKPOINT_DAYS:
        return CHECKPOINT_DAYS
    return run.tracking_day // CHECKPOINT_DAYS * CHECKPOINT_DAYS + CHECKPOINT_DAYS


def present(rows, run, views, hidden):
    upcoming = next_checkpoint_day(run)
    grouped = {}
    for row in rows:
        grouped.setdefault((row.input_id, row.stratum), []).append(
            (row, finding_for(row, run, views, hidden, upcoming)))
    stories = []
    for (input_id, stratum), items in grouped.items():
        items.sort(key=lambda item: (STATE_PRIORITY.index(item[1]["state"]), OUTCOME_ORDER.index(item[0].outcome_id)))
        findings = [finding for _, finding in items]
        best = min(findings, key=lambda finding: STATE_PRIORITY.index(finding["state"]))
        stories.append(dict(
            id=f"{input_id}:{stratum}", input_id=input_id, stratum=stratum,
            title=story_title(input_id, stratum),
            tier="main" if any(finding["tier"] == "main" for finding in findings) else "exploratory",
            state=best["state"], state_label=best["state_label"], headline=best["summary"],
            findings=findings, unseen=any(finding["unseen"] for finding in findings),
            never_logged=all(finding["never_logged"] for finding in findings),
            safety_note=note_for(input_id, [finding["outcome_id"] for finding in findings
                                            if finding["state"] in FINDING_STATES
                                            and finding["outcome_id"] in MENTAL_HEALTH_OUTCOMES]),
        ))
    stories.sort(key=lambda story: (STATE_PRIORITY.index(story["state"]), story["title"]))
    return dict(
        version=PRESENTATION_VERSION, safety_version=SAFETY_VERSION, general_note=GENERAL_NOTE,
        next_checkpoint_day=upcoming,
        new_findings=sum(story["unseen"] for story in stories), stories=stories,
    )
