from __future__ import annotations

from collections import Counter, defaultdict
from datetime import date, timedelta
from statistics import mean
from typing import Any

from fastapi import APIRouter, HTTPException, Query
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession
from app.api.routes.metrics import _workout_summary_payload
from app.models import DailyScore, StrainTarget, Workout
from app.services.health_dates import get_or_create_profile, local_date_for_profile, local_week_start
from app.services.scores import (
    READINESS_SCORE_VERSION,
    SCORE_VERSIONS,
    STRAIN_LOAD_VERSION,
    _adjusted_sleep_need_minutes,
    _main_sleep,
    rebuild_derived_scores,
)


router = APIRouter(tags=["scores"])

# get all daily scores
@router.get("/scores/daily")
def daily_scores(
    session: DbSession,
    user: CurrentUser,
    start: date = Query(...),
    end: date = Query(...),
) -> list[dict[str, object]]:
    scores = session.scalars(
        select(DailyScore)
        .where(
            DailyScore.user_id == user.id,
            DailyScore.score_date >= start,
            DailyScore.score_date <= end,
        )
        .order_by(DailyScore.score_date, DailyScore.score_type)
    ).all()
    return [_score_payload(score) for score in scores]

# rebuild scores for a day
@router.post("/scores/rebuild")
def rebuild_scores(
    session: DbSession,
    user: CurrentUser,
    start: date = Query(...),
    end: date = Query(...),
) -> dict[str, object]:
    result = rebuild_derived_scores(session, user_id=user.id, start=start, end=end)
    session.commit()
    return {
        "user_id": result.user_id,
        "start": result.start,
        "end": result.end,
        "scores_rebuilt": result.scores_rebuilt,
        "baselines_rebuilt": result.baselines_rebuilt,
        "targets_rebuilt": result.targets_rebuilt,
    }

# get score history for a certain interval
@router.get("/scores/{score_type}")
def score_history(
    session: DbSession,
    user: CurrentUser,
    score_type: str,
    start: date = Query(...),
    end: date = Query(...),
) -> list[dict[str, object]]:
    if score_type not in SCORE_VERSIONS:
        raise HTTPException(status_code=404, detail="Unknown score type")
    scores = session.scalars(
        select(DailyScore)
        .where(
            DailyScore.user_id == user.id,
            DailyScore.score_type == score_type,
            DailyScore.algorithm_version == SCORE_VERSIONS[score_type],
            DailyScore.score_date >= start,
            DailyScore.score_date <= end,
        )
        .order_by(DailyScore.score_date)
    ).all()
    return [_score_payload(score) for score in scores]

# get strain targets for a certain interval
@router.get("/strain/targets")
def strain_targets(
    session: DbSession,
    user: CurrentUser,
    start: date = Query(...),
    end: date = Query(...),
) -> list[dict[str, object]]:
    start_week = local_week_start(start)
    end_week = local_week_start(end)
    targets = session.scalars(
        select(StrainTarget)
        .where(
            StrainTarget.user_id == user.id,
            StrainTarget.algorithm_version == STRAIN_LOAD_VERSION,
            StrainTarget.week_start_date >= start_week,
            StrainTarget.week_start_date <= end_week,
        )
        .order_by(StrainTarget.week_start_date)
    ).all()
    return [_target_payload(target) for target in targets]


@router.get("/strain/detail")
def strain_detail(
    session: DbSession,
    user: CurrentUser,
    selected_date: date | None = Query(default=None, alias="date"),
    timeframe: str = Query(default="week", pattern="^(day|week|month|year)$"),
) -> dict[str, object]:
    profile = get_or_create_profile(session, user.id)
    anchor = selected_date or local_date_for_profile(profile)
    start, end = _strain_window(anchor, timeframe)
    scores = _strain_scores(session, user.id, start, end)
    targets = _strain_targets_for_window(session, user.id, start, end)
    workouts = _strain_workouts(session, user.id, start, end)
    component_items = _strain_component_items(scores)
    target_band_counts = Counter(target.load_band for target in targets if target.load_band)
    summary = _strain_detail_summary(timeframe, scores, targets, start, end)
    if timeframe in {"month", "year"} and target_band_counts:
        summary["load_band"] = target_band_counts.most_common(1)[0][0]
    chart = _strain_chart(timeframe, scores, targets, start, end)
    workout_contributions = _workout_contributions_for_scores(scores)
    contributor_workouts = workouts if timeframe in {"month", "year"} else workouts[:25]

    return {
        "timeframe": timeframe,
        "start": start,
        "end": end,
        "summary": summary,
        "chart": chart,
        "components": {
            "items": component_items,
            "total_load_points": round(sum(item["load_points"] for item in component_items), 2),
        },
        "training_context": _strain_training_context(timeframe, scores, targets, target_band_counts),
        "guidance": _strain_guidance(timeframe, summary, target_band_counts),
        "contributors": _strain_contributor_payloads(
            session,
            user.id,
            profile,
            contributor_workouts,
            workout_contributions,
        ),
        "data_quality": _strain_data_quality(scores, start, end),
    }


