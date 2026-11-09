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
    TESTABLE_BEHAVIOURS, TESTABLE_BY_ID, ExperimentBehaviour, active_experiment, describe, first_slip,
    followed_by_day, followed_change, options_for, schedule, usual_for,
)
from app.services.behaviour_series import load_user_data
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
                             heart_rate_variability=60, heart_rate_variability_type="rmssd",
                             hrv_rmssd=60))


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


def drinks(units):
    return {"amount": {"type": "quantity", "value": units * 10.0, "unit": "mL_ethanol"}}


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
    assert all(item.change_text.startswith("Change week: no ") for item in TESTABLE_BEHAVIOURS)


def test_caffeine_change_counts_only_when_finished_before_two() -> None:
    behaviour = ExperimentBehaviour("caffeine_before_2pm", "caffeine", "", "", latest_use=time(14))
    stamp = datetime(2026, 11, 1, 21, tzinfo=UTC)
    early = Answer(1.0, {"last_use": {"type": "time", "value": "09:30"}}, stamp)
    late = Answer(1.0, {"last_use": {"type": "time", "value": "16:00"}}, stamp)
    assert followed_change(behaviour, early) is True
    assert followed_change(behaviour, late) is False
    assert followed_change(behaviour, Answer(1.0, {}, stamp)) is None
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
    assert experiment["status"] == "active" and experiment["title"] == "Alcohol-free weeks"
    assert len(experiment["days"]) == 28 and experiment["result"] is None
    assert experiment["days"][0]["plan"] == "Change week: no alcohol"
    assert experiment["days"][7]["plan"] == "Usual week: do what you normally do"
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
    assert body["today"]["plan"] == "Usual week: do what you normally do"
    assert body["today"]["day_number"] == 9


def test_completed_experiment_compares_change_and_usual_days(session) -> None:
    user = owner(session)
    start = TODAY - timedelta(days=40)
    experiment = experiment_for(session, user, start)
    for item in schedule(experiment):
        day = item["date"]
        change = item["kind"] == "change"
        if change and day.day % 5:
            session.add(entry(user, day, "alcohol", False))
        night(session, user, day, 52.0 if change else 57.0)
    session.commit()
    current = active_experiment(session, user.id, TODAY)
    assert current.status == "completed"
    body = describe(session, current, TODAY)
    result = body["result"]
    assert result["status"] == "ready"
    assert (result["change_days"], result["usual_days"]) == (10, 10)
    assert round(result["difference"], 1) == -5.0 and result["benefit"] == "helps"
    assert result["summary"] == "Overnight resting heart rate was about 5 bpm lower in change weeks than in usual weeks."
    assert any("one person's result" in note for note in result["notes"])
    assert result["notes"][0] == "This is an observation from your own logs, not medical advice."
    assert body["adherence"]["change_days"] == 14 and body["adherence"]["logged_days"] < 14
    assert body["adherence"]["followed_days"] == body["adherence"]["logged_days"]
    assert result["adherence_text"].startswith("You logged sticking to the change on ")
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


def test_alcohol_budgets_add_up_across_each_change_week(session) -> None:
    user = owner(session)
    experiment = experiment_for(session, user, TODAY - timedelta(days=20), behaviour="alcohol_week_4")
    start = experiment.start_date
    for offset, units in ((0, 2), (3, 2), (5, None), (14, 3), (16, 2)):
        session.add(entry(user, start + timedelta(days=offset), "alcohol", True, drinks(units) if units else {}))
    session.add(entry(user, start + timedelta(days=1), "alcohol", False))
    session.add(entry(user, start + timedelta(days=8), "alcohol", True, drinks(9)))
    session.commit()
    budget = TESTABLE_BY_ID["alcohol_week_4"]
    data = load_user_data(session, user.id, start, TODAY)
    followed = followed_by_day(budget, experiment, data, TODAY)
    assert followed[start] is True and followed[start + timedelta(days=3)] is True
    assert followed[start + timedelta(days=1)] is True and followed[start + timedelta(days=5)] is None
    assert start + timedelta(days=8) not in followed
    assert followed[start + timedelta(days=14)] is True and followed[start + timedelta(days=16)] is False
    assert first_slip(session, experiment, TODAY) == start + timedelta(days=16)


def test_usual_week_comes_from_the_last_four_weeks_of_logs(session) -> None:
    user = owner(session)
    for offset in range(1, 29):
        day = TODAY - timedelta(days=offset)
        drank = offset % 2 == 0
        session.add(entry(user, day, "alcohol", drank, drinks(3) if drank else None))
        if offset <= 14:
            session.add(entry(user, day, "caffeine", True, {"last_use": {"type": "time", "value": "13:00"}}))
    session.add(entry(user, TODAY - timedelta(days=40), "alcohol", True, drinks(9)))
    session.commit()
    alcohol = usual_for(session, user.id, "alcohol", TODAY)
    assert (alcohol["logged_days"], alcohol["used_days"], alcohol["typical_units"]) == (28, 14, 3.0)
    assert alcohol["lines"] == ["You drank about 4 days a week.", "Averaging around 10 units per week in total."]
    assert [item.id for item in options_for("alcohol", alcohol)] == ["alcohol_free", "alcohol_week_7",
                                                                    "alcohol_week_10"]
    caffeine = usual_for(session, user.id, "caffeine", TODAY)
    assert caffeine["lines"][1] == "Your last caffeine was usually around 1pm."
    assert [item.id for item in options_for("caffeine", caffeine)] == ["caffeine_free", "caffeine_before_noon"]
    screens = usual_for(session, user.id, "screen_in_bed", TODAY)
    assert screens["logged_days"] == 0 and "no usual to show yet" in screens["lines"][0]
    assert [item.id for item in options_for("screen_in_bed", screens)] == ["no_screens_in_bed"]


