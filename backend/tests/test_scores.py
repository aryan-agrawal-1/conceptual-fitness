from __future__ import annotations

from datetime import UTC, date, datetime, time, timedelta

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.main import app
from app.models import (
    DailyScore,
    DailySummary,
    GoogleAccount,
    MetricSample,
    ScoreStatus,
    SleepSession,
    SyncCursor,
    SyncStatus,
    User,
    UserProfile,
    Workout,
)
from app.services.scores import (
    READINESS_SCORE_VERSION,
    SLEEP_SCORE_VERSION,
    STRAIN_LOAD_VERSION,
    rebuild_derived_scores,
)
from app.services.normalization import upsert_raw_and_normalized


def _user_with_profile(session, *, birth_year: int = 1992) -> User:
    user = User()
    session.add(user)
    session.flush()
    session.add(
        UserProfile(
            user_id=user.id,
            timezone="UTC",
            birth_year=birth_year,
            sleep_target_minutes=480,
        )
    )
    session.add(
        GoogleAccount(
            user_id=user.id,
            health_user_id=f"health-{user.id}",
            legacy_user_id=f"legacy-{user.id}",
            granted_scopes=[],
        )
    )
    session.flush()
    return user


def _dt(day: date, hour: int, minute: int = 0) -> datetime:
    return datetime.combine(day, time(hour, minute), tzinfo=UTC)


def _add_sleep(
    session,
    user: User,
    day: date,
    *,
    minutes_asleep: int = 455,
    minutes_awake: int = 35,
    start_hour: int = 22,
    start_minute: int = 30,
) -> None:
    start_day = day - timedelta(days=1) if start_hour >= 12 else day
    start = _dt(start_day, start_hour, start_minute)
    end = start + timedelta(minutes=minutes_asleep + minutes_awake)
    session.add(
        SleepSession(
            user_id=user.id,
            start_time=start,
            end_time=end,
            civil_date=day,
            minutes_asleep=minutes_asleep,
            minutes_awake=minutes_awake,
            minutes_in_sleep_period=minutes_asleep + minutes_awake,
            stages_summary=[
                {"type": "REM", "minutes": 95},
                {"type": "DEEP", "minutes": 70},
            ],
            stages=[],
            is_main_sleep=True,
        )
    )


def _add_summary(
    session,
    user: User,
    day: date,
    *,
    hrv: float = 58,
    rhr: float = 56,
    sleep_minutes: int = 455,
    steps: int = 6500,
    active_calories: float = 320,
) -> None:
    session.add(
        DailySummary(
            user_id=user.id,
            summary_date=day,
            steps=steps,
            active_calories=active_calories,
            total_calories=2300,
            distance_meters=5200,
            resting_heart_rate=rhr,
            heart_rate_variability=hrv,
            oxygen_saturation=97,
            respiratory_rate=14.5,
            sleep_minutes=sleep_minutes,
            workout_count=0,
            data_quality="strong",
        )
    )


def _add_hr_workout(session, user: User, day: date, *, bpm: float = 152) -> None:
    start = _dt(day, 7, 0)
    end = start + timedelta(minutes=30)
    session.add(
        Workout(
            user_id=user.id,
            workout_type="running",
            start_time=start,
            end_time=end,
            civil_date=day,
            duration_seconds=1800,
            raw_summary={},
        )
    )
    for index in range(31):
        session.add(
            MetricSample(
                user_id=user.id,
                metric="heart_rate",
                observed_at=start + timedelta(minutes=index),
                civil_date=day,
                value=bpm,
                unit="bpm",
            )
        )


def test_scores_wait_for_required_sleep(session) -> None:
    user = _user_with_profile(session)
    day = date.today() - timedelta(days=1)
    _add_summary(session, user, day, sleep_minutes=0)

    rebuild_derived_scores(session, user_id=user.id, start=day, end=day)
    session.commit()

    sleep = session.scalar(
        select(DailyScore).where(
            DailyScore.user_id == user.id,
            DailyScore.score_type == "sleep",
        )
    )
    readiness = session.scalar(
        select(DailyScore).where(
            DailyScore.user_id == user.id,
            DailyScore.score_type == "readiness",
        )
    )

    assert sleep.value is None
    assert sleep.status.value == "waiting_for_sleep"
    assert readiness.value is None
    assert readiness.status.value == "waiting_for_sleep"