@router.get("/readiness/detail")
def readiness_detail(
    session: DbSession,
    user: CurrentUser,
    selected_date: date | None = Query(default=None, alias="date"),
    timeframe: str = Query(default="week", pattern="^(day|week|month|year)$"),
) -> dict[str, object]:
    profile = get_or_create_profile(session, user.id)
    anchor = selected_date or local_date_for_profile(profile)
    start, end = _strain_window(anchor, timeframe)
    scores = _readiness_scores(session, user.id, start, end)
    summary = _readiness_detail_summary(timeframe, scores, start, end)

    return {
        "timeframe": timeframe,
        "start": start,
        "end": end,
        "summary": summary,
        "chart": _readiness_chart(timeframe, scores, start, end),
        "components": _readiness_components(scores),
        "context": _readiness_context(session, user.id, profile, timeframe, scores, start, end),
        "guidance": _readiness_guidance(timeframe, summary, scores),
        "reasons": _readiness_reasons_payload(scores),
        "data_quality": _readiness_data_quality(scores, start, end),
    }


def _score_payload(score: DailyScore) -> dict[str, object]:
    return {
        "date": score.score_date,
        "score_type": score.score_type,
        "algorithm_version": score.algorithm_version,
        "value": score.value,
        "unit": score.value_unit,
        "status": score.status.value,
        "confidence_phase": score.confidence_phase,
        "data_quality": score.data_quality,
        "components": score.components,
        "inputs": score.inputs,
        "reasons": score.reasons,
        "computed_at": score.computed_at,
    }


def _target_payload(target: StrainTarget) -> dict[str, object]:
    return {
        "week_start_date": target.week_start_date,
        "algorithm_version": target.algorithm_version,
        "target_load_points": target.target_load_points,
        "chronic_load_points": target.chronic_load_points,
        "acute_load_points": target.acute_load_points,
        "progress_load_points": target.progress_load_points,
        "progress_ratio": target.progress_ratio,
        "load_band": target.load_band,
        "confidence_phase": target.confidence_phase,
        "components": target.components,
        "inputs": target.inputs,
        "computed_at": target.computed_at,
    }


def _strain_window(anchor: date, timeframe: str) -> tuple[date, date]:
    if timeframe == "day":
        return anchor, anchor
    if timeframe == "week":
        start = local_week_start(anchor)
        return start, start + timedelta(days=6)
    if timeframe == "month":
        start = anchor.replace(day=1)
        next_month = (
            date(anchor.year + 1, 1, 1)
            if anchor.month == 12
            else date(anchor.year, anchor.month + 1, 1)
        )
        return start, next_month - timedelta(days=1)
    start = date(anchor.year, 1, 1)
    return start, date(anchor.year, 12, 31)


def _strain_scores(session: DbSession, user_id: str, start: date, end: date) -> list[DailyScore]:
    return session.scalars(
        select(DailyScore)
        .where(
            DailyScore.user_id == user_id,
            DailyScore.score_type == "strain",
            DailyScore.algorithm_version == STRAIN_LOAD_VERSION,
            DailyScore.score_date >= start,
            DailyScore.score_date <= end,
        )
        .order_by(DailyScore.score_date)
    ).all()


def _readiness_scores(session: DbSession, user_id: str, start: date, end: date) -> list[DailyScore]:
    return session.scalars(
        select(DailyScore)
        .where(
            DailyScore.user_id == user_id,
            DailyScore.score_type == "readiness",
            DailyScore.algorithm_version == READINESS_SCORE_VERSION,
            DailyScore.score_date >= start,
            DailyScore.score_date <= end,
        )
        .order_by(DailyScore.score_date)
    ).all()


def _strain_targets_for_window(
    session: DbSession,
    user_id: str,
    start: date,
    end: date,
) -> list[StrainTarget]:
    return session.scalars(
        select(StrainTarget)
        .where(
            StrainTarget.user_id == user_id,
            StrainTarget.algorithm_version == STRAIN_LOAD_VERSION,
            StrainTarget.week_start_date >= local_week_start(start),
            StrainTarget.week_start_date <= local_week_start(end),
        )
        .order_by(StrainTarget.week_start_date)
    ).all()


