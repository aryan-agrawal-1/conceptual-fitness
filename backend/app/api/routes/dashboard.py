from __future__ import annotations

from datetime import date, timedelta

from fastapi import APIRouter, Query
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession
from app.api.routes.metrics import dashboard_metric_summaries, _workout_summary_payload
from app.models import DailyScore, DailySummary, GoogleAccount, StrainTarget, SyncCursor, Workout
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
    return _dashboard_snapshot(session, user.id, today)


@router.get("/dashboard/bundle")
def dashboard_bundle(
    session: DbSession,
    user: CurrentUser,
    date: date | None = Query(default=None),
    workout_days: int = Query(default=30, ge=1, le=365),
    workout_limit: int = Query(default=3, ge=0, le=20),
    metrics_window_days: int = Query(default=30, ge=1, le=365),
) -> dict[str, object]:
    profile = get_or_create_profile(session, user.id)
    day = date or local_date_for_profile(profile)
    metric_names = [
        "heart_rate_variability",
        "resting_heart_rate",
        "oxygen_saturation",
        "respiratory_rate",
        "vo2_max",
        "sleep",
        "steps",
        "active_calories",
        "distance",
    ]
    metric_summaries = dashboard_metric_summaries(
        session,
        user_id=user.id,
        metric_names=metric_names,
        end=day,
        window_days=metrics_window_days,
    )
    snapshot = _dashboard_snapshot(session, user.id, day)
    recent_workouts = _recent_workouts_payload(
        session,
        user.id,
        end=day,
        workout_days=workout_days,
        workout_limit=workout_limit,
    )
    sync_status = _sync_status_payload(session, user.id)
    connections = _connection_payloads(session, user.id)
    profile_payload = _profile_payload(profile)
    section_quality = {
        "snapshot": snapshot.get("data_quality", "missing"),
        "metrics": _metrics_quality(metric_summaries),
        "recent_workouts": "strong" if recent_workouts else "missing",
        "vo2_max": (
            metric_summaries["vo2_max"]["data_quality"]
            if isinstance(metric_summaries.get("vo2_max"), dict)
            else "missing"
        ),
        "sync": _sync_quality(sync_status, connections),
    }
    return {
        "user_id": user.id,
        "date": day,
        "profile": profile_payload,
        "connections": {"google_health": connections},
        "sync_status": sync_status,
        "snapshot": snapshot,
        "metric_summaries": metric_summaries,
        "recent_workouts": recent_workouts,
        "vo2_max": metric_summaries.get("vo2_max"),
        "data_quality": {
            "overall": _overall_quality(section_quality),
            "sections": section_quality,
        },
    }


def _dashboard_snapshot(session: DbSession, user_id: str, day: date) -> dict[str, object]:
    summary = session.scalar(
        select(DailySummary).where(
            DailySummary.user_id == user_id,
            DailySummary.summary_date == day,
        )
    )
    target = session.scalar(
        select(StrainTarget).where(
            StrainTarget.user_id == user_id,
            StrainTarget.week_start_date == local_week_start(day),
            StrainTarget.algorithm_version == STRAIN_LOAD_VERSION,
        )
    )
    if summary is None:
        return {
            "user_id": user_id,
            "date": day,
            "data_quality": "missing",
            "metrics": None,
            "scores": _scores_for_day(session, user_id, day),
            "strain_target": _strain_target_payload(target),
        }
    return {
        "user_id": user_id,
        "date": day,
        "data_quality": summary.data_quality,
        "metrics": _summary_payload(summary),
        "scores": _scores_for_day(session, user_id, day),
        "strain_target": _strain_target_payload(target),
    }


def _recent_workouts_payload(
    session: DbSession,
    user_id: str,
    *,
    end: date,
    workout_days: int,
    workout_limit: int,
) -> list[dict[str, object]]:
    if workout_limit == 0:
        return []
    start = end - timedelta(days=workout_days - 1)
    workouts = session.scalars(
        select(Workout)
        .where(
            Workout.user_id == user_id,
            Workout.civil_date >= start,
            Workout.civil_date <= end,
        )
        .order_by(Workout.start_time.desc())
        .limit(workout_limit)
    ).all()
    profile = get_or_create_profile(session, user_id)
    return [
        _workout_summary_payload(session, user_id, profile, workout)
        for workout in workouts
    ]


def _connection_payloads(session: DbSession, user_id: str) -> list[dict[str, object]]:
    accounts = session.scalars(
        select(GoogleAccount)
        .where(GoogleAccount.user_id == user_id)
        .order_by(GoogleAccount.connected_at.desc())
    ).all()
    return [
        {
            "account_id": account.id,
            "status": account.status.value,
            "health_user_id_present": bool(account.health_user_id),
            "legacy_user_id_present": bool(account.legacy_user_id),
            "granted_scopes": account.granted_scopes,
            "connected_at": account.connected_at,
            "last_sync_at": account.last_sync_at,
            "last_error": account.last_error,
        }
        for account in accounts
    ]


def _sync_status_payload(session: DbSession, user_id: str) -> list[dict[str, object]]:
    account_ids = [
        account.id
        for account in session.scalars(select(GoogleAccount).where(GoogleAccount.user_id == user_id))
    ]
    if not account_ids:
        return []
    cursors = session.scalars(
        select(SyncCursor)
        .where(SyncCursor.google_account_id.in_(account_ids))
        .order_by(SyncCursor.updated_at.desc())
    ).all()
    return [
        {
            "google_account_id": cursor.google_account_id,
            "data_type": cursor.data_type,
            "status": cursor.status.value,
            "last_successful_start": cursor.last_successful_start,
            "last_successful_end": cursor.last_successful_end,
            "last_error": cursor.last_error,
            "updated_at": cursor.updated_at,
        }
        for cursor in cursors
    ]


def _profile_payload(profile) -> dict[str, object]:
    return {
        "user_id": profile.user_id,
        "timezone": profile.timezone,
        "date_of_birth": profile.date_of_birth,
        "birth_year": profile.birth_year,
        "sex": profile.sex,
        "height_cm": profile.height_cm,
        "weight_kg": profile.weight_kg,
        "fitness_goal": profile.fitness_goal,
        "sleep_target_minutes": profile.sleep_target_minutes,
    }


def _metrics_quality(metric_summaries: dict[str, object]) -> str:
    qualities = [
        summary.get("data_quality")
        for summary in metric_summaries.values()
        if isinstance(summary, dict)
    ]
    return _overall_quality({str(index): str(quality) for index, quality in enumerate(qualities)})


def _sync_quality(
    sync_status: list[dict[str, object]],
    connections: list[dict[str, object]],
) -> str:
    if any(connection.get("status") == "connected" for connection in connections):
        if not sync_status:
            return "weak"
        if any(item.get("status") == "failed" for item in sync_status):
            return "weak"
        return "strong"
    return "missing"


def _overall_quality(section_quality: dict[str, str]) -> str:
    values = list(section_quality.values())
    if any(value == "strong" for value in values):
        return "strong"
    if any(value == "weak" for value in values):
        return "weak"
    return "missing"


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
