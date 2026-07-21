from __future__ import annotations


from dataclasses import dataclass
from datetime import date

from sqlalchemy.orm import Session

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
)
from app.services.readiness_scores import _adjusted_sleep_need_minutes, _upsert_readiness_score
from app.services.sleep_scores import _continuity_score, _duration_score, _upsert_sleep_score
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
) -> ScoreRebuildResult:
    profile = get_or_create_profile(session, user_id)
    today = local_date_for_profile(profile)
    effective_end = min(end, today)
    if effective_end < start:
        effective_end = start

    scores_rebuilt = 0
    baselines_rebuilt = 0
    for day in _date_range(start, effective_end):
        _detect_timezone_shift_context(session, user_id=user_id, profile=profile, day=day)
        baselines_rebuilt += rebuild_daily_baselines(
            session,
            user_id=user_id,
            profile=profile,
            baseline_date=day,
        )
        _upsert_sleep_score(session, user_id=user_id, profile=profile, day=day)
        _upsert_strain_score(session, user_id=user_id, profile=profile, day=day)
        _upsert_readiness_score(session, user_id=user_id, profile=profile, day=day)
        scores_rebuilt += 3
        session.flush()

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