def _strain_workouts(session: DbSession, user_id: str, start: date, end: date) -> list[Workout]:
    return session.scalars(
        select(Workout)
        .where(
            Workout.user_id == user_id,
            Workout.civil_date >= start,
            Workout.civil_date <= end,
        )
        .order_by(Workout.start_time.desc())
    ).all()


def _strain_detail_summary(
    timeframe: str,
    scores: list[DailyScore],
    targets: list[StrainTarget],
    start: date,
    end: date,
) -> dict[str, object]:
    total = _score_total(scores)
    valid_scores = [score for score in scores if score.value is not None]
    current_target = targets[-1] if targets else None
    summary: dict[str, object] = {
        "load_points": round(total, 2),
        "target_load_points": current_target.target_load_points if current_target else None,
        "progress_ratio": current_target.progress_ratio if current_target else None,
        "load_band": current_target.load_band if current_target else None,
        "valid_days": len(valid_scores),
    }
    if timeframe == "day":
        score = scores[0] if scores else None
        summary.update(
            {
                "title": "Daily strain load",
                "primary_value": score.value if score else None,
                "status": score.status.value if score else "missing_data",
                "data_quality": score.data_quality if score else "missing",
            }
        )
        return summary
    if timeframe == "week":
        summary.update(
            {
                "title": "Weekly load",
                "primary_value": total,
                "progress_load_points": current_target.progress_load_points if current_target else total,
                "chronic_load_points": current_target.chronic_load_points if current_target else None,
                "acute_load_points": current_target.acute_load_points if current_target else total,
            }
        )
        return summary

    weekly_totals = _weekly_totals(scores)
    average_weekly_load = mean(weekly_totals.values()) if weekly_totals else None
    summary.update(
        {
            "title": "Average weekly load",
            "primary_value": round(average_weekly_load, 2) if average_weekly_load is not None else None,
            "average_weekly_load": round(average_weekly_load, 2) if average_weekly_load is not None else None,
            "week_count": len(weekly_totals),
            "period_days": (end - start).days + 1,
        }
    )
    return summary


def _strain_chart(
    timeframe: str,
    scores: list[DailyScore],
    targets: list[StrainTarget],
    start: date,
    end: date,
) -> dict[str, object]:
    if timeframe == "day":
        return {
            "kind": "component_bar",
            "points": _strain_component_items(scores),
        }
    if timeframe == "week":
        by_date = {score.score_date: score for score in scores}
        target = targets[-1] if targets else None
        points = []
        day = start
        while day <= end:
            score = by_date.get(day)
            points.append(
                {
                    "date": day,
                    "load_points": score.value if score else None,
                    "status": score.status.value if score else "missing_data",
                    "components": _strain_component_map(score),
                }
            )
            day += timedelta(days=1)
        return {
            "kind": "daily_bars",
            "target_load_points": target.target_load_points if target else None,
            "progress_ratio": target.progress_ratio if target else None,
            "points": points,
        }
    if timeframe == "month":
        targets_by_week = {target.week_start_date: target for target in targets}
        points = []
        for week_start, load in sorted(_weekly_totals(scores).items()):
            target = targets_by_week.get(week_start)
            points.append(
                {
                    "week_start_date": week_start,
                    "load_points": round(load, 2),
                    "target_load_points": target.target_load_points if target else None,
                    "progress_ratio": target.progress_ratio if target else None,
                    "load_band": target.load_band if target else "unknown",
                }
            )
        return {"kind": "weekly_bars", "points": points}

    points = []
    scores_by_month: dict[date, list[DailyScore]] = defaultdict(list)
    for score in scores:
        scores_by_month[date(score.score_date.year, score.score_date.month, 1)].append(score)
    for month_start, month_scores in sorted(scores_by_month.items()):
        weekly_totals = _weekly_totals(month_scores)
        average_weekly_load = mean(weekly_totals.values()) if weekly_totals else None
        points.append(
            {
                "month_start_date": month_start,
                "average_weekly_load": round(average_weekly_load, 2)
                if average_weekly_load is not None
                else None,
                "total_load_points": round(_score_total(month_scores), 2),
            }
        )
    return {"kind": "monthly_average_weekly_load", "points": points}


def _strain_component_items(scores: list[DailyScore]) -> list[dict[str, object]]:
    labels = {
        "workouts": "Workouts",
        "general_activity": "General activity",
    }
    totals = {key: 0.0 for key in labels}
    for score in scores:
        split = _user_facing_load_split(score.components or {})
        totals["workouts"] += split["workouts"]
        totals["general_activity"] += split["general_activity"]
    total = sum(totals.values())
    return [
        {
            "key": key,
            "label": label,
            "load_points": round(value, 2),
            "share": round(value / total, 3) if total else None,
        }
        for key, label in labels.items()
        if (value := round(totals[key], 2))
    ]


