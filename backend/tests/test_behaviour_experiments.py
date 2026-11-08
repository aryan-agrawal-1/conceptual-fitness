from __future__ import annotations

from datetime import UTC, date, datetime, time, timedelta
from uuid import uuid4

import numpy as np
from fastapi.testclient import TestClient
from sqlalchemy import func, select

from app.main import app
from app.models import (
    BehaviourExperiment, DailySummary, JournalEntry, JournalPreference, JournalState, SleepSession, User,
    UserProfile,
)
from app.services.account_export import category_specs
from app.services.behaviour_analysis import run_analysis
from app.services.behaviour_experiments import (
    TESTABLE_BEHAVIOURS, ExperimentBehaviour, active_experiment, describe, followed_change, schedule,
)
from app.services.behaviour_series import Answer


TODAY = date(2026, 11, 1)


def owner(session) -> User:
    user = User(email="experiments@example.com")
    session.add(user)
    session.flush()
    session.add(UserProfile(user_id=user.id, timezone="UTC"))
    session.add(JournalState(user_id=user.id, revision=1, analysis_revision=1))
    session.add(JournalPreference(user_id=user.id, key="opt_in:substances", value=True,
                                  edited_at=datetime.now(UTC), mutation_id=str(uuid4()), revision=1))
    session.add(JournalPreference(user_id=user.id, key="opt_in:medication_supplements", value=True,
                                  edited_at=datetime.now(UTC), mutation_id=str(uuid4()), revision=1))
    session.commit()
    return user


def entry(user, day, behaviour, value, details=None) -> JournalEntry:
    recorded = datetime.combine(day, time(21), tzinfo=UTC)
    return JournalEntry(
        user_id=user.id, journal_date=day, behaviour_id=behaviour, edited_at=recorded,
        mutation_id=str(uuid4()),
        response={"recorded_at": recorded.isoformat(), "journal_date": day.isoformat()},
        normalized={"canonical_answer": {"type": "boolean", "value": value},
                    "canonical_details": details or {}},
        revision=1,
    )


def night(session, user, day, rhr) -> None:
    wake = day + timedelta(days=1)
    session.add(SleepSession(
        user_id=user.id, start_time=datetime.combine(day, time(23), tzinfo=UTC),
        end_time=datetime.combine(wake, time(7), tzinfo=UTC), civil_date=wake,
        minutes_asleep=420, minutes_in_sleep_period=480, is_main_sleep=True,
    ))
    session.add(DailySummary(user_id=user.id, summary_date=wake, resting_heart_rate=rhr,
                             heart_rate_variability=60))


def seed_history(session, user, days=45) -> None:
    rng = np.random.default_rng(0)
    first = TODAY - timedelta(days=days)
    for offset in range(days + 2):
        day = first + timedelta(days=offset)
        drank = bool(rng.random() < 0.5)
        if day < TODAY:
            units = {"amount": {"type": "quantity", "value": 40.0, "unit": "mL_ethanol"}} if drank else {}
            session.add(entry(user, day, "alcohol", drank, units))
            session.add(entry(user, day, "usual_medication", bool(rng.random() < 0.6)))
        night(session, user, day, 55 + rng.normal(0, 1.5) + (3 if drank else 0))
    session.commit()


def experiment_for(session, user, start, pair_id="alcohol:rhr:d1", behaviour="alcohol_free",
                   input_id="alcohol") -> BehaviourExperiment:
    experiment = BehaviourExperiment(
        user_id=user.id, behaviour_id=behaviour, input_id=input_id, pair_id=pair_id,
        outcome_id=pair_id.split(":")[1], stratum="all", status="active", start_date=start,
        end_date=start + timedelta(days=27),
    )
    session.add(experiment)
    session.commit()
    return experiment


def test_schedule_alternates_weeks_with_two_washout_days() -> None:
    experiment = BehaviourExperiment(behaviour_id="alcohol_free", start_date=TODAY,
                                     end_date=TODAY + timedelta(days=27))
    days = schedule(experiment)
    assert len(days) == 28
    assert [day["kind"] for day in days[::7]] == ["change", "usual", "change", "usual"]
    assert [day["washout"] for day in days[:7]] == [True, True, False, False, False, False, False]
    assert sum(not day["washout"] for day in days if day["kind"] == "change") == 10


def test_only_reviewed_habit_reductions_are_testable() -> None:
    inputs = {item.input_id for item in TESTABLE_BEHAVIOURS}
    assert inputs == {"caffeine", "alcohol", "screen_in_bed"}
    forbidden = {"nicotine", "cannabis", "other_substances", "usual_medication", "supplements",
                 "menstrual_bleeding", "menstrual_cramps", "fever", "feeling_unwell", "headache", "pain"}
    assert not inputs & forbidden
    assert all(item.change_text.startswith("Experiment day: no ") for item in TESTABLE_BEHAVIOURS)


def test_caffeine_change_counts_only_when_finished_before_two() -> None:
    behaviour = ExperimentBehaviour("caffeine_before_2pm", "caffeine", "", "", latest_use=time(14))
    stamp = datetime(2026, 11, 1, 21, tzinfo=UTC)
    early = Answer(1.0, {"last_use": {"type": "time", "value": "09:30"}}, stamp)
    late = Answer(1.0, {"last_use": {"type": "time", "value": "16:00"}}, stamp)
    assert followed_change(behaviour, early) is True
    assert followed_change(behaviour, late) is False
    assert followed_change(behaviour, Answer(1.0, {}, stamp)) is False
    assert followed_change(behaviour, Answer(0.0, {}, stamp)) is True
    assert followed_change(behaviour, None) is None


