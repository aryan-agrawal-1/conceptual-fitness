from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

from app.services.journal_catalogue import CATALOGUE_V1, STATISTICAL_BEHAVIOURS


MAP_VERSION = "behaviour_map_v1"
CATALOGUE_VERSION = CATALOGUE_V1.version

Tier = Literal["main", "exploratory"]
Coding = Literal["binary", "dose", "alcohol_bands", "continuous"]
Alignment = Literal["next_day", "after_answer", "morning_after_sleep", "shift_day"]

PHYSIOLOGY = ("sleep_minutes", "sleep_efficiency", "rhr", "hrv")
SLEEP = ("sleep_minutes", "sleep_efficiency")
NEXT_FEELINGS = ("mood_next", "stress_next", "energy_next")
MORNING_FEELINGS = ("mood_morning", "stress_morning", "energy_morning")


@dataclass(frozen=True)
class Outcome:
    id: str
    label: str
    unit: str


@dataclass(frozen=True)
class InputDefinition:
    id: str
    source: Literal["journal", "wearable"]
    coding: Coding
    dose_unit: str | None = None
    timing: bool = False
    two_way: bool = False
    held_reason: str | None = None
    favourable_review: bool = False
    description_only: bool = False


@dataclass(frozen=True)
class Pair:
    input_id: str
    outcome_id: str
    tier: Tier
    lag_days: int = 1
    alignment: Alignment = "next_day"
    sensitivity_lags: tuple[int, ...] = ()

    @property
    def id(self) -> str:
        return f"{self.input_id}:{self.outcome_id}:d{self.lag_days}"


@dataclass(frozen=True)
class BlockedPair:
    input_id: str
    outcome_id: str
    reason: Literal["in_formula", "never_tested", "recorded_after_outcome",
                    "same_measurement", "marks_illness", "not_statistical"]
    scope: Literal["any", "night_before_answer"] = "any"


@dataclass(frozen=True)
class BehaviourMap:
    version: str
    catalogue_version: int
    outcomes: tuple[Outcome, ...]
    inputs: tuple[InputDefinition, ...]
    pairs: tuple[Pair, ...]
    blocked: tuple[BlockedPair, ...]
    hard_band_percentile: float = 0.75
    sick_inputs: tuple[str, ...] = ("feeling_unwell", "fever")
    substance_inputs: tuple[str, ...] = ("alcohol", "nicotine", "cannabis", "other_substances")
    frequent_shift_share: float = 0.25
    shift_rest_days: int = 2
    alcohol_marker_units: float = 7.0

    def input(self, input_id: str) -> InputDefinition:
        return next(item for item in self.inputs if item.id == input_id)

    def outcome(self, outcome_id: str) -> Outcome:
        return next(item for item in self.outcomes if item.id == outcome_id)


OUTCOMES = (
    Outcome("sleep_minutes", "Main sleep", "min"),
    Outcome("sleep_efficiency", "Sleep efficiency", "percent"),
    Outcome("rhr", "Overnight resting heart rate", "bpm"),
    Outcome("hrv", "Overnight HRV", "ms"),
    Outcome("readiness", "Readiness", "score"),
    Outcome("mood_next", "Next-day mood", "rating"),
    Outcome("stress_next", "Next-day stress", "rating"),
    Outcome("energy_next", "Next-day energy", "rating"),
    Outcome("mood_morning", "Morning mood", "rating"),
    Outcome("stress_morning", "Morning stress", "rating"),
    Outcome("energy_morning", "Morning energy", "rating"),
)

INPUTS = (
    InputDefinition("alcohol", "journal", "alcohol_bands", timing=True, favourable_review=True),
    InputDefinition("caffeine", "journal", "dose", dose_unit="mg", timing=True),
    InputDefinition("nicotine", "journal", "binary", favourable_review=True),
    InputDefinition("cannabis", "journal", "binary"),
    InputDefinition("other_substances", "journal", "binary"),
    InputDefinition("feeling_unwell", "journal", "binary", description_only=True),
    InputDefinition("fever", "journal", "binary", description_only=True),
    *(InputDefinition(item, "journal", "dose", dose_unit="severity", two_way=True)
      for item in ("headache", "muscle_soreness", "pain", "digestive_symptoms", "allergy_symptoms")),
    *(InputDefinition(item, "journal", "continuous", dose_unit="rating")
      for item in ("mood", "stress", "energy")),
    *(InputDefinition(item, "journal", "binary")
      for item in ("worked_late", "night_shift", "travel", "screen_in_bed", "sleep_mask")),
    InputDefinition("sauna", "journal", "dose", dose_unit="min"),
    InputDefinition("cold_exposure", "journal", "dose", dose_unit="min"),
    InputDefinition("usual_medication", "journal", "binary", held_reason="awaiting_safety_wording"),
    InputDefinition("supplements", "journal", "binary", held_reason="awaiting_safety_wording"),
    InputDefinition("menstrual_bleeding", "journal", "dose", dose_unit="flow"),
    InputDefinition("menstrual_cramps", "journal", "dose", dose_unit="severity"),
    InputDefinition("training_load", "wearable", "continuous", dose_unit="load_points"),
    InputDefinition("hard_training", "wearable", "binary"),
    InputDefinition("workout_duration", "wearable", "continuous", dose_unit="min"),
    InputDefinition("longest_session", "wearable", "binary"),
    InputDefinition("workout_end_before_bed", "wearable", "continuous", dose_unit="h"),
    InputDefinition("workout_type_strength", "wearable", "binary"),
    InputDefinition("steps", "wearable", "continuous", dose_unit="steps"),
    InputDefinition("last_night_sleep_minutes", "wearable", "continuous", dose_unit="min"),
    InputDefinition("last_night_sleep_efficiency", "wearable", "continuous", dose_unit="percent"),
)