def _user_facing_load_split(components: dict[str, Any]) -> dict[str, float]:
    cardio = components.get("cardio_load")
    source_zone = components.get("source_zone_load")
    daily_activity = _component_load(components.get("daily_activity_load"))
    muscular = _component_load(components.get("muscular_load"))
    workout_load = muscular
    general_activity_load = daily_activity

    if isinstance(cardio, dict):
        cardio_total = _component_load(cardio)
        cardio_workout = cardio.get("workout_load_points")
        cardio_general = cardio.get("general_activity_load_points")
        if isinstance(cardio_workout, int | float) or isinstance(cardio_general, int | float):
            workout_load += float(cardio_workout or 0.0)
            general_activity_load += float(cardio_general or 0.0)
        else:
            workout_ratio = cardio.get("workout_coverage_ratio")
            ratio = float(workout_ratio) if isinstance(workout_ratio, int | float) else 0.0
            ratio = max(0.0, min(1.0, ratio))
            workout_load += cardio_total * ratio
            general_activity_load += cardio_total * (1 - ratio)

    source_zone_load = _component_load(source_zone)
    if isinstance(source_zone, dict):
        zone_workout = source_zone.get("workout_load_points")
        zone_general = source_zone.get("general_activity_load_points")
        if isinstance(zone_workout, int | float) or isinstance(zone_general, int | float):
            workout_load += float(zone_workout or 0.0)
            general_activity_load += float(zone_general or 0.0)
        elif source_zone.get("source") == "provider_zones":
            workout_load += source_zone_load
        else:
            general_activity_load += source_zone_load

    return {
        "workouts": workout_load,
        "general_activity": general_activity_load,
    }


def _workout_contributions_for_scores(scores: list[DailyScore]) -> dict[str, dict[str, object]]:
    contributions: dict[str, dict[str, object]] = {}
    for score in scores:
        for item in (score.components or {}).get("workout_contributions") or []:
            if not isinstance(item, dict):
                continue
            workout_id = item.get("workout_id")
            load = item.get("load_points")
            if not workout_id or not isinstance(load, int | float):
                continue
            contribution = contributions.setdefault(
                str(workout_id),
                {
                    "strain_load_points": 0.0,
                    "strain_components": {},
                },
            )
            contribution["strain_load_points"] += float(load)
            components = item.get("components")
            if isinstance(components, dict):
                for key, value in components.items():
                    if isinstance(value, int | float):
                        contribution["strain_components"][key] = round(
                            contribution["strain_components"].get(key, 0.0) + float(value),
                            2,
                        )
    return {
        workout_id: {
            "strain_load_points": round(value["strain_load_points"], 2),
            "strain_components": value["strain_components"],
        }
        for workout_id, value in contributions.items()
    }


def _strain_contributor_payloads(
    session: DbSession,
    user_id: str,
    profile: Any,
    workouts: list[Workout],
    workout_contributions: dict[str, dict[str, object]],
) -> list[dict[str, object]]:
    payloads = []
    for workout in workouts:
        payload = _workout_summary_payload(session, user_id, profile, workout)
        contribution = workout_contributions.get(workout.id)
        if contribution is not None:
            payload.update(contribution)
        payloads.append(payload)
    return payloads


def _strain_component_map(score: DailyScore | None) -> dict[str, float]:
    if score is None:
        return {}
    return {
        item["key"]: item["load_points"]
        for item in _strain_component_items([score])
    }


def _component_load(value: Any) -> float:
    if isinstance(value, dict):
        load = value.get("load_points")
        return float(load) if isinstance(load, int | float) else 0.0
    return 0.0


def _weekly_totals(scores: list[DailyScore]) -> dict[date, float]:
    totals: dict[date, float] = defaultdict(float)
    for score in scores:
        if score.value is not None:
            totals[local_week_start(score.score_date)] += score.value
    return dict(totals)


def _score_total(scores: list[DailyScore]) -> float:
    return sum(score.value for score in scores if score.value is not None)


def _strain_training_context(
    timeframe: str,
    scores: list[DailyScore],
    targets: list[StrainTarget],
    target_band_counts: Counter,
) -> dict[str, object]:
    latest_target = targets[-1] if targets else None
    return {
        "timeframe": timeframe,
        "total_load_points": round(_score_total(scores), 2),
        "average_daily_load": round(mean([score.value for score in scores if score.value is not None]), 2)
        if any(score.value is not None for score in scores)
        else None,
        "latest_target_load_points": latest_target.target_load_points if latest_target else None,
        "latest_chronic_load_points": latest_target.chronic_load_points if latest_target else None,
        "latest_load_band": latest_target.load_band if latest_target else None,
        "target_band_counts": dict(target_band_counts),
    }


