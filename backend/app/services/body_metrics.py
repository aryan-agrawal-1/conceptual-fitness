from __future__ import annotations

from datetime import date

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from app.models import MetricSample


def preferred_body_sample(
    session: Session,
    *,
    user_id: str,
    metric: str,
    preference: str | None,
    end: date | None = None,
) -> MetricSample | None:
    statement = select(MetricSample).where(
        MetricSample.user_id == user_id,
        MetricSample.metric == metric,
    )
    if preference == "manual":
        statement = statement.where(MetricSample.source_platform == "manual")
    elif preference is not None:
        statement = statement.where(
            or_(MetricSample.source_platform.is_(None), MetricSample.source_platform != "manual")
        )
    if end is not None:
        statement = statement.where(MetricSample.civil_date <= end)
    return session.scalar(statement.order_by(MetricSample.observed_at.desc()).limit(1))
