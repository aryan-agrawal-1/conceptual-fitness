from __future__ import annotations

from datetime import UTC, date, datetime, time, timedelta
from uuid import uuid4

import numpy as np
from fastapi.testclient import TestClient
from sqlalchemy import func, select

from app.main import app
from app.models import (
    BehaviourAnalysisResult, BehaviourAnalysisRun, BehaviourPatternView, DailySummary, JournalEntry, JournalPreference,
    JournalState, SleepSession, User, UserProfile,
)
from app.services.account_export import category_specs
from app.services.behaviour_analysis import needs_run, run_analysis


TODAY = date(2026, 11, 1)


def owner(session) -> User:
    user = User(email="patterns@example.com")
    session.add(user)
    session.flush()
    session.add(UserProfile(user_id=user.id, timezone="UTC"))
    session.add(JournalState(user_id=user.id, revision=1, analysis_revision=1))
    session.commit()
    return user


def entry(user: User, day: date, behaviour: str, value: bool, details: dict | None = None) -> JournalEntry:
    recorded = datetime.combine(day, time(21), tzinfo=UTC).isoformat()
    return JournalEntry(
        user_id=user.id, journal_date=day, behaviour_id=behaviour,
        edited_at=datetime.combine(day, time(21), tzinfo=UTC), mutation_id=str(uuid4()),
        response={"recorded_at": recorded, "journal_date": day.isoformat()},
        normalized={"canonical_answer": {"type": "boolean", "value": value},
                    "canonical_details": details or {}},
        revision=1,
    )


def seed(session, user: User, days: int = 45) -> None:
    rng = np.random.default_rng(0)
    first = TODAY - timedelta(days=days)
    for offset in range(days + 2):
        day = first + timedelta(days=offset)
        drank = bool(rng.random() < 0.5)
        if day < TODAY:
            units = {"amount": {"type": "quantity", "value": 40.0, "unit": "mL_ethanol"}} if drank else {}
            session.add(entry(user, day, "alcohol", drank, units))
            session.add(entry(user, day, "usual_medication", bool(rng.random() < 0.6)))
        wake = day + timedelta(days=1)
        session.add(SleepSession(
            user_id=user.id, start_time=datetime.combine(day, time(23), tzinfo=UTC),
            end_time=datetime.combine(wake, time(7), tzinfo=UTC), civil_date=wake,
            minutes_asleep=int(420 + rng.normal(0, 30)), minutes_in_sleep_period=480,
            is_main_sleep=True,
        ))
        session.add(DailySummary(user_id=user.id, summary_date=wake,
                                 resting_heart_rate=55 + rng.normal(0, 1.5) + (3 if drank else 0),
                                 heart_rate_variability=60 + rng.normal(0, 5)))
    session.add(JournalPreference(user_id=user.id, key="opt_in:substances", value=True,
                                  edited_at=datetime.now(UTC), mutation_id=str(uuid4()), revision=1))
    session.add(JournalPreference(user_id=user.id, key="opt_in:medication_supplements", value=True,
                                  edited_at=datetime.now(UTC), mutation_id=str(uuid4()), revision=1))
    session.commit()


def test_first_run_is_a_checkpoint_and_later_runs_carry_its_stages(session) -> None:
    user = owner(session)
    seed(session, user)
    first = run_analysis(session, user.id, trigger="edit", today=TODAY)
    assert (first.trigger, first.checkpoint_day, first.status) == ("checkpoint", 30, "completed")
    assert first.window_end == TODAY - timedelta(days=1)
    stored = session.scalars(select(BehaviourAnalysisResult).where(
        BehaviourAnalysisResult.run_id == first.id,
        BehaviourAnalysisResult.pair_id == "alcohol:rhr:d1",
    )).one()
    assert stored.stage in ("preliminary", "possible")
    assert stored.estimates and stored.q_value is not None
    assert stored.included_dates and stored.checks["model"]["columns"][0] == "intercept"
    second = run_analysis(session, user.id, trigger="edit", today=TODAY)
    assert (second.trigger, second.checkpoint_day) == ("edit", 30)
    carried = session.scalars(select(BehaviourAnalysisResult).where(
        BehaviourAnalysisResult.run_id == second.id,
        BehaviourAnalysisResult.pair_id == "alcohol:rhr:d1",
    )).one()
    assert carried.stage == stored.stage