def _strain_guidance(
    timeframe: str,
    summary: dict[str, object],
    target_band_counts: Counter,
) -> dict[str, object]:
    band = summary.get("load_band")
    if timeframe == "day":
        text = "Use today's load alongside your weekly target and readiness before deciding whether to add more strain."
    elif timeframe in {"month", "year"} and target_band_counts:
        common_band = target_band_counts.most_common(1)[0][0]
        text = f"Most completed weeks were {common_band.replace('_', ' ')}. Use that pattern to judge consistency, not a single high day."
    elif band == "below":
        text = "You are below your usual weekly load. Build gradually if recovery and schedule support it."
    elif band == "steady":
        text = "You are tracking inside your usual weekly range. Maintain the plan unless readiness suggests backing off."
    elif band == "above":
        text = "This load is above your recent normal. Add more only if this is an intentional push week."
    elif band == "well_above":
        text = "You are well above your usual load. Prioritize recovery or easy movement unless this spike is planned."
    else:
        text = "Keep building enough load for progress without turning every day into a hard day."
    return {"message": text}


def _strain_data_quality(scores: list[DailyScore], start: date, end: date) -> dict[str, object]:
    expected_days = (end - start).days + 1
    valid_scores = [score for score in scores if score.value is not None]
    quality_counts = Counter(score.data_quality for score in scores if score.data_quality)
    confidence_counts = Counter(score.confidence_phase for score in scores if score.confidence_phase)
    covered_minutes = 0.0
    long_gap_count = 0
    for score in scores:
        cardio = (score.components or {}).get("cardio_load")
        if isinstance(cardio, dict):
            covered = cardio.get("covered_minutes")
            gaps = cardio.get("long_gap_count")
            if isinstance(covered, int | float):
                covered_minutes += float(covered)
            if isinstance(gaps, int):
                long_gap_count += gaps
    return {
        "expected_days": expected_days,
        "scored_days": len(valid_scores),
        "completeness": round(len(valid_scores) / expected_days, 3) if expected_days else None,
        "quality_counts": dict(quality_counts),
        "confidence_counts": dict(confidence_counts),
        "heart_rate_covered_minutes": round(covered_minutes, 1),
        "long_gap_count": long_gap_count,
    }


def _readiness_detail_summary(
    timeframe: str,
    scores: list[DailyScore],
    start: date,
    end: date,
) -> dict[str, object]:
    valid_scores = [score for score in scores if score.value is not None]
    values = [float(score.value) for score in valid_scores if score.value is not None]
    latest = _latest_score(scores)
    average_score = round(mean(values), 1) if values else None
    low_days = sum(1 for value in values if value < 60)
    high_days = sum(1 for value in values if value >= 80)
    trend = _readiness_period_trend(timeframe, valid_scores, values)
    summary: dict[str, object] = {
        "title": "Readiness",
        "primary_value": latest.value if timeframe == "day" and latest else average_score,
        "average_score": average_score,
        "latest_score": latest.value if latest else None,
        "status": latest.status.value if latest else "missing_data",
        "readiness_band": _readiness_band((latest.value if latest else None) or average_score),
        "trend": trend,
        "valid_days": len(valid_scores),
        "period_days": (end - start).days + 1,
        "low_days": low_days,
        "high_days": high_days,
    }
    if timeframe == "day":
        summary["title"] = "Daily readiness"
        summary["data_quality"] = latest.data_quality if latest else "missing"
    elif timeframe == "week":
        summary["title"] = "Weekly readiness"
    elif timeframe == "month":
        summary["title"] = "Monthly readiness"
    else:
        summary["title"] = "Yearly readiness"
    return summary


def _readiness_chart(
    timeframe: str,
    scores: list[DailyScore],
    start: date,
    end: date,
) -> dict[str, object]:
    if timeframe == "day":
        return {
            "kind": "component_scores",
            "points": _readiness_component_items(_latest_score(scores)),
        }
    if timeframe in {"week", "month"}:
        scores_by_date = {score.score_date: score for score in scores}
        points = []
        day = start
        while day <= end:
            score = scores_by_date.get(day)
            points.append(_readiness_daily_point(day, score))
            day += timedelta(days=1)
        return {"kind": "daily_line", "points": points}

    scores_by_month: dict[date, list[DailyScore]] = defaultdict(list)
    for score in scores:
        scores_by_month[date(score.score_date.year, score.score_date.month, 1)].append(score)
    points = []
    month = date(start.year, 1, 1)
    while month <= date(start.year, 12, 1):
        month_scores = scores_by_month.get(month, [])
        values = [float(score.value) for score in month_scores if score.value is not None]
        points.append(
            {
                "month_start_date": month,
                "average_score": round(mean(values), 1) if values else None,
                "low_days": sum(1 for value in values if value < 60),
                "high_days": sum(1 for value in values if value >= 80),
                "scored_days": len(values),
            }
        )
        month = date(month.year + 1, 1, 1) if month.month == 12 else date(month.year, month.month + 1, 1)
    return {"kind": "monthly_average_scores", "points": points}


