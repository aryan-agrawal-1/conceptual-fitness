from __future__ import annotations

from datetime import date

from fastapi import APIRouter, Query
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession
from app.models import DailyScore, DailySummary, StrainTarget
from app.services.health_dates import get_or_create_profile, local_date_for_profile, local_week_start
from app.services.scores import SCORE_VERSIONS, STRAIN_LOAD_VERSION


router = APIRouter(tags=["dashboard"])

# full daily summary
def _summary_payload(summary: DailySummary) -> dict[str, object]:
    return {
        "date": summary.summary_date,
        "steps": summary.steps,
        "active_calories": summary.active_calories,
        "total_calories": summary.total_calories,
        "distance_meters": summary.distance_meters,
        "resting_heart_rate": summary.resting_heart_rate,
        "heart_rate_variability": summary.heart_rate_variability,
        "oxygen_saturation": summary.oxygen_saturation,
        "respiratory_rate": summary.respiratory_rate,
        "sleep_minutes": summary.sleep_minutes,
        "workout_count": summary.workout_count,
        "data_quality": summary.data_quality,
        "updated_at": summary.updated_at,
    }


# scores endpoint
def _score_payload(score: DailyScore | None) -> dict[str, object] | None:
    if score is None:
        return None
    return {
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

# get scores for given day
def _scores_for_day(session: DbSession, user_id: str, day: date) -> dict[str, object]:
    scores: dict[str, object] = {}
    for score_type, version in SCORE_VERSIONS.items():
        score = session.scalar(
            select(DailyScore).where(
                DailyScore.user_id == user_id,
                DailyScore.score_date == day,
                DailyScore.score_type == score_type,
                DailyScore.algorithm_version == version,
            )
        )
        scores[score_type] = _score_payload(score)
    return scores

# get strain target
def _strain_target_payload(target: StrainTarget | None) -> dict[str, object] | None:
    if target is None:
        return None
    return {
        "week_start_date": target.week_start_date,
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


@router.get("/dashboard/today")
def dashboard_today(session: DbSession, user: CurrentUser) -> dict[str, object]:
    profile = get_or_create_profile(session, user.id)
    today = local_date_for_profile(profile)
    summary = session.scalar(
        select(DailySummary).where(
            DailySummary.user_id == user.id,
            DailySummary.summary_date == today,
        )
    )
    target = session.scalar(
        select(StrainTarget).where(
            StrainTarget.user_id == user.id,
            StrainTarget.week_start_date == local_week_start(today),
            StrainTarget.algorithm_version == STRAIN_LOAD_VERSION,
        )
    )
    if summary is None:
        return {
            "user_id": user.id,
            "date": today,
            "data_quality": "missing",
            "metrics": None,
            "scores": _scores_for_day(session, user.id, today),
            "strain_target": _strain_target_payload(target),
        }
    return {
        "user_id": user.id,
        "date": today,
        "metrics": _summary_payload(summary),
        "scores": _scores_for_day(session, user.id, today),
        "strain_target": _strain_target_payload(target),
    }


@router.get("/summaries/daily")
def daily_summaries(
    session: DbSession,
    user: CurrentUser,
    start: date = Query(...),
    end: date = Query(...),
) -> list[dict[str, object]]:
    summaries = session.scalars(
        select(DailySummary)
        .where(
            DailySummary.user_id == user.id,
            DailySummary.summary_date >= start,
            DailySummary.summary_date <= end,
        )
        .order_by(DailySummary.summary_date)
    ).all()
    return [_summary_payload(summary) for summary in summaries]
