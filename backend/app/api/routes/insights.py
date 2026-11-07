from __future__ import annotations

import logging

from fastapi import APIRouter
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession
from app.models import BehaviourAnalysisResult, BehaviourAnalysisRun, JournalPreference, JournalState
from app.services.behaviour_analysis import latest_runs
from app.services.behaviour_series import turned_off_inputs


logger = logging.getLogger(__name__)

router = APIRouter(prefix="/insights", tags=["insights"])


def result_payload(row: BehaviourAnalysisResult) -> dict:
    held = row.held_reason is not None
    return dict(
        pair_id=row.pair_id, input_id=row.input_id, outcome_id=row.outcome_id,
        lag_days=row.lag_days, tier=row.tier, stratum=row.stratum,
        stage="held" if held else row.stage, held_reason=row.held_reason,
        suppression_reason=row.suppression_reason, coding=row.coding,
        exposed_days=row.exposed_days, comparison_days=row.comparison_days,
        estimates=[] if held else row.estimates, q_value=None if held else row.q_value,
        labels=row.labels,
    )


@router.get("/patterns")
def get_patterns(session: DbSession, user: CurrentUser) -> dict:
    latest_attempt = session.scalar(select(BehaviourAnalysisRun).where(
        BehaviourAnalysisRun.user_id == user.id,
    ).order_by(BehaviourAnalysisRun.started_at.desc()).limit(1))
    run, _ = latest_runs(session, user.id)
    if run is None:
        status = "failed" if latest_attempt is not None and latest_attempt.status == "failed" else "not_started"
        if latest_attempt is not None and latest_attempt.status == "running":
            status = "running"
        return dict(status=status, run=None, results=[])
    state = session.get(JournalState, user.id)
    preferences = {row.key: row.value for row in session.scalars(select(JournalPreference).where(
        JournalPreference.user_id == user.id,
    ))}
    hidden = turned_off_inputs(preferences)
    rows = session.scalars(select(BehaviourAnalysisResult).where(
        BehaviourAnalysisResult.run_id == run.id,
    ).order_by(BehaviourAnalysisResult.pair_id, BehaviourAnalysisResult.stratum))
    results = [result_payload(row) for row in rows if row.input_id not in hidden]
    logger.info("Behaviour patterns served results=%d", len(results))
    return dict(
        status="ready",
        run=dict(
            id=run.id, algorithm_version=run.algorithm_version, map_version=run.map_version,
            window_start=run.window_start, window_end=run.window_end,
            tracking_day=run.tracking_day, checkpoint_day=run.checkpoint_day,
            completed_at=run.completed_at,
            current=state is None or state.analysis_revision == run.analysis_revision,
            last_attempt_failed=latest_attempt is not None and latest_attempt.status == "failed",
        ),
        results=results,
    )