def _readiness_daily_point(day: date, score: DailyScore | None) -> dict[str, object]:
    return {
        "date": day,
        "score": score.value if score else None,
        "status": score.status.value if score else "missing_data",
        "readiness_band": _readiness_band(score.value if score else None),
        "data_quality": score.data_quality if score else "missing",
    }


def _readiness_components(scores: list[DailyScore]) -> dict[str, object]:
    valid_scores = [score for score in scores if score.value is not None]
    latest = _latest_scored_score(scores) or _latest_score(scores)
    latest_items = _readiness_component_items(latest)
    averages: dict[str, list[float]] = defaultdict(list)
    for score in valid_scores:
        for item in _readiness_component_items(score):
            component_score = item.get("score")
            if isinstance(component_score, int | float):
                averages[item["key"]].append(float(component_score))
    return {
        "items": latest_items,
        "average_items": [
            {
                "key": key,
                "label": _READINESS_COMPONENT_LABELS.get(key, key.replace("_", " ").title()),
                "score": round(mean(values), 1),
            }
            for key, values in averages.items()
            if values
        ],
    }


def _readiness_component_items(score: DailyScore | None) -> list[dict[str, object]]:
    if score is None:
        return []
    components = score.components or {}
    items = []
    for key, label in _READINESS_COMPONENT_LABELS.items():
        raw = components.get(key)
        if not isinstance(raw, dict):
            continue
        component_score = raw.get("score")
        if not isinstance(component_score, int | float):
            continue
        item: dict[str, object] = {
            "key": key,
            "label": label,
            "score": round(float(component_score), 1),
            "weight": _READINESS_COMPONENT_WEIGHTS.get(key),
            "message": _readiness_component_message(key, raw),
        }
        detail = _readiness_component_detail(key, raw)
        if detail:
            item["detail"] = detail
        items.append(item)
    return items


def _readiness_component_message(key: str, component: dict[str, Any]) -> str | None:
    if key == "sleep_adequacy_debt":
        debt = component.get("sleep_debt_minutes_7d")
        if isinstance(debt, int | float):
            hours = round(float(debt) / 60, 1)
            return f"7-day sleep debt is {hours:g}h."
    if key == "autonomic_recovery":
        trend_penalty = component.get("trend_penalty")
        if isinstance(trend_penalty, int | float) and trend_penalty > 0:
            return f"Autonomic trend penalty is {round(float(trend_penalty), 1):g} points."
        return "HRV and resting heart rate are compared with your baseline."
    if key == "recent_load_fit":
        ratio = component.get("load_ratio")
        if isinstance(ratio, int | float):
            return f"Recent load is {round(float(ratio), 2):g}x your comparison window."
        return "Recent strain history is still calibrating."
    if key == "illness_anomaly_context":
        anomalies = component.get("anomalies")
        if isinstance(anomalies, list) and anomalies:
            return f"{len(anomalies)} recovery anomaly signals detected."
        return "No major anomaly signals detected."
    if key == "confidence":
        phase = component.get("phase")
        if isinstance(phase, str):
            return f"Personalization phase: {phase.replace('_', ' ')}."
    return None


def _readiness_component_detail(key: str, component: dict[str, Any]) -> dict[str, object]:
    if key == "autonomic_recovery":
        detail: dict[str, object] = {}
        hrv = component.get("hrv")
        rhr = component.get("rhr")
        if isinstance(hrv, dict):
            detail["hrv_score"] = hrv.get("score")
        if isinstance(rhr, dict):
            detail["rhr_score"] = rhr.get("score")
        return detail
    if key == "recent_load_fit":
        return {
            "load_ratio": component.get("load_ratio"),
            "yesterday_load": component.get("yesterday_load"),
            "valid_strain_days": component.get("valid_strain_days"),
        }
    if key == "illness_anomaly_context":
        return {
            "anomalies": component.get("anomalies") or [],
            "readiness_cap": component.get("readiness_cap"),
        }
    return {}