def test_refresh_schedule_follows_edits_weeks_and_checkpoints(session) -> None:
    user = owner(session)
    seed(session, user)
    assert needs_run(session, user.id, TODAY) == "edit"
    run_analysis(session, user.id, trigger="edit", today=TODAY)
    assert needs_run(session, user.id, TODAY) is None
    assert needs_run(session, user.id, TODAY + timedelta(days=9)) == "weekly"
    assert needs_run(session, user.id, TODAY + timedelta(days=15)) == "checkpoint"
    session.get(JournalState, user.id).analysis_revision += 1
    session.commit()
    assert needs_run(session, user.id, TODAY) == "edit"


def findings(body: dict) -> list[dict]:
    return [finding for story in body["stories"] for finding in story["findings"]]


def test_patterns_endpoint_states_holds_and_hides_turned_off_inputs(session, auth_headers) -> None:
    user = owner(session)
    headers = auth_headers(user)
    client = TestClient(app)
    assert client.get("/insights/patterns").status_code == 401
    assert client.get("/insights/patterns", headers=headers).json() == dict(
        status="not_started", run=None, stories=[], new_findings=0,
        general_note="Patterns are observations from your own data, not medical advice.")
    seed(session, user)
    run_analysis(session, user.id, trigger="edit", today=TODAY)
    body = client.get("/insights/patterns", headers=headers).json()
    assert body["status"] == "ready" and body["run"]["current"] is True
    assert body["run"]["next_checkpoint_day"] == 60
    medication = next(item for item in findings(body) if item["pair_id"] == "usual_medication:rhr:d1")
    assert medication["state"] != "held"
    medication_story = next(story for story in body["stories"] if story["input_id"] == "usual_medication")
    assert "Do not start, stop or change a medication" in medication_story["safety_note"]
    assert body["run"]["algorithm_version"] == "behaviour_engine_v3"
    assert body["run"]["safety_version"] == "behaviour_safety_v1"
    alcohol = next(story for story in body["stories"] if story["input_id"] == "alcohol")
    assert alcohol["state"] in ("early_signal", "possible") and alcohol["unseen"] is True
    assert body["new_findings"] >= 1
    session.add(JournalPreference(user_id=user.id, key="pin:alcohol", value=False,
                                  edited_at=datetime.now(UTC), mutation_id=str(uuid4()), revision=2))
    session.commit()
    body = client.get("/insights/patterns", headers=headers).json()
    assert not any(story["input_id"] == "alcohol" for story in body["stories"])
    assert "alcohol" not in str(body).lower()


def test_seen_patterns_are_recorded_once_and_only_for_findings(session, auth_headers) -> None:
    user = owner(session)
    headers = auth_headers(user)
    client = TestClient(app)
    assert client.post("/insights/patterns/seen", headers=headers, json={"patterns": []}).json() == dict(recorded=0)
    seed(session, user)
    run_analysis(session, user.id, trigger="edit", today=TODAY)
    body = client.get("/insights/patterns", headers=headers).json()
    keys = [dict(pair_id=item["pair_id"], stratum=item["stratum"]) for item in findings(body)]
    shown = [item for item in findings(body) if item["unseen"]]
    first = client.post("/insights/patterns/seen", headers=headers, json={"patterns": keys}).json()
    assert first == dict(recorded=len(shown))
    assert client.post("/insights/patterns/seen", headers=headers, json={"patterns": keys}).json() == dict(recorded=0)
    body = client.get("/insights/patterns", headers=headers).json()
    assert body["new_findings"] == 0 and not any(item["unseen"] for item in findings(body))
    views = session.scalars(select(BehaviourPatternView)).all()
    assert {view.pair_id for view in views} == {item["pair_id"] for item in shown}


