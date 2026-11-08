from __future__ import annotations

import logging

from fastapi import APIRouter
from pydantic import BaseModel, Field
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession
from app.models import (
    BehaviourAnalysisResult, BehaviourAnalysisRun, BehaviourPatternView, JournalPreference, JournalState,
)
from app.services.behaviour_analysis import latest_runs
from app.services.behaviour_presentation import FINDING_STATES, present
from app.services.behaviour_series import turned_off_inputs


logger = logging.getLogger(__name__)

router = APIRouter(prefix="/insights", tags=["insights"])


class PatternKey(BaseModel):
    pair_id: str = Field(max_length=120)
    stratum: str = Field(default="all", max_length=24)


class SeenPatterns(BaseModel):
    patterns: list[PatternKey] = Field(max_length=500)


def hidden_inputs(session, user_id):
    preferences = {row.key: row.value for row in session.scalars(select(JournalPreference).where(
        JournalPreference.user_id == user_id,
    ))}
    return turned_off_inputs(preferences)


def views_for(session, user_id):
    return {(row.pair_id, row.stratum): row for row in session.scalars(select(BehaviourPatternView).where(
        BehaviourPatternView.user_id == user_id,
    ))}


def visible_rows(session, run, hidden):
    rows = session.scalars(select(BehaviourAnalysisResult).where(
        BehaviourAnalysisResult.run_id == run.id,
    ).order_by(BehaviourAnalysisResult.pair_id, BehaviourAnalysisResult.stratum))
    return [row for row in rows if row.input_id not in hidden]


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
        return dict(status=status, run=None, stories=[], new_findings=0)
    state = session.get(JournalState, user.id)
    hidden = hidden_inputs(session, user.id)
    presented = present(visible_rows(session, run, hidden), run, views_for(session, user.id), hidden)
    logger.info("Behaviour patterns served stories=%d new=%d", len(presented["stories"]),
                presented["new_findings"])
    return dict(
        status="ready",
        run=dict(
            id=run.id, algorithm_version=run.algorithm_version, map_version=run.map_version,
            presentation_version=presented["version"],
            window_start=run.window_start, window_end=run.window_end,
            tracking_day=run.tracking_day, checkpoint_day=run.checkpoint_day,
            next_checkpoint_day=presented["next_checkpoint_day"],
            completed_at=run.completed_at,
            current=state is None or state.analysis_revision == run.analysis_revision,
            last_attempt_failed=latest_attempt is not None and latest_attempt.status == "failed",
        ),
        stories=presented["stories"],
        new_findings=presented["new_findings"],
    )


@router.post("/patterns/seen")
def mark_patterns_seen(payload: SeenPatterns, session: DbSession, user: CurrentUser) -> dict:
    run, _ = latest_runs(session, user.id)
    if run is None:
        return dict(recorded=0)
    hidden = hidden_inputs(session, user.id)
    rows = {(row.pair_id, row.stratum): row for row in visible_rows(session, run, hidden)}
    views = views_for(session, user.id)
    presented = present(list(rows.values()), run, views, hidden)
    showable = {(finding["pair_id"], finding["stratum"])
                for story in presented["stories"] for finding in story["findings"]
                if finding["state"] in FINDING_STATES}
    recorded = 0
    for key in {(item.pair_id, item.stratum) for item in payload.patterns}:
        if key not in showable or key in views:
            continue
        session.add(BehaviourPatternView(
            user_id=user.id, pair_id=key[0], stratum=key[1], stage_when_seen=rows[key].stage,
            checkpoint_day=run.checkpoint_day,
        ))
        recorded += 1
    session.commit()
    logger.info("Behaviour patterns marked seen recorded=%d", recorded)
    return dict(recorded=recorded)
