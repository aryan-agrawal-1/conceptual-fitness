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
    assert payload["primary_goal"] is None
    assert payload["secondary_goals"] == []
    assert payload["constraints"] == {
        "schedule": [],
        "equipment": [],
        "injuries": [],
        "dietary_preferences": [],
        "sleep_schedule": None,
    }
    assert payload["unit_system"] == "metric"
    assert payload["height_provenance"] == {
        "preference": "google",
        "active_source": None,
        "updated_at": None,
    }
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
            "secondary_goals": ["build strength", "improve mobility"],
            "constraints": {
                "schedule": ["Weekdays after 18:00"],
                "equipment": ["Dumbbells"],
                "injuries": ["Previous left ankle sprain"],
                "dietary_preferences": ["Vegetarian"],
                "sleep_schedule": "23:00-07:00",
            },
            "unit_system": "imperial",
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
    assert payload["primary_goal"] == "improve_cardio"
    assert payload["secondary_goals"] == ["build strength", "improve mobility"]
    assert payload["constraints"]["equipment"] == ["Dumbbells"]
    assert payload["constraints"]["sleep_schedule"] == "23:00-07:00"
    assert payload["unit_system"] == "imperial"
    assert payload["sleep_target_minutes"] == 510
    assert payload["onboarding_completed_at"] is not None


def test_profile_primary_goal_alias_partial_constraints_and_explicit_clears(
    session,
    auth_headers,
) -> None:
    user = _user(session)
    client = TestClient(app)

    first = client.patch(
        "/profile",
        headers=auth_headers(user),
        json={
            "primary_goal": "  Run a marathon  ",
            "secondary_goals": ["  Sleep better  ", "Sleep better"],
            "constraints": {"equipment": ["  Treadmill  "]},
        },
    )
    retry = client.patch(
        "/profile",
        headers=auth_headers(user),
        json={
            "fitness_goal": " Run a marathon ",
            "primary_goal": "Run a marathon",
            "secondary_goals": ["Sleep better"],
            "constraints": {"equipment": ["Treadmill"]},
        },
    )

    assert first.status_code == retry.status_code == 200
    assert retry.json()["fitness_goal"] == "Run a marathon"
    assert retry.json()["secondary_goals"] == ["Sleep better"]
    assert retry.json()["constraints"]["equipment"] == ["Treadmill"]

    cleared = client.patch(
        "/profile",
        headers=auth_headers(user),
        json={"primary_goal": None, "secondary_goals": [], "constraints": None},
    )

    assert cleared.status_code == 200
    assert cleared.json()["fitness_goal"] is None
    assert cleared.json()["secondary_goals"] == []
    assert cleared.json()["constraints"]["equipment"] == []


def test_profile_rejects_conflicting_goal_aliases_and_unknown_constraints(
    session,
    auth_headers,
) -> None:
    user = _user(session)
    client = TestClient(app)

    conflicting = client.patch(
        "/profile",
        headers=auth_headers(user),
        json={"fitness_goal": "strength", "primary_goal": "endurance"},
    )
    unknown = client.patch(
        "/profile",
        headers=auth_headers(user),
        json={"constraints": {"unsupported": ["value"]}},
    )
    null_preference = client.patch(
        "/profile",
        headers=auth_headers(user),
        json={"weight_source_preference": None},
    )

    assert conflicting.status_code == 422
    assert unknown.status_code == 422
    assert null_preference.status_code == 422


def test_profile_reports_preferred_body_metric_provenance(session, auth_headers) -> None:
    user = _user(session)
    session.add_all(
        [
            MetricSample(
                user_id=user.id,
                metric="weight",
                observed_at=datetime(2026, 6, 20, 9, tzinfo=UTC),
                civil_date=date(2026, 6, 20),
                value=80,
                unit="kg",
                source_platform="FITBIT",
            ),
            MetricSample(
                user_id=user.id,
                metric="weight",
                observed_at=datetime(2026, 6, 21, 9, tzinfo=UTC),
                civil_date=date(2026, 6, 21),
                value=79,
                unit="kg",
                source_platform="manual",
            ),
        ]
    )
    session.commit()
    client = TestClient(app)

    provider = client.get("/profile", headers=auth_headers(user))
    manual = client.patch(
        "/profile",
        headers=auth_headers(user),
        json={"weight_source_preference": "manual"},
    )

    assert provider.status_code == manual.status_code == 200
    assert provider.json()["weight_kg"] == 80
    assert provider.json()["weight_provenance"] == {
        "preference": "google",
        "active_source": "FITBIT",
        "updated_at": "2026-06-20T09:00:00",
    }
    assert manual.json()["weight_provenance"] == {
        "preference": "manual",
        "active_source": "manual",
        "updated_at": "2026-06-21T09:00:00",
    }
    assert manual.json()["weight_kg"] == 79


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
