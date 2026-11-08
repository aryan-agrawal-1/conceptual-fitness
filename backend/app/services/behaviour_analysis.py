from __future__ import annotations

import logging
import time as clock
from dataclasses import dataclass, field
from datetime import date, timedelta

import numpy as np
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.security import utcnow
from app.models import BehaviourAnalysisResult, BehaviourAnalysisRun, JournalState
from app.services.behaviour_map import BEHAVIOUR_MAP_V1, BehaviourMap, Pair, tested_pairs
from app.services.behaviour_series import (
    RATING_OUTCOMES, TRAINING_INPUTS, Exposure, UserData, exposure_for, load_user_data,
    outcome_for, shift_pattern, sick_days, usual_bedtime,
)
from app.services.behaviour_stats import FitUnavailable, benjamini_hochberg, gls_ar1, ols, shrink
from app.services.health_dates import get_or_create_profile, local_date_for_profile


logger = logging.getLogger(__name__)

ALGORITHM_VERSION = "behaviour_engine_v1"
WINDOW_DAYS = 90
CHECKPOINT_DAYS = 30
CONSISTENT_DAYS = 90
MIN_OUTCOME_DAYS = 30
MIN_RECENT_OUTCOME_DAYS = 14
RECENT_DAYS = 30
PRELIMINARY_DAYS = 10
FINDING_DAYS = 18
PRELIMINARY_Q = 0.05
FINDING_Q = 0.10
OVERLAP_SUPPRESS = 0.8
OVERLAP_LABEL = 0.5
OVERLAP_MIN_DAYS = 10
PRIOR_SD_SHARE = 0.5
REVERSE_CHECK_P = 0.05
STAGE_ORDER = ("no_link", "preliminary", "possible", "consistent")
SETTINGS = dict(
    window_days=WINDOW_DAYS, checkpoint_days=CHECKPOINT_DAYS, consistent_days=CONSISTENT_DAYS,
    min_outcome_days=MIN_OUTCOME_DAYS, min_recent_outcome_days=MIN_RECENT_OUTCOME_DAYS,
    preliminary_days=PRELIMINARY_DAYS, finding_days=FINDING_DAYS, preliminary_q=PRELIMINARY_Q,
    finding_q=FINDING_Q, overlap_suppress=OVERLAP_SUPPRESS, overlap_label=OVERLAP_LABEL,
    prior_sd_share=PRIOR_SD_SHARE,
)


@dataclass
class Design:
    days: list[date]
    outcome: list[float]
    columns: list[str]
    matrix: list[list[float]]
    tested: tuple[int, ...]
    exposed: list[bool]
    excluded: list[dict]


@dataclass
class PairResult:
    pair: Pair
    stratum: str
    coding: str
    stage: str = "counts"
    suppression_reason: str | None = None
    held_reason: str | None = None
    exposed_days: int = 0
    comparison_days: int = 0
    estimates: list[dict] = field(default_factory=list)
    p_value: float | None = None
    q_value: float | None = None
    checks: dict = field(default_factory=dict)
    labels: list[str] = field(default_factory=list)
    included_dates: list[str] = field(default_factory=list)
    excluded_days: list[dict] = field(default_factory=list)
    tested: bool = False

    @property
    def key(self) -> tuple[str, str]:
        return self.pair.id, self.stratum


@dataclass(frozen=True)
class Context:
    data: UserData
    mapping: BehaviourMap
    exposures: dict[str, Exposure]
    sick: set[date]
    shift_mode: str
    shifts: set[date]
    shift_removed: set[date]
    training_mean: float
    training_sd: float


def primary(exposure: Exposure, day: date) -> float | None:
    values = exposure.values.get(day)
    return values[0] if values is not None else None


