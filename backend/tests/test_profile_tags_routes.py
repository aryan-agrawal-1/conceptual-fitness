from __future__ import annotations

from datetime import date, datetime, UTC

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.main import app
from app.models import DailyContext, MetricSample, User, UserProfile


def _user(session) -> User:
    user = User(email="profile@example.com")
    session.add(user)
    session.commit()
    return user


def test_profile_get_creates_default_profile(session, auth_headers) -> None:
    user = _user(session)
    client = TestClient(app)

    response = client.get("/profile", headers=auth_headers(user))

    assert response.status_code == 200
    payload = response.json()
    assert payload["user_id"] == user.id
    assert payload["timezone"] == "UTC"
    assert payload["sleep_target_minutes"] == 480
    assert payload["fitness_goal"] is None
    assert payload["weather_enabled"] is False
    assert payload["height_source_preference"] == "google"
    assert payload["weight_source_preference"] == "google"
    assert payload["onboarding_completed_at"] is None
    assert session.scalar(select(UserProfile).where(UserProfile.user_id == user.id)) is not None


def test_profile_patch_updates_supported_fields(session, auth_headers) -> None:
    user = _user(session)
    client = TestClient(app)

    response = client.patch(
        "/profile",
        headers=auth_headers(user),
        json={
            "timezone": "Europe/London",
            "birth_year": 1994,
            "sex": "male",
            "height_cm": 181.5,
            "weight_kg": 78.2,
            "weather_enabled": True,
            "location_permission_status": "authorized",
            "height_source_preference": "manual",
            "weight_source_preference": "manual",
            "fitness_goal": "improve_cardio",
            "sleep_target_minutes": 510,
            "onboarding_completed": True,
        },
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["timezone"] == "Europe/London"
    assert payload["birth_year"] == 1994
    assert payload["height_cm"] == 181.5
    assert payload["weight_kg"] == 78.2
    assert payload["weather_enabled"] is True
    assert payload["location_permission_status"] == "authorized"
    assert payload["height_source_preference"] == "manual"
    assert payload["weight_source_preference"] == "manual"
    assert payload["fitness_goal"] == "improve_cardio"
    assert payload["sleep_target_minutes"] == 510
    assert payload["onboarding_completed_at"] is not None


def test_profile_rejects_unknown_timezone(session, auth_headers) -> None:
    user = _user(session)
    client = TestClient(app)

    response = client.patch(
        "/profile",
        headers=auth_headers(user),
        json={"timezone": "Not/AZone"},
    )

    assert response.status_code == 422


def test_profile_rejects_unknown_sex(session, auth_headers) -> None:
    user = _user(session)
    client = TestClient(app)

    response = client.patch(
        "/profile",
        headers=auth_headers(user),
        json={"sex": "other"},
    )

    assert response.status_code == 422


def test_manual_body_metrics_preference_blocks_synced_profile_overwrite(
    session,
    auth_headers,
) -> None:
    user = _user(session)
    profile = UserProfile(
        user_id=user.id,
        timezone="UTC",
        height_cm=181,
        weight_kg=78,
        height_source_preference="manual",
        weight_source_preference="manual",
        sleep_target_minutes=480,
    )
    session.add_all(
        [
            profile,
            MetricSample(
                user_id=user.id,
                metric="height",
                observed_at=datetime(2026, 6, 22, 9, tzinfo=UTC),
                civil_date=date(2026, 6, 22),
                value=1.9,
                unit="meters",
                source_platform="FITBIT",
            ),
            MetricSample(
                user_id=user.id,
                metric="weight",
                observed_at=datetime(2026, 6, 22, 9, tzinfo=UTC),
                civil_date=date(2026, 6, 22),
                value=86,
                unit="kg",
                source_platform="FITBIT",
            ),
        ]
    )
    session.commit()
    client = TestClient(app)

    response = client.get("/body-metrics", headers=auth_headers(user))

    assert response.status_code == 200
    payload = response.json()
    assert payload["height_cm"] == 181
    assert payload["weight_kg"] == 78


def test_tags_crud_is_scoped_to_current_user(session, auth_headers) -> None:
    user = _user(session)
    other = _user(session)
    client = TestClient(app)

    create_response = client.post(
        "/tags",
        headers=auth_headers(user),
        json={
            "date": "2026-06-19",
            "type": "caffeine",
            "severity": "moderate",
            "value": {"amount_mg": 160, "time": "15:30"},
        },
    )
    assert create_response.status_code == 201
    tag = create_response.json()
    assert tag["type"] == "caffeine"
    assert tag["source"] == "manual"

    list_response = client.get(
        "/tags",
        params={"start": "2026-06-18", "end": "2026-06-20"},
        headers=auth_headers(user),
    )
    assert list_response.status_code == 200
    assert [item["id"] for item in list_response.json()] == [tag["id"]]

    blocked_response = client.patch(
        f"/tags/{tag['id']}",
        headers=auth_headers(other),
        json={"severity": "high"},
    )
    assert blocked_response.status_code == 404

    update_response = client.patch(
        f"/tags/{tag['id']}",
        headers=auth_headers(user),
        json={"severity": "high", "value": {"amount_mg": 200}},
    )
    assert update_response.status_code == 200
    assert update_response.json()["severity"] == "high"
    assert update_response.json()["value"] == {"amount_mg": 200}

    delete_response = client.delete(f"/tags/{tag['id']}", headers=auth_headers(user))
    assert delete_response.status_code == 204
    assert session.get(DailyContext, tag["id"]) is None


def test_tag_types_include_basic_manual_tags() -> None:
    client = TestClient(app)

    response = client.get("/tags/types")

    assert response.status_code == 200
    assert {"alcohol", "caffeine", "illness", "poor_sleep", "unusual_workout"}.issubset(
        set(response.json()["types"])
    )
