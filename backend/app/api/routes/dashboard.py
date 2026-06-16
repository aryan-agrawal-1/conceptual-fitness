from __future__ import annotations

from datetime import date

from fastapi import APIRouter, Query
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession
from app.models import DailySummary


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


@router.get("/dashboard/today")
def dashboard_today(session: DbSession, user: CurrentUser) -> dict[str, object]:
    today = date.today()
    summary = session.scalar(
        select(DailySummary).where(
            DailySummary.user_id == user.id,
            DailySummary.summary_date == today,
        )
    )
    if summary is None:
        return {"date": today, "data_quality": "missing", "metrics": None}
    return {"user_id": user.id, "metrics": _summary_payload(summary)}


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