def test_only_reductions_are_offered_as_changes() -> None:
    for item in TESTABLE_BEHAVIOURS:
        assert item.change_text.startswith("Change week: no ")
        assert "change day" not in item.detail.lower()
    assert all(item.weekly_units is None or item.weekly_units <= 14 for item in TESTABLE_BEHAVIOURS)
    heavy = dict(weekly_units=30.0, typical_units=6.0, typical_last_use=None)
    assert [item.id for item in options_for("alcohol", heavy)] == ["alcohol_free", "alcohol_week_10",
                                                                  "alcohol_week_14"]
    light = dict(weekly_units=3.0, typical_units=3.0, typical_last_use=None)
    assert [item.id for item in options_for("alcohol", light)] == ["alcohol_free"]


def test_setup_and_start_with_a_chosen_change(session, auth_headers) -> None:
    user = owner(session)
    headers = auth_headers(user)
    client = TestClient(app)
    seed_history(session, user)
    run_analysis(session, user.id, trigger="edit", today=TODAY)
    setup = client.get("/insights/experiment/setup", headers=headers,
                       params=dict(pair_id="alcohol:rhr:d1")).json()["setup"]
    offered = [option["id"] for option in setup["options"]]
    assert offered[0] == "alcohol_free" and len(offered) == 3
    assert all(TESTABLE_BY_ID[item].weekly_units < setup["usual"]["weekly_units"] for item in offered[1:])
    assert setup["usual"]["typical_units"] == 4.0
    assert setup["safety_note"] == "This is an observation from your own logs, not medical advice."
    tomorrow = (datetime.now(UTC).date() + timedelta(days=1)).isoformat()
    assert setup["start_date"] == tomorrow and setup["weeks"] == 4
    refused = client.get("/insights/experiment/setup", headers=headers,
                         params=dict(pair_id="usual_medication:rhr:d1"))
    assert refused.status_code == 409
    wrong = client.post("/insights/experiment", headers=headers,
                        json=dict(pair_id="alcohol:rhr:d1",
                                  behaviour_id=next(f"alcohol_week_{units}" for units in (4, 7, 10, 14)
                                                    if f"alcohol_week_{units}" not in offered)))
    assert wrong.status_code == 409 and wrong.json()["detail"]["code"] == "change_not_available"
    other = client.post("/insights/experiment", headers=headers,
                        json=dict(pair_id="alcohol:rhr:d1", behaviour_id="caffeine_free"))
    assert other.json()["detail"]["code"] == "change_not_available"
    started = client.post("/insights/experiment", headers=headers,
                          json=dict(pair_id="alcohol:rhr:d1", behaviour_id=offered[1])).json()["experiment"]
    units = int(TESTABLE_BY_ID[offered[1]].weekly_units)
    assert started["behaviour_id"] == offered[1] and started["title"] == f"Up to {units} units a week"
    assert started["days"][0]["plan"] == f"Change week: no more than {units} units of alcohol this week"
    assert started["off_track"] is None


def test_going_over_the_plan_in_a_change_week_ends_the_experiment_and_it_can_restart(session, auth_headers) -> None:
    user = owner(session)
    headers = auth_headers(user)
    client = TestClient(app)
    seed_history(session, user)
    session.query(JournalEntry).filter(JournalEntry.journal_date >= TODAY - timedelta(days=10)).delete()
    session.commit()
    run_analysis(session, user.id, trigger="edit", today=TODAY)
    start = TODAY - timedelta(days=9)
    experiment_for(session, user, start, behaviour="alcohol_week_4")
    session.add(entry(user, start, "alcohol", True, drinks(2)))
    session.add(entry(user, start + timedelta(days=1), "alcohol", True, {}))
    session.add(entry(user, start + timedelta(days=7), "alcohol", True, drinks(6)))
    session.commit()
    assert client.get("/insights/experiment", headers=headers).json()["experiment"]["status"] == "active"
    assert client.post("/insights/experiment/restart", headers=headers).status_code == 404
    session.add(entry(user, start + timedelta(days=2), "alcohol", True, drinks(3)))
    session.commit()
    ended = client.get("/insights/experiment", headers=headers).json()["experiment"]
    assert ended["status"] == "off_track" and ended["today"] is None and ended["result"] is None
    slip = start + timedelta(days=2)
    assert ended["off_track"]["date"] == slip.isoformat()
    assert ended["off_track"]["summary"] == (
        f"On {slip.strftime('%A')} {slip.day} {slip.strftime('%B')}, in a change week, you logged more than 4 "
        "units of alcohol for the week, so this experiment has ended.")
    restarted = client.post("/insights/experiment/restart", headers=headers).json()["experiment"]
    assert restarted["status"] == "active" and restarted["behaviour_id"] == "alcohol_week_4"
    assert restarted["start_date"] == (datetime.now(UTC).date() + timedelta(days=1)).isoformat()
    again = client.post("/insights/experiment/restart", headers=headers)
    assert again.status_code == 404 and again.json()["detail"]["code"] == "nothing_to_restart"
