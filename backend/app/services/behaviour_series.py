from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta
from statistics import median
from zoneinfo import ZoneInfo

import numpy as np
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import DailyScore, DailySummary, JournalEntry, JournalPreference, SleepSession, Workout
from app.services.behaviour_map import BehaviourMap, InputDefinition, Pair
from app.services.health_dates import get_or_create_profile, timezone_for_profile
from app.services.hrv import hrv_value_of_type
from app.services.journal_catalogue import CATALOGUE_V1, SENSITIVE_CATEGORIES
from app.services.score_helpers import READINESS_SCORE_VERSION, STRAIN_LOAD_VERSION
from app.services.strain_scores import _is_strength_workout


COMPLETE_DOSE_SHARE = 0.8
RATING_WINDOW = timedelta(hours=16)
FOLLOWING_NIGHT_WINDOW = timedelta(hours=36)
TRAINING_INPUTS = frozenset({
    "training_load", "hard_training", "workout_duration", "longest_session",
    "workout_end_before_bed", "workout_type_strength", "steps",
})
RATING_OUTCOMES = {"mood_next": "mood", "stress_next": "stress", "energy_next": "energy",
                   "mood_morning": "mood", "stress_morning": "stress", "energy_morning": "energy"}
RATING_INPUTS = frozenset({"mood", "stress", "energy"})


@dataclass(frozen=True)
class Answer:
    value: float | None
    details: dict
    recorded_at: datetime


@dataclass(frozen=True)
class MainSleep:
    start: datetime
    end: datetime
    minutes: float | None
    efficiency: float | None


@dataclass(frozen=True)
class WorkoutDay:
    minutes: float
    end: datetime
    strength: bool


@dataclass
class UserData:
    zone: ZoneInfo
    start: date
    end: date
    answers: dict[tuple[date, str], Answer] = field(default_factory=dict)
    sleeps: dict[date, MainSleep] = field(default_factory=dict)
    rhr: dict[date, float] = field(default_factory=dict)
    hrv: dict[date, float] = field(default_factory=dict)
    steps: dict[date, float] = field(default_factory=dict)
    readiness: dict[date, float] = field(default_factory=dict)
    training_load: dict[date, float] = field(default_factory=dict)
    workouts: dict[date, list[WorkoutDay]] = field(default_factory=lambda: defaultdict(list))
    turned_off: frozenset[str] = frozenset()
    first_day: date | None = None

    def days(self) -> list[date]:
        return [self.start + timedelta(days=offset)
                for offset in range((self.end - self.start).days + 1)]


@dataclass(frozen=True)
class Exposure:
    terms: tuple[str, ...]
    values: dict[date, tuple[float, ...]]
    exposed: dict[date, bool]
    recorded_at: dict[date, datetime]
    coding: str
    markers: dict[date, str] = field(default_factory=dict)


@dataclass(frozen=True)
class Row:
    day: date
    terms: tuple[float, ...]
    exposed: bool
    outcome: float


def turned_off_inputs(preferences: dict[str, bool]) -> frozenset[str]:
    off = set()
    for behaviour in CATALOGUE_V1.behaviours:
        if behaviour.category_id not in SENSITIVE_CATEGORIES:
            continue
        if (preferences.get(f"opt_in:{behaviour.category_id}") is False
                or preferences.get(f"pin:{behaviour.id}") is False):
            off.add(behaviour.id)
    return frozenset(off)


def answer_value(normalized: dict | None) -> float | None:
    answer = (normalized or {}).get("canonical_answer")
    if not answer or answer.get("type") == "text":
        return None
    value = answer.get("value")
    if isinstance(value, bool):
        return 1.0 if value else 0.0
    return float(value) if isinstance(value, (int, float)) else None