def build_design(context: Context, pair: Pair, stratum: str, lag: int, *,
                 remove_sick: bool = True, reverse: bool = False) -> Design:
    data, exposure = context.data, context.exposures[pair.input_id]
    include_training = (
        pair.input_id not in TRAINING_INPUTS
        and pair.outcome_id not in RATING_OUTCOMES
        and pair.alignment in ("next_day", "shift_day")
    )
    rows, excluded = [], []
    for day in data.days():
        values = exposure.values.get(day)
        if stratum != "all" and (day in context.shifts) != (stratum == "shift"):
            continue
        if pair.input_id != "night_shift" and day in context.shift_removed:
            excluded.append({"date": day.isoformat(), "reason": "shift_recovery"})
            continue
        span = [day + timedelta(days=offset) for offset in range(0, max(lag, 0) + 1)]
        if remove_sick and any(item in context.sick for item in span):
            excluded.append({"date": day.isoformat(), "reason": "sick_day"})
            continue
        if values is None:
            excluded.append({"date": day.isoformat(), "reason": "input_not_answered"})
            continue
        outcome = outcome_for(data, pair, day, 0 if reverse else lag, exposure.recorded_at.get(day))
        if outcome is None:
            excluded.append({"date": day.isoformat(), "reason": "outcome_missing"})
            continue
        recent = [primary(exposure, day - timedelta(days=offset)) for offset in (1, 2)]
        known = [item for item in recent if item is not None]
        row = {name: value for name, value in zip(exposure.terms, values)}
        row["recent"] = float(np.mean(known)) if known else 0.0
        row["recent_unknown"] = 0.0 if known else 1.0
        if lag == 2:
            following = day + timedelta(days=1)
            if pair.input_id in ("hard_training", "longest_session"):
                load = data.training_load.get(following)
                row["between"] = ((load - context.training_mean) / context.training_sd
                                  if load is not None else 0.0)
            else:
                load = primary(exposure, following)
                row["between"] = load if load is not None else 0.0
            row["between_unknown"] = 0.0 if load is not None else 1.0
        if include_training:
            load = data.training_load.get(day)
            row["training"] = (load - context.training_mean) / context.training_sd if load is not None else 0.0
            row["training_unknown"] = 0.0 if load is not None else 1.0
        night = day - timedelta(days=1) if pair.alignment == "morning_after_sleep" else day
        row["journal_weekend_night"] = 1.0 if night.weekday() in (4, 5) else 0.0
        row["drift"] = (day - data.start).days / 30
        rows.append((day, outcome, row, exposure.exposed.get(day, False)))
    if not rows:
        return Design([], [], [], [], (), [], excluded)
    names = list(exposure.terms) + [name for name in rows[0][2] if name not in exposure.terms]
    matrix = [[1.0] + [row[name] for name in names] for _, _, row, _ in rows]
    columns, matrix, tested = varying(["intercept"] + names, matrix, exposure.terms)
    return Design([day for day, *_ in rows], [outcome for _, outcome, *_ in rows], columns, matrix,
                  tested, [flag for *_, flag in rows], excluded)


def varying(columns: list[str], matrix: list[list[float]],
            terms: tuple[str, ...]) -> tuple[list[str], list[list[float]], tuple[int, ...]]:
    spread = {index for index in range(1, len(columns)) if len({line[index] for line in matrix}) > 1}
    kept_terms = [name for name in terms if columns.index(name) in spread] or [terms[0]]
    keep = [0] + [index for index in range(1, len(columns))
                  if index in spread and columns[index] not in terms
                  or columns[index] in kept_terms]
    columns = [columns[index] for index in keep]
    matrix = [[line[index] for index in keep] for line in matrix]
    return columns, matrix, tuple(columns.index(name) for name in kept_terms)


def ordinal_days(days: list[date]) -> list[int]:
    return [day.toordinal() for day in days]


def fit_design(design: Design):
    return gls_ar1(design.outcome, design.matrix, ordinal_days(design.days), design.tested)


def previous_value_check(design: Design):
    by_day = dict(zip(design.days, design.outcome))
    rows, outcomes = [], []
    for day, outcome, line in zip(design.days, design.outcome, design.matrix):
        previous = by_day.get(day - timedelta(days=1))
        if previous is not None:
            rows.append(line + [previous])
            outcomes.append(outcome)
    if not rows:
        raise FitUnavailable("insufficient_variation")
    terms = tuple(design.columns[index] for index in design.tested)
    columns, rows, tested = varying(design.columns + ["previous_outcome"], rows, terms)
    if len(tested) != len(design.tested):
        raise FitUnavailable("insufficient_variation")
    return ols(outcomes, rows, tested)


def outcome_valid_days(design: Design, window_end: date) -> tuple[int, int]:
    recent = [day for day in design.days if day > window_end - timedelta(days=RECENT_DAYS)]
    return len(design.days), len(recent)


