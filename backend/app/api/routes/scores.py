from __future__ import annotations

from datetime import date

from fastapi import APIRouter, HTTPException, Query
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession
from app.models import DailyScore, StrainTarget
from app.services.health_dates import local_week_start
from app.services.scores import SCORE_VERSIONS, STRAIN_LOAD_VERSION, rebuild_derived_scores


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