def test_rebuild_scores_materializes_sleep_strain_readiness_and_target(session) -> None:
    user = _user_with_profile(session, birth_year=1990)
    today = date.today()
    start = today - timedelta(days=30)
    for offset in range(31):
        day = start + timedelta(days=offset)
        _add_sleep(session, user, day)
        _add_summary(session, user, day)
    _add_hr_workout(session, user, today, bpm=154)

    result = rebuild_derived_scores(session, user_id=user.id, start=start, end=today)
    session.commit()

    assert result.scores_rebuilt == 93

    sleep = session.scalar(
        select(DailyScore).where(
            DailyScore.user_id == user.id,
            DailyScore.score_date == today,
            DailyScore.score_type == "sleep",
            DailyScore.algorithm_version == SLEEP_SCORE_VERSION,
        )
    )
    strain = session.scalar(
        select(DailyScore).where(
            DailyScore.user_id == user.id,
            DailyScore.score_date == today,
            DailyScore.score_type == "strain",
            DailyScore.algorithm_version == STRAIN_LOAD_VERSION,
        )
    )
    readiness = session.scalar(
        select(DailyScore).where(
            DailyScore.user_id == user.id,
            DailyScore.score_date == today,
            DailyScore.score_type == "readiness",
            DailyScore.algorithm_version == READINESS_SCORE_VERSION,
        )
    )

    assert sleep.status.value == "scored"
    assert sleep.confidence_phase == "personalized"
    assert set(sleep.components) == {
        "duration",
        "regularity",
        "continuity",
        "timing",
        "physiology",
        "stages",
    }
    assert sleep.value and sleep.value >= 80

    assert strain.value and strain.value > 10
    assert strain.value_unit == "load_points"
    assert strain.components["cardio_load"]["workout_coverage_ratio"] >= 0.9
    assert strain.components["cardio_load"]["workout_load_points"] > 0
    assert strain.components["cardio_load"]["general_activity_load_points"] >= 0
    assert strain.components["workout_contributions"][0]["load_points"] > 0
    assert strain.inputs["max_hr_source"] in {"hunt_age_formula", "observed_sustained_workout"}

    assert readiness.status.value == "scored"
    assert readiness.value and readiness.value > 60
    assert readiness.inputs["uses_same_day_strain"] is False


def test_sleep_stage_score_uses_timeline_not_duplicated_summary(session) -> None:
    user = _user_with_profile(session, birth_year=1990)
    day = date.today()
    start = _dt(day, 2, 28)
    stages = [
        ("AWAKE", 35),
        ("LIGHT", 188),
        ("DEEP", 87),
        ("REM", 64),
    ]
    cursor = start
    timeline = []
    for stage, minutes in stages:
        next_cursor = cursor + timedelta(minutes=minutes)
        timeline.append(
            {
                "stage": stage,
                "startTime": cursor.isoformat().replace("+00:00", "Z"),
                "endTime": next_cursor.isoformat().replace("+00:00", "Z"),
            }
        )
        cursor = next_cursor
    session.add(
        SleepSession(
            user_id=user.id,
            start_time=start,
            end_time=cursor,
            civil_date=day,
            minutes_asleep=340,
            minutes_awake=35,
            minutes_in_sleep_period=375,
            stages_summary=[
                {"type": "AWAKE", "minutes": "35", "count": "1"},
                {"type": "LIGHT", "minutes": "188", "count": "1"},
                {"type": "DEEP", "minutes": "87", "count": "1"},
                {"type": "REM", "minutes": "64", "count": "1"},
                {"type": "AWAKE", "minutes": "35", "count": "1"},
                {"type": "LIGHT", "minutes": "188", "count": "1"},
                {"type": "DEEP", "minutes": "87", "count": "1"},
                {"type": "REM", "minutes": "64", "count": "1"},
            ],
            stages=timeline,
            is_main_sleep=True,
        )
    )
    _add_summary(session, user, day, sleep_minutes=340)

    rebuild_derived_scores(session, user_id=user.id, start=day, end=day)
    session.commit()

    sleep = session.scalar(
        select(DailyScore).where(
            DailyScore.user_id == user.id,
            DailyScore.score_date == day,
            DailyScore.score_type == "sleep",
            DailyScore.algorithm_version == SLEEP_SCORE_VERSION,
        )
    )

    stages_component = sleep.components["stages"]
    assert stages_component["rem_minutes"] == 64
    assert stages_component["deep_minutes"] == 87
    assert stages_component["rem_percent"] == 0.188
    assert stages_component["deep_percent"] == 0.256
    assert stages_component["score"] > 90


