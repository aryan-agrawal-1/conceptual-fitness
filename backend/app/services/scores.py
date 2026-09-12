from __future__ import annotations


from dataclasses import dataclass
from copy import deepcopy
from datetime import date, timedelta

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.models import DailyScore, User

from app.services.health_dates import get_or_create_profile, local_date_for_profile, local_week_start
from app.services.score_baselines import _detect_timezone_shift_context, rebuild_daily_baselines
from app.services.score_helpers import (
    BASELINE_VERSION,
    READINESS_SCORE_VERSION,
    SCORE_VERSIONS,
    SLEEP_SCORE_VERSION,
    STRAIN_LOAD_VERSION,
    _date_range,
    _main_sleep,
    _score_for_day,
)
from app.services.readiness_scores import _adjusted_sleep_need_minutes, _upsert_readiness_score
from app.services.sleep_scores import _continuity_score, _duration_score, _upsert_sleep_score
from app.services.summaries import rebuild_daily_summaries
from app.services.strain_scores import _upsert_strain_score, _upsert_strain_target


__all__ = [
    "BASELINE_VERSION",
    "READINESS_SCORE_VERSION",
    "SCORE_VERSIONS",
    "SLEEP_SCORE_VERSION",
    "STRAIN_LOAD_VERSION",
    "ScoreRebuildResult",
    "_adjusted_sleep_need_minutes",
    "_continuity_score",
    "_duration_score",
    "_main_sleep",
    "rebuild_daily_baselines",
    "rebuild_derived_scores",
]


@dataclass(frozen=True)
class ScoreRebuildResult:
    user_id: str
    start: date
    end: date
    scores_rebuilt: int
    baselines_rebuilt: int
    targets_rebuilt: int


def rebuild_derived_scores(
    session: Session,
    *,
    user_id: str,
    start: date,
    end: date,
    include_dependents: bool = False,
) -> ScoreRebuildResult:
    # Serialize score publication across current sync, history and manual edits.
    session.execute(select(User.id).where(User.id == user_id).with_for_update())
    profile = get_or_create_profile(session, user_id)
    today = local_date_for_profile(profile)
    if include_dependents:
        latest_score_date = session.scalar(select(func.max(DailyScore.score_date)).where(
            DailyScore.user_id == user_id,
        ))
        # Invalidate existing dependent windows; do not invent empty future history.
        today = min(today, max(end, latest_score_date or end))
    # Raw inputs feed up to 90 days of exercise references (baselines use 60).
    # ponytail: rebuild all score types in this window; split by metric if profiling warrants.
    effective_end = min(end + timedelta(days=90) if include_dependents else end, today)
    if effective_end < start:
        effective_end = start

    scores_rebuilt = 0
    baselines_rebuilt = 0
    day = start
    while day <= effective_end:
        _detect_timezone_shift_context(session, user_id=user_id, profile=profile, day=day)
        baselines_rebuilt += rebuild_daily_baselines(
            session,
            user_id=user_id,
            profile=profile,
            baseline_date=day,
        )
        _upsert_sleep_score(session, user_id=user_id, profile=profile, day=day)
        previous = _score_for_day(session, user_id, day, "strain", STRAIN_LOAD_VERSION)
        previous_inputs = deepcopy((previous.value, previous.components, previous.data_quality)) if previous else None
        strain = _upsert_strain_score(session, user_id=user_id, profile=profile, day=day)
        if include_dependents and previous_inputs != (strain.value, strain.components, strain.data_quality):
            # Changed strain feeds 90-day category rates, 60-day baselines and
            # 63-day residual comparisons. Propagate only while inputs change.
            effective_end = max(effective_end, min(day + timedelta(days=90), today))
        _upsert_readiness_score(session, user_id=user_id, profile=profile, day=day)
        scores_rebuilt += 3
        session.flush()
        day += timedelta(days=1)

    targets_rebuilt = 0
    for week_start in sorted({local_week_start(day) for day in _date_range(start, effective_end)}):
        _upsert_strain_target(session, user_id=user_id, week_start=week_start)
        targets_rebuilt += 1
    session.flush()
    return ScoreRebuildResult(
        user_id=user_id,
        start=start,
        end=effective_end,
        scores_rebuilt=scores_rebuilt,
        baselines_rebuilt=baselines_rebuilt,
        targets_rebuilt=targets_rebuilt,
    )


def rebuild_after_health_edit(session: Session, *, user_id: str, days: set[date]) -> None:
    """Publish edited inputs and their dependent scores in the caller's transaction."""
    session.execute(select(User.id).where(User.id == user_id).with_for_update())
    session.flush()
    today = local_date_for_profile(get_or_create_profile(session, user_id))
    dates = sorted(day for day in days if day <= today)
    for day in dates:
        rebuild_daily_summaries(session, user_id=user_id, start=day, end=day)
    rebuilt_through = date.min
    for day in dates:
        if day > rebuilt_through:
            result = rebuild_derived_scores(
                session, user_id=user_id, start=day, end=day, include_dependents=True,
            )
            rebuilt_through = result.end
