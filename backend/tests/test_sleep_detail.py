from __future__ import annotations

from datetime import UTC, date, datetime, time, timedelta

from fastapi.testclient import TestClient

from app.main import app
from app.models import DailyScore, ScoreStatus, SleepSession, User, UserProfile
from app.services.scores import SLEEP_SCORE_VERSION


def _dt(day: date, hour: int, minute: int = 0) -> datetime:
    return datetime.combine(day, time(hour, minute), tzinfo=UTC)


def _user(session) -> User:
    user = User()
    session.add(user)
    session.flush()
    session.add(
        UserProfile(
            user_id=user.id,
            timezone="UTC",
            birth_year=1990,
            sleep_target_minutes=480,
        )
    )
    session.flush()
    return user


def _sleep(
    session,
    user: User,
    day: date,
    *,
    start_hour: int = 23,
    start_minute: int = 0,
    minutes_asleep: int = 420,
    minutes_awake: int = 40,
    is_main_sleep: bool = True,
) -> SleepSession:
    start_day = day - timedelta(days=1) if start_hour >= 12 else day
    start = _dt(start_day, start_hour, start_minute)
    sleep = SleepSession(
        user_id=user.id,
        start_time=start,
        end_time=start + timedelta(minutes=minutes_asleep + minutes_awake),
        civil_date=day,
        minutes_asleep=minutes_asleep,
        minutes_awake=minutes_awake,
        minutes_in_sleep_period=minutes_asleep + minutes_awake,
        stages_summary=[
            {"type": "REM", "minutes": 90},
            {"type": "DEEP", "minutes": 70},
        ],
        stages=[
            {
                "stage": "LIGHT",
                "startTime": start.isoformat(),
                "endTime": (start + timedelta(minutes=60)).isoformat(),
            }
        ],
        is_main_sleep=is_main_sleep,
    )
    session.add(sleep)
    session.flush()
    return sleep


def _sleep_score(session, user: User, day: date, *, value: float = 84.2) -> None:
    session.add(
        DailyScore(
            user_id=user.id,
            score_date=day,
            score_type="sleep",
            algorithm_version=SLEEP_SCORE_VERSION,
            value=value,
            value_unit="score_0_100",
            status=ScoreStatus.scored,
            confidence_phase="personalized",
            data_quality="strong",
            components={
                "duration": {"score": 90.0, "minutes": 450, "target_minutes": 480},
                "regularity": {
                    "score": 86.4,
                    "average_drift_minutes": 18.0,
                    "start_minute": 1380,
                    "end_minute": 430,
                },
                "continuity": {
                    "score": 88.0,
                    "sleep_efficiency": 0.938,
                    "minutes_awake": 30,
                },
            },
            inputs={"main_sleep_id": "sleep-id"},
            reasons=[{"code": "sleep_regularity_strong"}],
        )
    )