def load_user_data(session: Session, user_id: str, start: date, end: date) -> UserData:
    profile = get_or_create_profile(session, user_id)
    zone = timezone_for_profile(profile)
    data = UserData(zone=zone, start=start, end=end)
    lookback = start - timedelta(days=3)
    lookahead = end + timedelta(days=3)
    entries = session.scalars(select(JournalEntry).where(
        JournalEntry.user_id == user_id, JournalEntry.deleted.is_(False),
        JournalEntry.journal_date.between(lookback, lookahead),
    ))
    for entry in entries:
        recorded = (entry.response or {}).get("recorded_at")
        if not recorded:
            continue
        data.answers[(entry.journal_date, entry.behaviour_id)] = Answer(
            value=answer_value(entry.normalized),
            details=(entry.normalized or {}).get("canonical_details") or {},
            recorded_at=datetime.fromisoformat(recorded),
        )
    data.first_day = session.scalar(select(JournalEntry.journal_date).where(
        JournalEntry.user_id == user_id, JournalEntry.deleted.is_(False),
    ).order_by(JournalEntry.journal_date).limit(1))
    preferences = {row.key: row.value for row in session.scalars(select(JournalPreference).where(
        JournalPreference.user_id == user_id,
    ))}
    data.turned_off = turned_off_inputs(preferences)
    for sleep in session.scalars(select(SleepSession).where(
        SleepSession.user_id == user_id, SleepSession.is_main_sleep.is_(True),
        SleepSession.civil_date.between(lookback, lookahead),
    )):
        period = sleep.minutes_in_sleep_period
        efficiency = (100.0 * sleep.minutes_asleep / period
                      if sleep.minutes_asleep is not None and period else None)
        data.sleeps[sleep.civil_date] = MainSleep(
            start=sleep.start_time, end=sleep.end_time,
            minutes=float(sleep.minutes_asleep) if sleep.minutes_asleep is not None else None,
            efficiency=efficiency,
        )
    summaries = session.scalars(select(DailySummary).where(
        DailySummary.user_id == user_id, DailySummary.summary_date.between(lookback, lookahead),
    ).order_by(DailySummary.summary_date)).all()
    hrv_type = next((item.heart_rate_variability_type for item in reversed(summaries)
                     if item.heart_rate_variability_type), None)
    for summary in summaries:
        if summary.resting_heart_rate is not None:
            data.rhr[summary.summary_date] = float(summary.resting_heart_rate)
        if (hrv := hrv_value_of_type(summary, hrv_type)) is not None:
            data.hrv[summary.summary_date] = float(hrv)
        if summary.steps is not None:
            data.steps[summary.summary_date] = float(summary.steps)
    for score in session.scalars(select(DailyScore).where(
        DailyScore.user_id == user_id, DailyScore.score_date.between(lookback, lookahead),
        DailyScore.value.is_not(None),
        ((DailyScore.score_type == "readiness") & (DailyScore.algorithm_version == READINESS_SCORE_VERSION))
        | ((DailyScore.score_type == "strain") & (DailyScore.algorithm_version == STRAIN_LOAD_VERSION)),
    )):
        target = data.readiness if score.score_type == "readiness" else data.training_load
        target[score.score_date] = float(score.value)
    for workout in session.scalars(select(Workout).where(
        Workout.user_id == user_id, Workout.status == "completed", Workout.deleted_at.is_(None),
        Workout.civil_date.between(lookback, lookahead),
    )):
        minutes = (workout.duration_seconds or (workout.end_time - workout.start_time).total_seconds()) / 60
        data.workouts[workout.civil_date].append(WorkoutDay(
            minutes=float(minutes), end=workout.end_time, strength=_is_strength_workout(workout),
        ))
    return data


def minutes_from_noon(moment: time) -> float:
    return ((moment.hour - 12) % 24) * 60 + moment.minute


def usual_bedtime(data: UserData) -> float | None:
    starts = [minutes_from_noon(sleep.start.astimezone(data.zone).time())
              for day, sleep in data.sleeps.items() if data.start <= day <= data.end]
    return median(starts) if starts else None


def hours_before_bed(clock: str | None, bedtime: float | None) -> float | None:
    if clock is None or bedtime is None:
        return None
    hour, minute = (int(part) for part in clock.split(":"))
    return (bedtime - minutes_from_noon(time(hour, minute))) / 60


def detail_value(answer: Answer, key: str):
    detail = answer.details.get(key)
    return detail.get("value") if isinstance(detail, dict) else None