def test_confidence_does_not_rise_after_a_pattern_was_seen(session) -> None:
    user = owner(session)
    seed(session, user, days=75)
    session.add(BehaviourPatternView(user_id=user.id, pair_id="alcohol:rhr:d1", stratum="all",
                                     stage_when_seen="preliminary", checkpoint_day=30))
    session.commit()
    run = run_analysis(session, user.id, trigger="edit", today=TODAY)
    stored = session.scalars(select(BehaviourAnalysisResult).where(
        BehaviourAnalysisResult.run_id == run.id, BehaviourAnalysisResult.pair_id == "alcohol:rhr:d1",
    )).one()
    assert stored.stage == "preliminary" and "capped_after_seen" in stored.labels


def test_failed_runs_are_recorded_without_losing_the_last_good_result(session, auth_headers, monkeypatch) -> None:
    from app.services import behaviour_analysis

    user = owner(session)
    seed(session, user)
    run_analysis(session, user.id, trigger="edit", today=TODAY)

    def broken(*args, **kwargs):
        raise RuntimeError("boom")

    monkeypatch.setattr(behaviour_analysis, "analyse", broken)
    try:
        run_analysis(session, user.id, trigger="edit", today=TODAY)
    except RuntimeError:
        pass
    body = TestClient(app).get("/insights/patterns", headers=auth_headers(user)).json()
    assert body["status"] == "ready" and body["run"]["last_attempt_failed"] is True
    failed = session.scalars(select(BehaviourAnalysisRun).where(
        BehaviourAnalysisRun.status == "failed")).one()
    assert failed.error_code == "analysis_error"


def journal_edit(behaviour: str, value: dict | None, *, category_day: str = "2026-10-24") -> dict:
    stamp = "2026-10-25T12:00:00Z"
    return dict(journal_date=category_day, behaviour_id=behaviour, edited_at=stamp,
                mutation_id=str(uuid4()), deleted=False,
                response=dict(journal_date=category_day, timezone="UTC", recorded_at=stamp,
                              behaviour_id=behaviour, answer=value))


def preference(key: str, value: bool) -> dict:
    return dict(key=key, value=value, edited_at="2026-10-25T12:00:00Z", mutation_id=str(uuid4()))


def test_sync_queues_analysis_for_inputs_and_private_switches_only(session, auth_headers, queued_analyses) -> None:
    user = owner(session)
    headers = auth_headers(user)
    client = TestClient(app)
    client.post("/journal/sync", headers=headers, json={"preferences": [preference("opt_in:reflection", True)]})
    client.post("/journal/sync", headers=headers, json={"entries": [
        journal_edit("daily_note", {"type": "text", "value": "private"})]})
    assert queued_analyses == []
    client.post("/journal/sync", headers=headers, json={"entries": [
        journal_edit("mood", {"type": "rating", "value": 4})]})
    assert queued_analyses == [(user.id, "edit")]
    client.post("/journal/sync", headers=headers, json={"preferences": [preference("opt_in:substances", True)]})
    client.post("/journal/sync", headers=headers, json={"preferences": [
        dict(preference("pin:alcohol", False), edited_at="2026-10-25T13:00:00Z")]})
    assert queued_analyses[1:] == [(user.id, "edit"), (user.id, "edit")]


def test_results_are_exported_and_erased_with_the_account(session) -> None:
    user = owner(session)
    seed(session, user)
    run_analysis(session, user.id, trigger="edit", today=TODAY)
    models = {spec.model for spec in category_specs("derived_insights")}
    assert {BehaviourAnalysisRun, BehaviourAnalysisResult, BehaviourPatternView} <= models
    session.add(BehaviourPatternView(user_id=user.id, pair_id="alcohol:rhr:d1", stage_when_seen="possible"))
    session.commit()
    session.delete(session.get(User, user.id))
    session.commit()
    assert session.scalar(select(func.count()).select_from(BehaviourAnalysisResult)) == 0
    assert session.scalar(select(func.count()).select_from(BehaviourAnalysisRun)) == 0
    assert session.scalar(select(func.count()).select_from(BehaviourPatternView)) == 0