def _readiness_context(
    session: DbSession,
    user_id: str,
    profile: Any,
    timeframe: str,
    scores: list[DailyScore],
    start: date,
    end: date,
) -> dict[str, object]:
    valid_scores = [score for score in scores if score.value is not None]
    latest = _latest_scored_score(scores) or _latest_score(scores)
    components = latest.components if latest and latest.components else {}
    sleep = components.get("sleep_adequacy_debt") if isinstance(components.get("sleep_adequacy_debt"), dict) else {}
    anomaly = components.get("illness_anomaly_context") if isinstance(components.get("illness_anomaly_context"), dict) else {}
    hrv = _average_readiness_metric_context(valid_scores, "hrv", higher_is_better=True)
    rhr = _average_readiness_metric_context(valid_scores, "rhr", higher_is_better=False)
    load_ratio = _average_readiness_component_value(valid_scores, "recent_load_fit", "load_ratio")
    prior_day_load = _average_readiness_component_value(valid_scores, "recent_load_fit", "yesterday_load")
    sleep_debt = (
        sleep.get("sleep_debt_minutes_7d")
        if timeframe == "day" and isinstance(sleep, dict)
        else _readiness_period_sleep_debt_minutes(session, user_id, profile, start, end)
    )
    sleep_debt_days = 7 if timeframe == "day" else (end - start).days + 1
    return {
        "sleep_debt_minutes": sleep_debt,
        "sleep_debt_minutes_7d": sleep_debt,
        "sleep_debt_period_days": sleep_debt_days,
        "hrv_score": hrv["score"],
        "hrv_baseline_relation": hrv["baseline_relation"],
        "rhr_score": rhr["score"],
        "rhr_baseline_relation": rhr["baseline_relation"],
        "load_ratio": load_ratio,
        "yesterday_load": prior_day_load,
        "valid_strain_days": _max_readiness_component_value(valid_scores, "recent_load_fit", "valid_strain_days"),
        "anomalies": (anomaly.get("anomalies") if isinstance(anomaly, dict) else []) or [],
        "readiness_cap": anomaly.get("readiness_cap") if isinstance(anomaly, dict) else None,
        "confidence_phase": latest.confidence_phase if latest else None,
        "data_quality": latest.data_quality if latest else "missing",
    }


def _readiness_period_sleep_debt_minutes(
    session: DbSession,
    user_id: str,
    profile: Any,
    start: date,
    end: date,
) -> int:
    debt = 0
    day = start
    while day <= end:
        sleep = _main_sleep(session, user_id, day)
        if sleep is not None and sleep.minutes_asleep is not None:
            target = _adjusted_sleep_need_minutes(session, user_id, profile, day)
            debt += max(0, target - sleep.minutes_asleep)
        day += timedelta(days=1)
    return debt


def _average_readiness_metric_context(
    scores: list[DailyScore],
    metric: str,
    *,
    higher_is_better: bool,
) -> dict[str, object]:
    component_scores: list[float] = []
    values: list[float] = []
    baselines: list[float] = []
    for score in scores:
        autonomic = _readiness_component(score, "autonomic_recovery")
        nested = autonomic.get(metric) if isinstance(autonomic.get(metric), dict) else None
        if not isinstance(nested, dict):
            continue
        component_score = nested.get("score")
        if isinstance(component_score, int | float):
            component_scores.append(float(component_score))
        value = nested.get("value")
        baseline = nested.get("baseline")
        if isinstance(value, int | float) and isinstance(baseline, int | float):
            values.append(float(value))
            baselines.append(float(baseline))
    average_value = mean(values) if values else None
    average_baseline = mean(baselines) if baselines else None
    return {
        "score": round(mean(component_scores), 1) if component_scores else None,
        "baseline_relation": _baseline_relation_from_values(
            average_value,
            average_baseline,
            higher_is_better=higher_is_better,
        ),
    }


def _average_readiness_component_value(
    scores: list[DailyScore],
    component_key: str,
    value_key: str,
) -> float | None:
    values = [
        float(value)
        for score in scores
        if isinstance((value := _readiness_component(score, component_key).get(value_key)), int | float)
    ]
    return round(mean(values), 3) if values else None


def _max_readiness_component_value(
    scores: list[DailyScore],
    component_key: str,
    value_key: str,
) -> int | None:
    values = [
        int(value)
        for score in scores
        if isinstance((value := _readiness_component(score, component_key).get(value_key)), int | float)
    ]
    return max(values) if values else None


def _readiness_component(score: DailyScore, key: str) -> dict[str, Any]:
    components = score.components or {}
    component = components.get(key)
    return component if isinstance(component, dict) else {}


def _nested_score(container: Any, key: str) -> object | None:
    if not isinstance(container, dict):
        return None
    value = container.get(key)
    if not isinstance(value, dict):
        return None
    return value.get("score")


def _baseline_relation_from_values(
    current: float | None,
    baseline: float | None,
    *,
    higher_is_better: bool,
) -> str | None:
    if current is None or baseline is None:
        return None
    if abs(current - baseline) < 0.05:
        return "at_baseline"
    if higher_is_better:
        return "above_baseline" if current > baseline else "below_baseline"
    return "below_baseline" if current < baseline else "above_baseline"