def test_sleep_detail_returns_current_score_consistency_series_and_sessions(session, auth_headers) -> None:
    user = _user(session)
    day_1 = date(2026, 6, 18)
    day_2 = date(2026, 6, 19)
    day_3 = date(2026, 6, 20)
    first = _sleep(session, user, day_1, minutes_asleep=400, minutes_awake=50)
    nap = _sleep(
        session,
        user,
        day_2,
        start_hour=14,
        minutes_asleep=35,
        minutes_awake=5,
        is_main_sleep=False,
    )
    current = _sleep(
        session,
        user,
        day_2,
        start_hour=22,
        start_minute=45,
        minutes_asleep=450,
        minutes_awake=30,
        is_main_sleep=True,
    )
    _sleep_score(session, user, day_2)
    session.commit()

    response = TestClient(app).get(
        "/sleep/detail",
        params={"start": day_1.isoformat(), "end": day_3.isoformat()},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["range"] == {"start": "2026-06-18", "end": "2026-06-20"}
    assert payload["current"]["id"] == current.id
    assert payload["current"]["date"] == "2026-06-19"
    assert payload["current"]["bedtime"] == "22:45"
    assert payload["current"]["wake_time"] == "06:45"
    assert payload["current"]["duration_minutes"] == 450
    assert payload["current"]["time_in_bed_minutes"] == 480
    assert payload["current"]["sleep_efficiency"] == 0.938
    assert payload["current"]["stages_summary"] == [
        {"type": "DEEP", "minutes": 70, "count": 0},
        {"type": "REM", "minutes": 90, "count": 0},
    ]
    assert payload["current"]["stages"] == current.stages
    assert payload["previous"]["id"] == first.id
    assert "stages" not in payload["previous"]
    assert payload["score"]["value"] == 84.2
    assert payload["score"]["status"] == "scored"
    assert payload["consistency"] == {
        "source": "sleep_score.regularity",
        "score": 86.4,
        "status": "consistent",
        "details": {
            "score": 86.4,
            "average_drift_minutes": 18.0,
            "start_minute": 1380,
            "end_minute": 430,
        },
    }
    assert payload["trend"]["duration_change_minutes"] == 50
    assert payload["trend"]["window_average_duration_minutes"] == 425.0
    assert payload["trend"]["window_average_efficiency"] == 0.91
    assert [point["date"] for point in payload["series"]] == [
        "2026-06-18",
        "2026-06-19",
        "2026-06-20",
    ]
    assert payload["series"][1]["sleep_session_id"] == current.id
    assert payload["series"][1]["score"] == 84.2
    assert payload["series"][2]["duration_minutes"] is None
    assert [item["id"] for item in payload["sessions"]] == [first.id, nap.id, current.id]
    assert all("stages" not in item for item in payload["sessions"])


def test_sleep_detail_uses_longest_sleep_when_no_provider_main_sleep(session, auth_headers) -> None:
    user = _user(session)
    day = date(2026, 6, 19)
    shorter = _sleep(
        session,
        user,
        day,
        start_hour=1,
        minutes_asleep=90,
        minutes_awake=10,
        is_main_sleep=False,
    )
    longer = _sleep(
        session,
        user,
        day,
        start_hour=23,
        minutes_asleep=390,
        minutes_awake=30,
        is_main_sleep=False,
    )
    session.commit()

    response = TestClient(app).get(
        "/sleep/detail",
        params={"start": day.isoformat(), "end": day.isoformat()},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["current"]["id"] == longer.id
    assert payload["previous"] is None
    assert payload["score"] is None
    assert payload["consistency"] is None
    assert payload["series"][0]["sleep_session_id"] == longer.id
    assert {item["id"] for item in payload["sessions"]} == {shorter.id, longer.id}


def test_sleep_detail_returns_timeframe_scoped_score_page_payload(session, auth_headers) -> None:
    user = _user(session)
    day_1 = date(2026, 6, 18)
    day_2 = date(2026, 6, 19)
    first = _sleep(session, user, day_1, minutes_asleep=400, minutes_awake=50)
    current = _sleep(
        session,
        user,
        day_2,
        start_hour=22,
        start_minute=45,
        minutes_asleep=450,
        minutes_awake=30,
    )
    _sleep_score(session, user, day_1, value=78.0)
    _sleep_score(session, user, day_2, value=84.0)
    session.commit()

    response = TestClient(app).get(
        "/sleep/detail",
        params={"date": day_2.isoformat(), "timeframe": "week"},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["timeframe"] == "week"
    assert payload["start"] == "2026-06-15"
    assert payload["end"] == "2026-06-21"
    assert payload["summary"]["title"] == "Weekly sleep"
    assert payload["summary"]["primary_value"] == 81.0
    assert payload["summary"]["average_sleep_minutes"] == 425.0
    assert payload["summary"]["target_met_nights"] == 0
    assert payload["summary"]["sleep_debt_minutes"] == 110
    assert payload["chart"]["kind"] == "weekly_sleep_pattern"
    assert len(payload["chart"]["points"]) == 7
    assert payload["chart"]["points"][4]["date"] == "2026-06-19"
    assert payload["chart"]["points"][4]["duration_minutes"] == 450
    assert payload["components"]["items"][0]["key"] == "duration"
    assert payload["components"]["average_items"][0]["key"] == "duration"
    assert payload["context"]["adjusted_sleep_need_minutes"] == 480.0
    assert payload["context"]["sleep_debt_minutes"] == 110
    assert payload["reasons"] == [{"code": "sleep_regularity_strong"}]
    assert [item["id"] for item in payload["sessions"]] == [first.id, current.id]