def test_strain_uses_observed_resting_hr_when_daily_rhr_missing(session) -> None:
    user = _user_with_profile(session, birth_year=2005)
    day = date.today() - timedelta(days=1)
    _add_summary(session, user, day, rhr=None, steps=0, active_calories=0)
    start = _dt(day, 6, 0)
    for index in range(180):
        bpm = 58 if index < 30 else 128
        session.add(
            MetricSample(
                user_id=user.id,
                metric="heart_rate",
                observed_at=start + timedelta(minutes=index),
                civil_date=day,
                value=bpm,
                unit="bpm",
            )
        )

    rebuild_derived_scores(session, user_id=user.id, start=day, end=day)
    session.commit()

    strain = session.scalar(
        select(DailyScore).where(
            DailyScore.user_id == user.id,
            DailyScore.score_date == day,
            DailyScore.score_type == "strain",
            DailyScore.algorithm_version == STRAIN_LOAD_VERSION,
        )
    )

    assert strain.inputs["resting_hr_source"] == "observed_low_percentile"
    assert strain.inputs["hr_sample_count"] == 180
    assert strain.components["cardio_load"]["load_points"] > 0


def test_strain_uses_time_in_zone_intervals_when_hr_confidence_weak(session) -> None:
    user = _user_with_profile(session, birth_year=2005)
    account = session.scalar(select(GoogleAccount).where(GoogleAccount.user_id == user.id))
    day = date.today() - timedelta(days=1)
    _add_summary(session, user, day, rhr=None, steps=0, active_calories=0)
    upsert_raw_and_normalized(
        session,
        account=account,
        data_type="time-in-heart-rate-zone",
        data_point={
            "name": "users/me/dataTypes/time-in-heart-rate-zone/dataPoints/1",
            "timeInHeartRateZone": {
                "interval": {
                    "startTime": f"{day.isoformat()}T08:00:00Z",
                    "endTime": f"{day.isoformat()}T08:30:00Z",
                    "civilStartTime": {"date": {"year": day.year, "month": day.month, "day": day.day}},
                },
                "heartRateZoneType": "VIGOROUS",
            },
        },
    )

    rebuild_derived_scores(session, user_id=user.id, start=day, end=day)
    session.commit()

    strain = session.scalar(
        select(DailyScore).where(
            DailyScore.user_id == user.id,
            DailyScore.score_date == day,
            DailyScore.score_type == "strain",
            DailyScore.algorithm_version == STRAIN_LOAD_VERSION,
        )
    )

    assert strain.components["source_zone_load"] == {
        "load_points": 24.0,
        "zones_seen": 1,
        "source": "time_in_heart_rate_zone",
        "workout_load_points": 0.0,
        "general_activity_load_points": 24.0,
        "workouts": [],
    }
    assert strain.value == 24.0


def test_scores_api_rebuild_and_history(session, auth_headers) -> None:
    user = _user_with_profile(session)
    day = date.today()
    _add_sleep(session, user, day)
    _add_summary(session, user, day)
    session.commit()

    client = TestClient(app)
    response = client.post(
        "/scores/rebuild",
        params={"start": day.isoformat(), "end": day.isoformat()},
        headers=auth_headers(user),
    )
    assert response.status_code == 200
    assert response.json()["scores_rebuilt"] == 3

    history = client.get(
        "/scores/daily",
        params={"start": day.isoformat(), "end": day.isoformat()},
        headers=auth_headers(user),
    )
    assert history.status_code == 200
    payload = history.json()
    assert {item["score_type"] for item in payload} == {"sleep", "readiness", "strain"}

    dashboard = client.get("/dashboard/today", headers=auth_headers(user))
    assert dashboard.status_code == 200
    assert set(dashboard.json()["scores"]) == {"sleep", "readiness", "strain"}


