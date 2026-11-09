from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy import select

from app.api.deps import CurrentUser, DbSession
from app.models import (
    BehaviourAnalysisResult, BehaviourAnalysisRun, BehaviourPatternView, JournalPreference, JournalState,
)
from app.services.behaviour_analysis import latest_runs
from app.services.behaviour_experiments import (
    ExperimentError, active_experiment, describe, mark_testable, restartable, setup_for, start_experiment,
    stop_experiment,
)
from app.services.behaviour_presentation import FINDING_STATES, present
from app.services.behaviour_safety import GENERAL_NOTE
from app.services.behaviour_series import turned_off_inputs
from app.services.health_dates import get_or_create_profile, local_date_for_profile


logger = logging.getLogger(__name__)

router = APIRouter(prefix="/insights", tags=["insights"])


class PatternKey(BaseModel):
    pair_id: str = Field(max_length=120)
    stratum: str = Field(default="all", max_length=24)


class SeenPatterns(BaseModel):
    patterns: list[PatternKey] = Field(max_length=500)


class StartExperiment(BaseModel):
    pair_id: str = Field(max_length=120)
    stratum: str = Field(default="all", max_length=24)
    behaviour_id: str | None = Field(default=None, max_length=40)


EXPERIMENT_ERROR_STATUS = dict(
    not_testable=409, experiment_active=409, no_active_experiment=404, change_not_available=409,
    nothing_to_restart=404,
)


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
        return dict(status=status, run=None, stories=[], new_findings=0, general_note=GENERAL_NOTE)
    state = session.get(JournalState, user.id)
    hidden = hidden_inputs(session, user.id)
    presented = mark_testable(present(visible_rows(session, run, hidden), run, views_for(session, user.id), hidden))
    logger.info("Behaviour patterns served stories=%d new=%d", len(presented["stories"]),
                presented["new_findings"])
    return dict(
        status="ready",
        run=dict(
            id=run.id, algorithm_version=run.algorithm_version, map_version=run.map_version,
            presentation_version=presented["version"], safety_version=presented["safety_version"],
            window_start=run.window_start, window_end=run.window_end,
            tracking_day=run.tracking_day, checkpoint_day=run.checkpoint_day,
            next_checkpoint_day=presented["next_checkpoint_day"],
            completed_at=run.completed_at,
            current=state is None or state.analysis_revision == run.analysis_revision,
            last_attempt_failed=latest_attempt is not None and latest_attempt.status == "failed",
        ),
        stories=presented["stories"],
        new_findings=presented["new_findings"],
        general_note=presented["general_note"],
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


def local_today(session, user_id):
    return local_date_for_profile(get_or_create_profile(session, user_id))


def shown_finding(session, user_id, pair_id, stratum):
    run, _ = latest_runs(session, user_id)
    if run is None:
        return None
    hidden = hidden_inputs(session, user_id)
    presented = present(visible_rows(session, run, hidden), run, views_for(session, user_id), hidden)
    return next((finding for story in presented["stories"] for finding in story["findings"]
                 if finding["pair_id"] == pair_id and finding["stratum"] == stratum), None)


def experiment_failure(error, action):
    logger.warning("Behaviour experiment %s refused reason=%s", action, error.code)
    return HTTPException(EXPERIMENT_ERROR_STATUS[error.code], dict(code=error.code))


@router.get("/experiment")
def get_experiment(session: DbSession, user: CurrentUser) -> dict:
    today = local_today(session, user.id)
    return dict(experiment=describe(session, active_experiment(session, user.id, today), today))


@router.get("/experiment/setup")
def get_experiment_setup(session: DbSession, user: CurrentUser, pair_id: str = Query(max_length=120),
                         stratum: str = Query(default="all", max_length=24)) -> dict:
    today = local_today(session, user.id)
    finding = shown_finding(session, user.id, pair_id, stratum)
    try:
        if finding is None:
            raise ExperimentError("not_testable")
        return dict(setup=setup_for(session, user.id, finding, today))
    except ExperimentError as error:
        raise experiment_failure(error, "setup") from error


@router.post("/experiment")
def post_experiment(payload: StartExperiment, session: DbSession, user: CurrentUser) -> dict:
    today = local_today(session, user.id)
    finding = shown_finding(session, user.id, payload.pair_id, payload.stratum)
    try:
        if finding is None:
            raise ExperimentError("not_testable")
        experiment = start_experiment(session, user.id, finding, today, payload.behaviour_id)
    except ExperimentError as error:
        raise experiment_failure(error, "start") from error
    return dict(experiment=describe(session, experiment, today))


@router.post("/experiment/restart")
def post_experiment_restart(session: DbSession, user: CurrentUser) -> dict:
    today = local_today(session, user.id)
    try:
        previous = restartable(session, user.id, today)
        finding = shown_finding(session, user.id, previous.pair_id, previous.stratum)
        if finding is None:
            raise ExperimentError("not_testable")
        experiment = start_experiment(session, user.id, finding, today, previous.behaviour_id, restart=True)
    except ExperimentError as error:
        raise experiment_failure(error, "restart") from error
    return dict(experiment=describe(session, experiment, today))


@router.post("/experiment/stop")
def post_experiment_stop(session: DbSession, user: CurrentUser) -> dict:
    today = local_today(session, user.id)
    try:
        experiment = stop_experiment(session, user.id, today)
    except ExperimentError as error:
        raise experiment_failure(error, "stop") from error
    return dict(experiment=describe(session, experiment, today))