def test_patterns_mark_shown_reduction_findings_as_testable(session, auth_headers) -> None:
    user = owner(session)
    seed_history(session, user)
    run_analysis(session, user.id, trigger="edit", today=TODAY)
    body = TestClient(app).get("/insights/patterns", headers=auth_headers(user)).json()
    alcohol = next(story for story in body["stories"] if story["input_id"] == "alcohol")
    rhr = next(item for item in alcohol["findings"] if item["pair_id"] == "alcohol:rhr:d1")
    assert alcohol["testable"] is True and rhr["testable"] is True
    medication = next(story for story in body["stories"] if story["input_id"] == "usual_medication")
    assert medication["testable"] is False
    assert all(not item["testable"] for story in body["stories"] for item in story["findings"]
               if item["state"] not in ("early_signal", "possible", "consistent"))


def test_start_and_stop_an_experiment(session, auth_headers) -> None:
    user = owner(session)
    headers = auth_headers(user)
    client = TestClient(app)
    assert client.get("/insights/experiment", headers=headers).json() == dict(experiment=None)
    assert client.post("/insights/experiment", headers=headers,
                       json=dict(pair_id="alcohol:rhr:d1")).status_code == 409
    seed_history(session, user)
    run_analysis(session, user.id, trigger="edit", today=TODAY)
    refused = client.post("/insights/experiment", headers=headers, json=dict(pair_id="usual_medication:rhr:d1"))
    assert refused.status_code == 409 and refused.json()["detail"]["code"] == "not_testable"
    started = client.post("/insights/experiment", headers=headers, json=dict(pair_id="alcohol:rhr:d1"))
    assert started.status_code == 200
    experiment = started.json()["experiment"]
    assert experiment["status"] == "active" and experiment["title"] == "Alcohol-free days"
    assert len(experiment["days"]) == 28 and experiment["result"] is None
    assert experiment["days"][0]["plan"] == "Experiment day: no alcohol"
    assert experiment["days"][7]["plan"] == "Usual day: do what you normally do"
    again = client.post("/insights/experiment", headers=headers, json=dict(pair_id="alcohol:rhr:d1"))
    assert again.status_code == 409 and again.json()["detail"]["code"] == "experiment_active"
    current = client.get("/insights/experiment", headers=headers).json()["experiment"]
    assert current["id"] == experiment["id"]
    stopped = client.post("/insights/experiment/stop", headers=headers).json()["experiment"]
    assert stopped["status"] == "stopped" and stopped["result"]["status"] == "too_few_days"
    assert client.post("/insights/experiment/stop", headers=headers).status_code == 404


def test_today_plan_follows_the_schedule(session) -> None:
    user = owner(session)
    experiment = experiment_for(session, user, TODAY - timedelta(days=8))
    body = describe(session, experiment, TODAY)
    assert body["today"]["kind"] == "usual" and body["today"]["washout"] is True
    assert body["today"]["plan"] == "Usual day: do what you normally do"
    assert body["today"]["day_number"] == 9


def test_completed_experiment_compares_change_and_usual_days(session) -> None:
    user = owner(session)
    start = TODAY - timedelta(days=40)
    experiment = experiment_for(session, user, start)
    for item in schedule(experiment):
        day = item["date"]
        change = item["kind"] == "change"
        if change:
            session.add(entry(user, day, "alcohol", day.day % 5 == 0))
        night(session, user, day, 52.0 if change else 57.0)
    session.commit()
    current = active_experiment(session, user.id, TODAY)
    assert current.status == "completed"
    body = describe(session, current, TODAY)
    result = body["result"]
    assert result["status"] == "ready"
    assert (result["change_days"], result["usual_days"]) == (10, 10)
    assert round(result["difference"], 1) == -5.0 and result["benefit"] == "helps"
    assert result["summary"] == "Overnight resting heart rate was about 5 bpm lower on change days than on usual days."
    assert any("one person's result" in note for note in result["notes"])
    assert body["adherence"]["change_days"] == 14 and body["adherence"]["logged_days"] == 14
    assert body["adherence"]["followed_days"] < 14
    assert result["adherence_text"].startswith("You logged doing the change on ")
    assert body["today"] is None


def test_small_differences_are_reported_as_no_clear_difference(session) -> None:
    user = owner(session)
    experiment = experiment_for(session, user, TODAY - timedelta(days=40))
    for item in schedule(experiment):
        night(session, user, item["date"], 55.5 if item["kind"] == "change" else 55.0)
    session.commit()
    result = describe(session, active_experiment(session, user.id, TODAY), TODAY)["result"]
    assert result["benefit"] == "none" and "no clear difference" in result["summary"]


def test_too_few_valid_days_gives_no_number(session) -> None:
    user = owner(session)
    experiment = experiment_for(session, user, TODAY - timedelta(days=40))
    for item in schedule(experiment)[:10]:
        night(session, user, item["date"], 55.0)
    session.commit()
    result = describe(session, active_experiment(session, user.id, TODAY), TODAY)["result"]
    assert result["status"] == "too_few_days" and result["difference"] is None
    assert "Not enough days" in result["summary"]


def test_experiments_are_exported_and_erased_with_the_account(session) -> None:
    user = owner(session)
    experiment_for(session, user, TODAY)
    assert BehaviourExperiment in {spec.model for spec in category_specs("derived_insights")}
    session.delete(session.get(User, user.id))
    session.commit()
    assert session.scalar(select(func.count()).select_from(BehaviourExperiment)) == 0