def journal_exposure(data: UserData, definition: InputDefinition, bedtime: float | None,
                     map_definition: BehaviourMap) -> Exposure:
    days = [day for day in data.days()]
    answers = {day: data.answers.get((day, definition.id)) for day in days}
    answered = {day: answer for day, answer in answers.items()
                if answer is not None and answer.value is not None}
    recorded = {day: answer.recorded_at for day, answer in answered.items()}
    if definition.coding == "continuous":
        values = {day: (answer.value,) for day, answer in answered.items()}
        return continuous_exposure(values, recorded, "continuous")
    yes_days = [day for day, answer in answered.items() if answer.value]
    dose_key = {"alcohol_bands": "amount", "dose": dose_detail(definition.id)}.get(definition.coding)
    doses = {day: dose_value(definition.id, answered[day], dose_key) for day in yes_days} if dose_key else {}
    with_dose = [day for day in yes_days if doses.get(day) is not None]
    use_dose = dose_key is not None and yes_days and len(with_dose) >= COMPLETE_DOSE_SHARE * len(yes_days)
    timings = {}
    if definition.timing:
        timings = {day: hours_before_bed(detail_value(answered[day], "last_use"), bedtime)
                   for day in yes_days}
    timed = [day for day in yes_days if timings.get(day) is not None]
    use_timing = bool(yes_days) and len(timed) >= COMPLETE_DOSE_SHARE * len(yes_days)
    mean_timing = float(np.mean([timings[day] for day in timed])) if use_timing else 0.0
    values, exposed, markers = {}, {}, {}
    for day, answer in answered.items():
        if not answer.value:
            terms = (0.0, 0.0) if use_dose and definition.coding == "alcohol_bands" else (0.0,)
            values[day] = terms + ((0.0,) if use_timing else ())
            exposed[day] = False
            continue
        if use_dose and doses.get(day) is None:
            continue
        if use_timing and timings.get(day) is None:
            continue
        if use_dose and definition.coding == "alcohol_bands":
            units = doses[day]
            terms = (1.0, 0.0) if units < 3 else (0.0, 1.0)
            if units >= map_definition.alcohol_marker_units:
                markers[day] = "heavy_night"
        elif use_dose:
            terms = (doses[day],)
        else:
            terms = (1.0,)
        values[day] = terms + ((timings[day] - mean_timing,) if use_timing else ())
        exposed[day] = True
    if use_dose and definition.coding == "alcohol_bands":
        names, coding = ("units_1_to_2", "units_3_plus"), "alcohol_bands"
    elif use_dose:
        names, coding = (definition.dose_unit or "dose",), "dose"
    else:
        names, coding = ("yes",), "binary"
    if use_timing:
        names += ("hours_before_bed",)
    return Exposure(terms=names, values=values, exposed=exposed,
                    recorded_at={day: recorded[day] for day in values}, coding=coding, markers=markers)


def dose_detail(behaviour_id: str) -> str:
    return {"caffeine": "amount", "sauna": "duration", "cold_exposure": "duration",
            "menstrual_bleeding": "intensity"}.get(behaviour_id, "severity")


def dose_value(behaviour_id: str, answer: Answer, key: str) -> float | None:
    value = detail_value(answer, key)
    if value is None:
        return None
    if behaviour_id == "alcohol":
        return float(value) / 10
    if key == "duration":
        return float(value) / 60
    return float(value)


def continuous_exposure(values: dict[date, tuple[float, ...]], recorded: dict[date, datetime],
                        coding: str) -> Exposure:
    if not values:
        return Exposure(terms=("value",), values={}, exposed={}, recorded_at={}, coding=coding)
    middle = median(value[0] for value in values.values())
    return Exposure(terms=("value",), values=values,
                    exposed={day: value[0] > middle for day, value in values.items()},
                    recorded_at=recorded, coding=coding)


def binary_exposure(values: dict[date, bool]) -> Exposure:
    return Exposure(terms=("yes",), values={day: (1.0 if flag else 0.0,) for day, flag in values.items()},
                    exposed=dict(values), recorded_at={}, coding="binary")


def percentile(values: list[float], share: float) -> float | None:
    return float(np.quantile(values, share)) if values else None


def wearable_exposure(data: UserData, definition: InputDefinition, bedtime: float | None,
                      map_definition: BehaviourMap) -> Exposure:
    days = data.days()
    worn = {day for day in days if day in data.training_load}
    if definition.id == "training_load":
        return continuous_exposure({day: (data.training_load[day],) for day in worn}, {}, "continuous")
    if definition.id == "hard_training":
        cut = percentile([data.training_load[day] for day in worn if data.training_load[day] > 0],
                         map_definition.hard_band_percentile)
        if cut is None:
            return binary_exposure({})
        return binary_exposure({day: data.training_load[day] >= cut for day in worn})
    if definition.id == "workout_duration":
        return continuous_exposure({day: (sum(item.minutes for item in data.workouts.get(day, [])),)
                                    for day in worn}, {}, "continuous")
    if definition.id == "longest_session":
        cut = percentile([item.minutes for day in days for item in data.workouts.get(day, [])],
                         map_definition.hard_band_percentile)
        if cut is None:
            return binary_exposure({})
        return binary_exposure({day: max((item.minutes for item in data.workouts.get(day, [])),
                                         default=0) >= cut for day in worn})
    if definition.id == "workout_end_before_bed":
        values = {}
        for day in days:
            sessions = data.workouts.get(day, [])
            if sessions and bedtime is not None:
                latest = max(item.end for item in sessions).astimezone(data.zone).time()
                values[day] = ((bedtime - minutes_from_noon(latest)) / 60,)
        return continuous_exposure(values, {}, "continuous")
    if definition.id == "workout_type_strength":
        return binary_exposure({day: any(item.strength for item in data.workouts[day])
                                for day in days if data.workouts.get(day)})
    if definition.id == "steps":
        return continuous_exposure({day: (data.steps[day],) for day in days if day in data.steps},
                                   {}, "continuous")
    source = {"last_night_sleep_minutes": "minutes", "last_night_sleep_efficiency": "efficiency"}
    attribute = source[definition.id]
    return continuous_exposure({day: (getattr(data.sleeps[day], attribute),) for day in days
                                if day in data.sleeps and getattr(data.sleeps[day], attribute) is not None},
                               {}, "continuous")