def test_dashboard_bundle_returns_frontend_dashboard_payload(session, auth_headers) -> None:
    user = _user_with_profile(session)
    day = date.today()
    _add_sleep(session, user, day)
    _add_summary(session, user, day)
    _add_hr_workout(session, user, day)
    session.add(
        MetricSample(
            user_id=user.id,
            metric="skin_temperature_variation",
            observed_at=_dt(day, 0),
            civil_date=day,
            value=0.24,
            unit="celsius",
        )
    )
    session.add(
        MetricSample(
            user_id=user.id,
            metric="vo2_max",
            observed_at=_dt(day, 7, 30),
            civil_date=day,
            value=48.2,
            unit="ml_per_kg_min",
        )
    )
    account = session.scalar(select(GoogleAccount).where(GoogleAccount.user_id == user.id))
    session.add(
        SyncCursor(
            google_account_id=account.id,
            data_type="daily-summary",
            status=SyncStatus.succeeded,
            last_successful_start=day,
            last_successful_end=day,
        )
    )
    rebuild_derived_scores(session, user_id=user.id, start=day, end=day)
    session.commit()

    response = TestClient(app).get(
        "/dashboard/bundle",
        params={"date": day.isoformat(), "metrics_window_days": 1},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["user_id"] == user.id
    assert payload["date"] == day.isoformat()
    assert payload["profile"]["timezone"] == "UTC"
    assert len(payload["connections"]["google_health"]) == 1
    assert payload["sync_status"][0]["status"] == "succeeded"
    assert payload["snapshot"]["metrics"]["heart_rate_variability"] == 58.0
    assert set(payload["snapshot"]["scores"]) == {"sleep", "readiness", "strain"}
    assert payload["recent_workouts"][0]["workout_type"] == "running"
    assert payload["vo2_max"]["current"] == {
        "date": day.isoformat(),
        "value": 48.2,
        "unit": "ml_per_kg_min",
    }
    assert list(payload["metric_summaries"]) == [
        "heart_rate_variability",
        "resting_heart_rate",
        "heart_rate",
        "skin_temperature_variation",
        "oxygen_saturation",
        "respiratory_rate",
        "vo2_max",
        "sleep",
        "steps",
        "total_calories",
        "distance",
    ]
    assert payload["metric_summaries"]["total_calories"]["current"] == {
        "date": day.isoformat(),
        "value": 2300.0,
        "unit": "kcal",
    }
    assert payload["metric_summaries"]["heart_rate"]["current"]["value"] == 152.0
    assert payload["metric_summaries"]["heart_rate"]["current"]["unit"] == "bpm"
    assert payload["metric_summaries"]["heart_rate"]["current"]["date"].startswith(day.isoformat())
    assert payload["metric_summaries"]["skin_temperature_variation"]["current"] == {
        "date": day.isoformat(),
        "value": 0.24,
        "unit": "celsius",
    }
    assert payload["metric_summaries"]["steps"]["current"]["value"] == 6500.0
    assert payload["data_quality"]["sections"]["sync"] == "strong"


def test_strain_detail_returns_timeframe_scoped_page_payload(session, auth_headers) -> None:
    user = _user_with_profile(session, birth_year=1990)
    anchor = date.today()
    start = anchor - timedelta(days=14)
    for offset in range(15):
        day = start + timedelta(days=offset)
        _add_sleep(session, user, day)
        _add_summary(session, user, day, steps=6500 + offset * 100)
        if offset in {3, 7, 14}:
            _add_hr_workout(session, user, day, bpm=150 + offset)

    rebuild_derived_scores(session, user_id=user.id, start=start, end=anchor)
    session.commit()

    response = TestClient(app).get(
        "/strain/detail",
        params={"date": anchor.isoformat(), "timeframe": "week"},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["timeframe"] == "week"
    assert payload["summary"]["title"] == "Weekly load"
    assert payload["summary"]["progress_load_points"] is not None
    assert payload["chart"]["kind"] == "daily_bars"
    assert len(payload["chart"]["points"]) == 7
    assert payload["components"]["items"]
    assert {item["key"] for item in payload["components"]["items"]} <= {
        "workouts",
        "general_activity",
    }
    assert payload["training_context"]["total_load_points"] is not None
    assert payload["guidance"]["message"]
    assert payload["data_quality"]["expected_days"] == 7
    assert payload["contributors"][0]["workout_type"] == "running"
    assert payload["contributors"][0]["strain_load_points"] > 0


def test_readiness_detail_returns_timeframe_scoped_page_payload(session, auth_headers) -> None:
    user = _user_with_profile(session, birth_year=1990)
    anchor = date.today()
    start = anchor - timedelta(days=14)
    for offset in range(15):
        day = start + timedelta(days=offset)
        _add_sleep(session, user, day, minutes_asleep=440 + offset)
        _add_summary(
            session,
            user,
            day,
            hrv=52 + offset,
            rhr=62 - min(offset, 8),
            sleep_minutes=440 + offset,
            steps=6500 + offset * 100,
        )
        if offset in {3, 7, 13}:
            _add_hr_workout(session, user, day, bpm=150 + offset)

    rebuild_derived_scores(session, user_id=user.id, start=start, end=anchor)
    session.commit()

    response = TestClient(app).get(
        "/readiness/detail",
        params={"date": anchor.isoformat(), "timeframe": "week"},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["timeframe"] == "week"
    assert payload["summary"]["title"] == "Weekly readiness"
    assert payload["summary"]["average_score"] is not None
    assert payload["summary"]["readiness_band"] in {"high", "medium", "low"}
    assert payload["chart"]["kind"] == "daily_line"
    assert len(payload["chart"]["points"]) == 7
    assert payload["components"]["items"]
    assert {item["key"] for item in payload["components"]["items"]} == {
        "sleep_adequacy_debt",
        "autonomic_recovery",
        "recent_load_fit",
        "illness_anomaly_context",
        "confidence",
    }
    assert payload["context"]["sleep_debt_minutes_7d"] is not None
    assert payload["context"]["hrv_baseline_relation"] in {
        "above_baseline",
        "below_baseline",
        "at_baseline",
    }
    assert payload["context"]["rhr_baseline_relation"] in {
        "above_baseline",
        "below_baseline",
        "at_baseline",
    }
    assert payload["context"]["load_ratio"] is not None
    assert payload["guidance"]["message"]
    assert payload["data_quality"]["expected_days"] == 7
    assert payload["data_quality"]["scored_days"] > 0

    unscored_response = TestClient(app).get(
        "/readiness/detail",
        params={"date": (anchor + timedelta(days=1)).isoformat(), "timeframe": "week"},
        headers=auth_headers(user),
    )
    assert unscored_response.status_code == 200
    unscored_payload = unscored_response.json()
    assert unscored_payload["context"]["sleep_debt_minutes_7d"] is not None
    assert unscored_payload["context"]["hrv_baseline_relation"] in {
        "above_baseline",
        "below_baseline",
        "at_baseline",
    }


def test_readiness_context_uses_selected_period_aggregates(session, auth_headers) -> None:
    user = _user_with_profile(session, birth_year=1990)
    week_start = date(2026, 6, 15)
    for offset in range(7):
        day = week_start + timedelta(days=offset)
        _add_sleep(session, user, day, minutes_asleep=450)
        session.add(
            DailyScore(
                user_id=user.id,
                score_date=day,
                score_type="readiness",
                algorithm_version=READINESS_SCORE_VERSION,
                value=70 + offset,
                value_unit="score_0_100",
                status=ScoreStatus.scored,
                confidence_phase="strong",
                data_quality="strong",
                components={
                    "sleep_adequacy_debt": {
                        "score": 80,
                        "sleep_debt_minutes_7d": 999,
                    },
                    "autonomic_recovery": {
                        "score": 80,
                        "hrv": {
                            "score": 70,
                            "value": 40 + offset,
                            "baseline": 50,
                        },
                        "rhr": {
                            "score": 85,
                            "value": 55,
                            "baseline": 60,
                        },
                    },
                    "recent_load_fit": {
                        "score": 90,
                        "load_ratio": 1.0 + offset * 0.1,
                        "yesterday_load": 10 + offset * 2,
                        "valid_strain_days": 14 + offset,
                    },
                },
                inputs={},
                reasons=[],
            )
        )
    session.commit()

    response = TestClient(app).get(
        "/readiness/detail",
        params={"date": (week_start + timedelta(days=6)).isoformat(), "timeframe": "week"},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    context = response.json()["context"]
    assert context["sleep_debt_minutes"] == 210
    assert context["sleep_debt_minutes_7d"] == 210
    assert context["sleep_debt_period_days"] == 7
    assert context["hrv_baseline_relation"] == "below_baseline"
    assert context["rhr_baseline_relation"] == "below_baseline"
    assert context["load_ratio"] == 1.3
    assert context["yesterday_load"] == 16
    assert context["valid_strain_days"] == 20


def test_readiness_detail_returns_yearly_monthly_averages(session, auth_headers) -> None:
    user = _user_with_profile(session, birth_year=1990)
    anchor = date.today()
    start = anchor.replace(day=1)
    for offset in range(0, 16):
        day = start + timedelta(days=offset)
        if day > anchor:
            break
        _add_sleep(session, user, day)
        _add_summary(session, user, day, hrv=54 + (offset % 12), rhr=58 - (offset % 5))
        if offset % 9 == 0:
            _add_hr_workout(session, user, day, bpm=148 + (offset % 8))

    rebuild_derived_scores(session, user_id=user.id, start=start, end=min(anchor, start + timedelta(days=15)))
    session.commit()

    response = TestClient(app).get(
        "/readiness/detail",
        params={"date": anchor.isoformat(), "timeframe": "year"},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["chart"]["kind"] == "monthly_average_scores"
    assert payload["summary"]["trend"] is None
    assert len(payload["chart"]["points"]) == 12
    scored_month = next(point for point in payload["chart"]["points"] if point["average_score"] is not None)
    assert scored_month["month_start_date"] == start.isoformat()