def _baseline_relation(container: Any, key: str, *, higher_is_better: bool) -> str | None:
    if not isinstance(container, dict):
        return None
    value = container.get(key)
    if not isinstance(value, dict):
        return None
    current = value.get("value")
    baseline = value.get("baseline")
    if not isinstance(current, int | float) or not isinstance(baseline, int | float):
        return None
    return _baseline_relation_from_values(float(current), float(baseline), higher_is_better=higher_is_better)


def _readiness_guidance(
    timeframe: str,
    summary: dict[str, object],
    scores: list[DailyScore],
) -> dict[str, object]:
    band = summary.get("readiness_band")
    trend = summary.get("trend")
    if not scores:
        text = "Readiness will appear after sleep and recovery data are available for this period."
    elif timeframe == "day":
        if band == "high":
            text = "Recovery signals support a purposeful training day if your plan calls for it."
        elif band == "medium":
            text = "Keep the day flexible. You can train, but watch how warm-up effort feels."
        elif band == "low":
            text = "Recovery is limited today. Bias toward easy movement, rest, or reducing planned intensity."
        else:
            text = "Use readiness with recent strain and how you feel before choosing the day."
    elif trend == "declining":
        text = "Readiness is trending down across this period. Look for sleep debt, elevated load, or autonomic strain before adding intensity."
    elif trend == "improving":
        text = "Readiness is improving across this period. Rebuild load gradually instead of treating one good day as full clearance."
    else:
        text = "Use the pattern of high and low readiness days to plan harder sessions around stronger recovery windows."
    return {"message": text}


def _readiness_reasons_payload(scores: list[DailyScore]) -> list[dict[str, object]]:
    latest = _latest_score(scores)
    if latest is None:
        return []
    return latest.reasons or []


def _readiness_data_quality(scores: list[DailyScore], start: date, end: date) -> dict[str, object]:
    expected_days = (end - start).days + 1
    valid_scores = [score for score in scores if score.value is not None]
    quality_counts = Counter(score.data_quality for score in scores if score.data_quality)
    confidence_counts = Counter(score.confidence_phase for score in scores if score.confidence_phase)
    status_counts = Counter(score.status.value for score in scores if score.status)
    return {
        "expected_days": expected_days,
        "scored_days": len(valid_scores),
        "completeness": round(len(valid_scores) / expected_days, 3) if expected_days else None,
        "quality_counts": dict(quality_counts),
        "confidence_counts": dict(confidence_counts),
        "status_counts": dict(status_counts),
    }


def _latest_score(scores: list[DailyScore]) -> DailyScore | None:
    return scores[-1] if scores else None


def _latest_scored_score(scores: list[DailyScore]) -> DailyScore | None:
    return next((score for score in reversed(scores) if score.value is not None), None)


def _readiness_band(value: float | None) -> str | None:
    if value is None:
        return None
    if value >= 80:
        return "high"
    if value >= 60:
        return "medium"
    return "low"


def _readiness_trend(values: list[float]) -> str | None:
    if len(values) < 3:
        return None
    first = mean(values[: min(3, len(values))])
    last = mean(values[-min(3, len(values)) :])
    delta = last - first
    if delta >= 4:
        return "improving"
    if delta <= -4:
        return "declining"
    return "steady"


def _readiness_period_trend(timeframe: str, scores: list[DailyScore], values: list[float]) -> str | None:
    if timeframe == "day":
        return None
    if timeframe != "year":
        return _readiness_trend(values)
    scores_by_month: dict[date, list[DailyScore]] = defaultdict(list)
    for score in scores:
        scores_by_month[date(score.score_date.year, score.score_date.month, 1)].append(score)
    monthly_values = [
        mean([float(score.value) for score in month_scores if score.value is not None])
        for _, month_scores in sorted(scores_by_month.items())
        if any(score.value is not None for score in month_scores)
    ]
    if len(monthly_values) < 2:
        return None
    return _readiness_trend(monthly_values)


_READINESS_COMPONENT_LABELS = {
    "sleep_adequacy_debt": "Sleep adequacy",
    "autonomic_recovery": "Autonomic recovery",
    "recent_load_fit": "Recent load fit",
    "illness_anomaly_context": "Anomaly context",
    "confidence": "Confidence",
}

_READINESS_COMPONENT_WEIGHTS = {
    "sleep_adequacy_debt": 0.30,
    "autonomic_recovery": 0.30,
    "recent_load_fit": 0.25,
    "illness_anomaly_context": 0.10,
    "confidence": 0.05,
}