def overlaps(context: Context) -> dict[str, list[tuple[str, float]]]:
    journal = {key: value for key, value in context.exposures.items()
               if context.mapping.input(key).source == "journal"}
    found: dict[str, list[tuple[str, float]]] = {key: [] for key in context.exposures}
    names = sorted(journal)
    for index, first in enumerate(names):
        for second in names[index + 1:]:
            common = sorted(set(journal[first].values) & set(journal[second].values))
            if len(common) < OVERLAP_MIN_DAYS:
                continue
            left = np.array([primary(journal[first], day) for day in common])
            right = np.array([primary(journal[second], day) for day in common])
            if left.std() == 0 or right.std() == 0:
                continue
            correlation = float(np.corrcoef(left, right)[0, 1])
            found[first].append((second, correlation))
            found[second].append((first, correlation))
    return found


def analyse_pair(context: Context, pair: Pair, stratum: str, window_end: date,
                 overlap: list[tuple[str, float]]) -> PairResult:
    definition = context.mapping.input(pair.input_id)
    exposure = context.exposures[pair.input_id]
    result = PairResult(pair=pair, stratum=stratum, coding=exposure.coding,
                        held_reason=definition.held_reason)
    if definition.two_way:
        result.labels.append("may_run_both_ways")
    if definition.favourable_review:
        result.labels.append("favourable_needs_review")
    design = build_design(context, pair, stratum, pair.lag_days)
    result.included_dates = [day.isoformat() for day in design.days]
    result.excluded_days = design.excluded
    result.exposed_days = sum(design.exposed)
    result.comparison_days = len(design.exposed) - result.exposed_days
    strong = [name for name, value in overlap if abs(value) >= OVERLAP_SUPPRESS]
    if strong:
        result.stage, result.suppression_reason = "suppressed", "overlaps_with:" + ",".join(sorted(strong))
        return result
    explained = [name for name, value in overlap if abs(value) >= OVERLAP_LABEL]
    if explained:
        result.labels.append("could_be_explained_by:" + ",".join(sorted(explained)))
    total, recent = outcome_valid_days(design, window_end)
    if total < MIN_OUTCOME_DAYS or recent < MIN_RECENT_OUTCOME_DAYS:
        result.stage, result.suppression_reason = "counts", "outcome_days_below_minimum"
        return result
    if min(result.exposed_days, result.comparison_days) < PRELIMINARY_DAYS:
        result.stage, result.suppression_reason = "counts", "exposure_days_below_minimum"
        return result
    try:
        fit = fit_design(design)
    except FitUnavailable as error:
        result.stage, result.suppression_reason = "suppressed", str(error)
        return result
    outcome_sd = float(np.std(design.outcome)) or 1.0
    for index, name in zip(design.tested, (design.columns[item] for item in design.tested)):
        position = design.tested.index(index)
        column = np.array([line[index] for line in design.matrix])
        scale = float(column.std()) if exposure.coding in ("continuous", "dose") or name == "hours_before_bed" else 1.0
        prior = PRIOR_SD_SHARE * outcome_sd / (scale or 1.0)
        estimate, error = fit.estimates[position], fit.standard_errors[position]
        result.estimates.append(dict(
            term=name, estimate=estimate, standard_error=error,
            interval=list(fit.intervals[position]), shrunk=shrink(estimate, error, prior),
            unit=context.mapping.outcome(pair.outcome_id).unit,
        ))
    result.p_value, result.tested = fit.p_value, True
    result.checks["model"] = dict(phi=fit.phi, observations=fit.observations,
                                  residual_sd=fit.residual_sd, columns=design.columns)
    result.checks["previous_value"] = check_agreement(design, fit)
    result.checks["without_sick_day_removal"] = alternative(
        context, pair, stratum, pair.lag_days, remove_sick=False)
    if pair.alignment == "next_day" and pair.outcome_id not in RATING_OUTCOMES:
        reverse = alternative(context, pair, stratum, 0, reverse=True)
        result.checks["reverse"] = reverse
        if reverse.get("p_value") is not None and reverse["p_value"] < REVERSE_CHECK_P:
            result.labels.append("may_run_both_ways")
    for lag in pair.sensitivity_lags:
        result.checks[f"d{lag}_sensitivity"] = alternative(context, pair, stratum, lag)
    result.labels = sorted(set(result.labels))
    return result


def alternative(context: Context, pair: Pair, stratum: str, lag: int, **options) -> dict:
    design = build_design(context, pair, stratum, lag, **options)
    try:
        fit = fit_design(design)
    except FitUnavailable as error:
        return dict(status=str(error))
    return dict(status="fitted", estimates=list(fit.estimates), p_value=fit.p_value,
                observations=fit.observations)