def pairs_for(input_id: str, outcomes: tuple[str, ...], tier: Tier, **options) -> tuple[Pair, ...]:
    return tuple(Pair(input_id, outcome, tier, **options) for outcome in outcomes)


PAIRS = (
    *(Pair("alcohol", outcome, "main", sensitivity_lags=(2,))
      for outcome in (*PHYSIOLOGY, "readiness")),
    Pair("alcohol", "energy_next", "main"),
    *pairs_for("alcohol", ("mood_next", "stress_next"), "exploratory"),
    *pairs_for("caffeine", PHYSIOLOGY, "main"),
    *pairs_for("caffeine", ("readiness", *NEXT_FEELINGS), "exploratory"),
    *(pair for item in ("nicotine", "cannabis", "other_substances")
      for pair in pairs_for(item, (*PHYSIOLOGY, "readiness"), "exploratory")),
    *(pair for item in ("headache", "muscle_soreness", "pain", "digestive_symptoms",
                        "allergy_symptoms")
      for pair in pairs_for(item, (*PHYSIOLOGY, "readiness"), "exploratory")),
    *(pair for item in ("mood", "stress", "energy")
      for pair in pairs_for(item, PHYSIOLOGY, "exploratory", alignment="after_answer")),
    *(pair for item in ("last_night_sleep_minutes", "last_night_sleep_efficiency")
      for pair in pairs_for(item, MORNING_FEELINGS, "main", lag_days=0,
                            alignment="morning_after_sleep")),
    *pairs_for("worked_late", (*PHYSIOLOGY, "readiness", *NEXT_FEELINGS), "exploratory"),
    *(Pair("travel", outcome, "exploratory", sensitivity_lags=(2,))
      for outcome in (*PHYSIOLOGY, "readiness", *NEXT_FEELINGS)),
    *pairs_for("night_shift", (*PHYSIOLOGY, "readiness"), "exploratory", alignment="shift_day"),
    *pairs_for("screen_in_bed", (*SLEEP, *NEXT_FEELINGS), "exploratory"),
    *pairs_for("sleep_mask", SLEEP, "exploratory"),
    *pairs_for("sauna", PHYSIOLOGY, "exploratory"),
    *pairs_for("cold_exposure", PHYSIOLOGY, "exploratory"),
    *pairs_for("usual_medication", (*PHYSIOLOGY, "readiness"), "exploratory"),
    *pairs_for("supplements", (*PHYSIOLOGY, "readiness"), "exploratory"),
    *pairs_for("menstrual_bleeding", PHYSIOLOGY, "exploratory"),
    *pairs_for("menstrual_cramps", PHYSIOLOGY, "exploratory"),
    *pairs_for("training_load", PHYSIOLOGY, "main"),
    *pairs_for("hard_training", PHYSIOLOGY, "main", lag_days=2),
    *pairs_for("workout_duration", ("sleep_minutes", "sleep_efficiency", "rhr"), "main"),
    *pairs_for("longest_session", ("sleep_minutes", "sleep_efficiency", "rhr"), "main", lag_days=2),
    *pairs_for("workout_end_before_bed", ("sleep_minutes", "sleep_efficiency", "rhr"), "main"),
    *pairs_for("workout_type_strength", ("hrv", "rhr"), "exploratory"),
    *pairs_for("steps", SLEEP, "exploratory"),
)

FORMULA_INPUTS = (
    "training_load", "hard_training", "workout_duration", "longest_session",
    "workout_end_before_bed", "workout_type_strength", "steps",
    "last_night_sleep_minutes", "last_night_sleep_efficiency",
)

BLOCKED = (
    *(BlockedPair(item, "readiness", "in_formula") for item in FORMULA_INPUTS),
    *(BlockedPair(item.id, "sleep_score", "never_tested") for item in INPUTS),
    *(BlockedPair(item, outcome, "recorded_after_outcome", scope="night_before_answer")
      for item in ("mood", "stress", "energy") for outcome in PHYSIOLOGY),
    *(BlockedPair(item, outcome.id, "marks_illness")
      for item in ("feeling_unwell", "fever") for outcome in OUTCOMES),
    *(BlockedPair("daily_note", outcome.id, "not_statistical") for outcome in OUTCOMES),
    *(BlockedPair(first, second, "same_measurement")
      for first in ("last_night_sleep_minutes", "last_night_sleep_efficiency")
      for second in SLEEP),
)

BEHAVIOUR_MAP_V1 = BehaviourMap(
    version=MAP_VERSION, catalogue_version=CATALOGUE_VERSION, outcomes=OUTCOMES,
    inputs=INPUTS, pairs=PAIRS, blocked=BLOCKED,
)


def unmapped_journal_inputs(mapping: BehaviourMap = BEHAVIOUR_MAP_V1) -> set[str]:
    mapped = {item.id for item in mapping.inputs}
    return set(STATISTICAL_BEHAVIOURS) - mapped


def tested_pairs(mapping: BehaviourMap = BEHAVIOUR_MAP_V1) -> tuple[Pair, ...]:
    return tuple(pair for pair in mapping.pairs if not mapping.input(pair.input_id).description_only)