def exposure_for(data: UserData, definition: InputDefinition, bedtime: float | None,
                 map_definition: BehaviourMap) -> Exposure:
    if definition.source == "journal":
        return journal_exposure(data, definition, bedtime, map_definition)
    return wearable_exposure(data, definition, bedtime, map_definition)


def physiology(data: UserData, outcome_id: str, wake_date: date) -> float | None:
    if outcome_id in ("sleep_minutes", "sleep_efficiency"):
        sleep = data.sleeps.get(wake_date)
        if sleep is None:
            return None
        return sleep.minutes if outcome_id == "sleep_minutes" else sleep.efficiency
    source = {"rhr": data.rhr, "hrv": data.hrv, "readiness": data.readiness}[outcome_id]
    return source.get(wake_date)


def rating_after(data: UserData, behaviour_id: str, journal_day: date, earliest: datetime | date) -> float | None:
    answer = data.answers.get((journal_day, behaviour_id))
    if answer is None or answer.value is None:
        return None
    if isinstance(earliest, datetime):
        return answer.value if answer.recorded_at >= earliest else None
    return answer.value if answer.recorded_at.astimezone(data.zone).date() >= earliest else None


def outcome_for(data: UserData, pair: Pair, day: date, lag: int, recorded_at: datetime | None) -> float | None:
    if pair.alignment == "after_answer":
        if recorded_at is None:
            return None
        nights = sorted((sleep.start, wake) for wake, sleep in data.sleeps.items()
                        if recorded_at < sleep.start <= recorded_at + FOLLOWING_NIGHT_WINDOW)
        return physiology(data, pair.outcome_id, nights[0][1]) if nights else None
    if pair.alignment == "morning_after_sleep":
        sleep = data.sleeps.get(day)
        if sleep is None:
            return None
        behaviour = RATING_OUTCOMES[pair.outcome_id]
        options = []
        for journal_day in (day - timedelta(days=1), day):
            answer = data.answers.get((journal_day, behaviour))
            if (answer is not None and answer.value is not None
                    and sleep.end <= answer.recorded_at <= sleep.end + RATING_WINDOW):
                options.append((answer.recorded_at, answer.value))
        return min(options)[1] if options else None
    target = day + timedelta(days=lag)
    if pair.outcome_id in RATING_OUTCOMES:
        sleep = data.sleeps.get(target)
        return rating_after(data, RATING_OUTCOMES[pair.outcome_id], target,
                            sleep.end if sleep else target)
    return physiology(data, pair.outcome_id, target)


def sick_days(data: UserData, map_definition: BehaviourMap) -> set[date]:
    if set(map_definition.sick_inputs) & data.turned_off:
        return set()
    sick = set()
    for day in data.days():
        fever = answered_yes(data, day, "fever")
        unwell = answered_yes(data, day, "feeling_unwell")
        after_substance = any(answered_yes(data, day - timedelta(days=1), item)
                              for item in map_definition.substance_inputs)
        if fever or (unwell and not after_substance):
            sick.add(day)
    return sick | {day - timedelta(days=1) for day in sick if day - timedelta(days=1) not in sick}


def answered_yes(data: UserData, day: date, behaviour_id: str) -> bool:
    answer = data.answers.get((day, behaviour_id))
    return answer is not None and bool(answer.value)


def shift_pattern(data: UserData, map_definition: BehaviourMap) -> tuple[str, set[date], set[date]]:
    answered = [day for day in data.days() if (day, "night_shift") in data.answers
                and data.answers[(day, "night_shift")].value is not None]
    shifts = {day for day in answered if answered_yes(data, day, "night_shift")}
    if not shifts:
        return "none", set(), set()
    if len(shifts) >= map_definition.frequent_shift_share * len(answered):
        return "frequent", shifts, set()
    removed = set(shifts)
    for day in shifts:
        for offset in range(1, map_definition.shift_rest_days + 1):
            following = day + timedelta(days=offset)
            if following not in shifts:
                removed.add(following)
    return "occasional", shifts, removed