def check_agreement(design: Design, fit) -> dict:
    try:
        check = previous_value_check(design)
    except FitUnavailable as error:
        return dict(status=str(error))
    agrees = all(
        np.sign(main) == np.sign(other) and abs(main - other) <= 1.96 * error
        for main, other, error in zip(fit.estimates, check.estimates, fit.standard_errors)
    )
    return dict(status="fitted", estimates=list(check.estimates), p_value=check.p_value, agrees=bool(agrees))


def assign_stage(result: PairResult, tracking_day: int, earlier: dict | None) -> str:
    smallest = min(result.exposed_days, result.comparison_days)
    if smallest >= FINDING_DAYS and result.q_value <= FINDING_Q:
        stage = "possible"
        direction = np.sign(result.estimates[0]["estimate"])
        if tracking_day >= CONSISTENT_DAYS or (
            earlier is not None and earlier["stage"] in ("possible", "consistent")
            and earlier["direction"] == direction and earlier["non_overlapping"]
        ):
            stage = "consistent"
    elif result.q_value <= PRELIMINARY_Q:
        stage = "preliminary"
    else:
        stage = "no_link"
    if result.checks.get("previous_value", {}).get("agrees") is False and stage in ("possible", "consistent"):
        result.labels = sorted(set(result.labels) | {"models_disagree"})
        stage = STAGE_ORDER[STAGE_ORDER.index(stage) - 1]
    return stage


def correct(results: list[PairResult]) -> None:
    for tier in ("main", "exploratory"):
        family = [result for result in results if result.tested and result.pair.tier == tier]
        for result, adjusted in zip(family, benjamini_hochberg([item.p_value for item in family])):
            result.q_value = adjusted


def build_context(data: UserData, mapping: BehaviourMap) -> Context:
    bedtime = usual_bedtime(data)
    exposures = {
        definition.id: exposure_for(data, definition, bedtime, mapping)
        for definition in mapping.inputs
        if definition.id not in data.turned_off and not definition.description_only
    }
    shift_mode, shifts, removed = shift_pattern(data, mapping)
    loads = [data.training_load[day] for day in data.days() if day in data.training_load]
    return Context(
        data=data, mapping=mapping, exposures=exposures, sick=sick_days(data, mapping),
        shift_mode=shift_mode, shifts=shifts, shift_removed=removed,
        training_mean=float(np.mean(loads)) if loads else 0.0,
        training_sd=float(np.std(loads)) if loads and np.std(loads) > 0 else 1.0,
    )


def analyse(data: UserData, *, tracking_day: int, checkpoint: bool,
            previous: dict[tuple[str, str], dict], earlier: dict[tuple[str, str], dict],
            mapping: BehaviourMap = BEHAVIOUR_MAP_V1) -> list[PairResult]:
    context = build_context(data, mapping)
    overlap = overlaps(context)
    results = []
    for pair in tested_pairs(mapping):
        if pair.input_id not in context.exposures:
            continue
        strata = ("shift", "off") if context.shift_mode == "frequent" and pair.input_id != "night_shift" else ("all",)
        for stratum in strata:
            results.append(analyse_pair(context, pair, stratum, data.end, overlap.get(pair.input_id, [])))
    correct(results)
    for result in results:
        if not result.tested:
            continue
        fresh = assign_stage(result, tracking_day, earlier.get(result.key))
        if checkpoint:
            result.stage = fresh
        else:
            carried = previous.get(result.key, {}).get("stage", "awaiting_checkpoint")
            result.stage = carried if carried in STAGE_ORDER else "awaiting_checkpoint"
            if fresh == "no_link" and carried in STAGE_ORDER[1:]:
                result.labels = sorted(set(result.labels) | {"weaker_since_checkpoint"})
    return results


def latest_runs(session: Session, user_id: str) -> tuple[BehaviourAnalysisRun | None, list[BehaviourAnalysisRun]]:
    runs = session.scalars(select(BehaviourAnalysisRun).where(
        BehaviourAnalysisRun.user_id == user_id, BehaviourAnalysisRun.status == "completed",
        BehaviourAnalysisRun.algorithm_version == ALGORITHM_VERSION,
        BehaviourAnalysisRun.map_version == BEHAVIOUR_MAP_V1.version,
    ).order_by(BehaviourAnalysisRun.started_at.desc())).all()
    checkpoints = [run for run in runs if run.checkpoint_day is not None and run.trigger == "checkpoint"]
    return (runs[0] if runs else None), checkpoints


def stage_lookup(session: Session, run: BehaviourAnalysisRun | None) -> dict[tuple[str, str], dict]:
    if run is None:
        return {}
    return {
        (row.pair_id, row.stratum): dict(
            stage=row.stage,
            direction=np.sign(row.estimates[0]["estimate"]) if row.estimates else 0,
        )
        for row in session.scalars(select(BehaviourAnalysisResult).where(
            BehaviourAnalysisResult.run_id == run.id,
        ))
    }


def due_checkpoint(tracking_day: int) -> int | None:
    if tracking_day < CHECKPOINT_DAYS:
        return None
    return tracking_day // CHECKPOINT_DAYS * CHECKPOINT_DAYS


def run_analysis(session: Session, user_id: str, *, trigger: str, today: date | None = None) -> BehaviourAnalysisRun:
    started = clock.monotonic()
    profile = get_or_create_profile(session, user_id)
    today = today or local_date_for_profile(profile)
    window_end = today - timedelta(days=1)
    window_start = window_end - timedelta(days=WINDOW_DAYS - 1)
    state = session.get(JournalState, user_id)
    data = load_user_data(session, user_id, window_start, window_end)
    tracking_day = (today - data.first_day).days if data.first_day else 0
    checkpoint_day = due_checkpoint(tracking_day)
    _, checkpoints = latest_runs(session, user_id)
    last_checkpoint = checkpoints[0] if checkpoints else None
    is_checkpoint = checkpoint_day is not None and (
        last_checkpoint is None or last_checkpoint.checkpoint_day < checkpoint_day
    )
    earlier_run = next((run for run in checkpoints
                        if run.window_end <= window_start - timedelta(days=1)), None)
    earlier = {key: {**value, "non_overlapping": True}
               for key, value in stage_lookup(session, earlier_run).items()}
    run = BehaviourAnalysisRun(
        user_id=user_id, algorithm_version=ALGORITHM_VERSION, map_version=BEHAVIOUR_MAP_V1.version,
        catalogue_version=BEHAVIOUR_MAP_V1.catalogue_version,
        trigger="checkpoint" if is_checkpoint else trigger,
        window_start=window_start, window_end=window_end, tracking_day=tracking_day,
        checkpoint_day=checkpoint_day if is_checkpoint else (
            last_checkpoint.checkpoint_day if last_checkpoint else None),
        analysis_revision=state.analysis_revision if state else 0, settings=SETTINGS,
    )
    session.add(run)
    session.flush()
    try:
        results = analyse(
            data, tracking_day=tracking_day, checkpoint=is_checkpoint,
            previous=stage_lookup(session, last_checkpoint), earlier=earlier,
        )
    except Exception:
        run.status, run.error_code, run.completed_at = "failed", "analysis_error", utcnow()
        session.commit()
        logger.exception("Behaviour analysis failed run=%s trigger=%s", run.id, run.trigger)
        raise
    for result in results:
        session.add(BehaviourAnalysisResult(
            run_id=run.id, user_id=user_id, pair_id=result.pair.id, input_id=result.pair.input_id,
            outcome_id=result.pair.outcome_id, lag_days=result.pair.lag_days, tier=result.pair.tier,
            stratum=result.stratum, stage=result.stage, suppression_reason=result.suppression_reason,
            held_reason=result.held_reason, coding=result.coding, exposed_days=result.exposed_days,
            comparison_days=result.comparison_days, estimates=result.estimates,
            p_value=result.p_value, q_value=result.q_value, checks=result.checks,
            labels=result.labels, included_dates=result.included_dates,
            excluded_days=result.excluded_days,
        ))
    run.status, run.completed_at = "completed", utcnow()
    if state is not None and state.analysis_revision == run.analysis_revision:
        state.analysis_dirty_from = None
    session.commit()
    logger.info(
        "Behaviour analysis completed run=%s trigger=%s pairs=%d tested=%d checkpoint=%s seconds=%.2f",
        run.id, run.trigger, len(results), sum(result.tested for result in results),
        run.checkpoint_day, clock.monotonic() - started,
    )
    return run


def needs_run(session: Session, user_id: str, today: date) -> str | None:
    state = session.get(JournalState, user_id)
    if state is None:
        return None
    latest, checkpoints = latest_runs(session, user_id)
    if latest is None or latest.analysis_revision != state.analysis_revision:
        return "edit"
    tracking_day = latest.tracking_day + (today - latest.window_end - timedelta(days=1)).days
    checkpoint_day = due_checkpoint(tracking_day)
    if checkpoint_day is not None and (not checkpoints or checkpoints[0].checkpoint_day < checkpoint_day):
        return "checkpoint"
    if today - latest.window_end > timedelta(days=7):
        return "weekly"
    return None
