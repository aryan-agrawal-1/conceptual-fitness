from __future__ import annotations

from datetime import UTC, datetime, timedelta

from fastapi.testclient import TestClient

from app.main import app
from app.models import (
    ExerciseCatalogItem,
    User,
    UserProfile,
    Workout,
    WorkoutSource,
)


def _user(session) -> User:
    user = User()
    session.add(user)
    session.flush()
    session.add(UserProfile(user_id=user.id, timezone="Europe/London"))
    session.flush()
    return user


def _catalog_item(session) -> ExerciseCatalogItem:
    item = ExerciseCatalogItem(
        external_id="Barbell_Bench_Press_-_Medium_Grip",
        source="free-exercise-db",
        source_version="test",
        name="Barbell Bench Press",
        aliases=["Bench Press"],
        instructions=["Lower the bar with control."],
        media=[],
        equipment="barbell",
        category="strength",
        movement_pattern="horizontal_push",
        primary_muscles=["chest"],
        secondary_muscles=["triceps", "shoulders"],
        measurement_schema="reps_load",
        default_rest_seconds=150,
        is_curated=True,
    )
    session.add(item)
    session.flush()
    return item


def _workout_payload(item: ExerciseCatalogItem, *, client_id: str = "client-workout-0001") -> dict:
    start = datetime(2026, 7, 22, 17, 0, tzinfo=UTC)
    return {
        "client_id": client_id,
        "workout_type": "strength",
        "start_time": start.isoformat(),
        "end_time": (start + timedelta(hours=1)).isoformat(),
        "timezone": "Europe/London",
        "status": "completed",
        "notes": "Felt good",
        "session_rpe": 7,
        "exercises": [
            {
                "exercise_id": item.id,
                "name": item.name,
                "measurement_schema": "reps_load",
                "sets": [
                    {
                        "status": "completed",
                        "reps": 8,
                        "load_value": 60,
                        "load_unit": "kg",
                        "load_per_implement": 30,
                        "implement_count": 2,
                        "side_count": 1,
                        "rir": 2,
                    },
                    {
                        "status": "planned",
                        "reps": 8,
                        "load_value": 60,
                        "load_unit": "kg",
                    },
                ],
            }
        ],
    }


def test_custom_exercise_is_private_and_searchable(session, auth_headers) -> None:
    owner = _user(session)
    other = _user(session)
    session.commit()
    client = TestClient(app)

    response = client.post(
        "/fitness/exercises",
        headers=auth_headers(owner),
        json={
            "name": "My Cable Press",
            "measurement_schema": "reps_load",
            "equipment": "cable",
            "primary_muscles": ["chest"],
        },
    )

    assert response.status_code == 201
    exercise_id = response.json()["id"]
    assert response.json()["is_custom"] is True
    assert [
        item["id"]
        for item in client.get(
            "/fitness/exercises?query=cable",
            headers=auth_headers(owner),
        ).json()
    ] == [exercise_id]
    assert client.get(
        "/fitness/exercises?query=cable",
        headers=auth_headers(other),
    ).json() == []


def test_exercise_options_use_catalog_and_keep_custom_values_private(session, auth_headers) -> None:
    owner = _user(session)
    other = _user(session)
    _catalog_item(session)
    session.add_all(
        [
            ExerciseCatalogItem(
                user_id=owner.id,
                source="custom",
                name="My Cable Kickback",
                equipment="cable",
                primary_muscles=["glutes"],
                measurement_schema="reps_load",
            ),
            ExerciseCatalogItem(
                user_id=other.id,
                source="custom",
                name="Private Neck Harness",
                equipment="other",
                primary_muscles=["neck"],
                measurement_schema="reps_load",
            ),
        ]
    )
    session.commit()
    client = TestClient(app)

    response = client.get("/fitness/exercise-options", headers=auth_headers(owner))

    assert response.status_code == 200
    assert response.json()["equipment"] == ["barbell", "cable"]
    assert response.json()["muscles"] == ["chest", "glutes", "shoulders", "triceps"]


def test_create_workout_is_idempotent_and_returns_exercise_summary(session, auth_headers) -> None:
    user = _user(session)
    item = _catalog_item(session)
    session.commit()
    client = TestClient(app)
    headers = auth_headers(user)
    payload = _workout_payload(item)

    created = client.post("/fitness/workouts", headers=headers, json=payload)
    repeated = client.post("/fitness/workouts", headers=headers, json=payload)

    assert created.status_code == 201
    assert repeated.status_code == 201
    assert repeated.json()["id"] == created.json()["id"]
    assert created.json()["summary"] == {
        "exercise_count": 1,
        "completed_set_count": 1,
        "volume_kg": 480.0,
    }
    assert created.json()["muscles_trained"][0] == {
        "muscle": "chest",
        "set_equivalents": 1.0,
    }
    assert created.json()["exercises"][0]["sets"][1]["status"] == "planned"

    overview = client.get("/fitness/overview", headers=headers)
    assert overview.status_code == 200
    assert overview.json()["recent_workouts"][0]["id"] == created.json()["id"]


def test_workout_revision_rejects_stale_updates(session, auth_headers) -> None:
    user = _user(session)
    item = _catalog_item(session)
    session.commit()
    client = TestClient(app)
    headers = auth_headers(user)
    created = client.post(
        "/fitness/workouts",
        headers=headers,
        json=_workout_payload(item),
    ).json()
    update = _workout_payload(item)
    update.pop("client_id")
    update["revision"] = created["revision"]
    update["notes"] = "Updated"

    response = client.put(f"/fitness/workouts/{created['id']}", headers=headers, json=update)
    stale = client.put(f"/fitness/workouts/{created['id']}", headers=headers, json=update)

    assert response.status_code == 200
    assert response.json()["notes"] == "Updated"
    assert response.json()["revision"] == created["revision"] + 1
    assert stale.status_code == 409


def test_exercise_favorite_history_and_save_as_routine(session, auth_headers) -> None:
    user = _user(session)
    item = _catalog_item(session)
    session.commit()
    client = TestClient(app)
    headers = auth_headers(user)
    workout = client.post(
        "/fitness/workouts",
        headers=headers,
        json=_workout_payload(item),
    ).json()

    assert client.post(
        f"/fitness/exercises/{item.id}/favorite",
        headers=headers,
    ).status_code == 204
    search = client.get("/fitness/exercises?query=bench", headers=headers).json()
    assert search[0]["id"] == item.id
    assert search[0]["is_favorite"] is True
    assert search[0]["use_count"] == 1
    assert client.get("/fitness/exercises?query=barbell", headers=headers).json()[0]["id"] == item.id
    assert client.get("/fitness/exercises?query=chest", headers=headers).json()[0]["id"] == item.id

    history = client.get(
        f"/fitness/exercises/{item.id}/history",
        headers=headers,
    )
    assert history.status_code == 200
    assert history.json()["records"]["estimated_one_rep_max_kg"] == 80.0
    assert history.json()["records"]["total_volume_kg"] == 480.0

    routine = client.post(
        f"/fitness/workouts/{workout['id']}/save-as-routine",
        headers=headers,
        json={"name": "Saved Push", "scheduled_weekdays": [1, 4]},
    )
    assert routine.status_code == 201
    assert routine.json()["name"] == "Saved Push"
    assert routine.json()["exercises"][0]["target_sets"] == 1
    assert routine.json()["exercises"][0]["target_reps_min"] == 8


def test_routine_start_snapshots_planned_sets_and_marks_due(session, auth_headers) -> None:
    user = _user(session)
    item = _catalog_item(session)
    session.commit()
    client = TestClient(app)
    headers = auth_headers(user)
    weekday = datetime.now(UTC).astimezone().isoweekday()
    routine_response = client.post(
        "/fitness/routines",
        headers=headers,
        json={
            "name": "Push Day",
            "scheduled_weekdays": [weekday],
            "is_favorite": True,
            "exercises": [
                {
                    "exercise_id": item.id,
                    "name": item.name,
                    "measurement_schema": "reps_load",
                    "target_sets": 3,
                    "target_reps_min": 8,
                    "target_reps_max": 10,
                    "target_load_value": 60,
                    "target_load_unit": "kg",
                    "rest_seconds": 150,
                }
            ],
        },
    )

    assert routine_response.status_code == 201
    routine = routine_response.json()
    overview = client.get("/fitness/overview", headers=headers).json()
    assert overview["due_routines"][0]["id"] == routine["id"]

    started = client.post(
        f"/fitness/routines/{routine['id']}/start?client_id=routine-start-0001",
        headers=headers,
    )
    assert started.status_code == 201
    assert started.json()["status"] == "active"
    assert len(started.json()["exercises"][0]["sets"]) == 3
    assert all(item["status"] == "planned" for item in started.json()["exercises"][0]["sets"])


def test_manual_workout_enriches_high_confidence_wearable_match(session, auth_headers) -> None:
    user = _user(session)
    item = _catalog_item(session)
    start = datetime(2026, 7, 22, 17, 0, tzinfo=UTC)
    provider = Workout(
        user_id=user.id,
        workout_type="strength",
        start_time=start,
        end_time=start + timedelta(hours=1),
        civil_date=start.date(),
        duration_seconds=3600,
        origin="wearable",
        status="completed",
        raw_summary={},
    )
    session.add(provider)
    session.flush()
    session.add(
        WorkoutSource(
            user_id=user.id,
            workout_id=provider.id,
            provider="google_health",
            source_record_id="provider-workout-1",
            start_time=provider.start_time,
            end_time=provider.end_time,
            payload={},
        )
    )
    session.commit()

    response = TestClient(app).post(
        "/fitness/workouts",
        headers=auth_headers(user),
        json=_workout_payload(item),
    )

    assert response.status_code == 201
    assert response.json()["id"] == provider.id
    assert response.json()["origin"] == "mixed"
    assert response.json()["sources"][0]["source_record_id"] == "provider-workout-1"
    assert response.json()["summary"]["completed_set_count"] == 1


def test_deleted_workout_is_hidden_but_retains_source_tombstone(session, auth_headers) -> None:
    user = _user(session)
    start = datetime(2026, 7, 22, 17, 0, tzinfo=UTC)
    workout = Workout(
        user_id=user.id,
        workout_type="run",
        start_time=start,
        end_time=start + timedelta(minutes=30),
        civil_date=start.date(),
        duration_seconds=1800,
        origin="wearable",
        status="completed",
        raw_summary={},
    )
    session.add(workout)
    session.flush()
    session.add(
        WorkoutSource(
            user_id=user.id,
            workout_id=workout.id,
            provider="google_health",
            source_record_id="delete-source-1",
            payload={},
        )
    )
    session.commit()
    client = TestClient(app)
    headers = auth_headers(user)

    response = client.delete(f"/fitness/workouts/{workout.id}", headers=headers)

    assert response.status_code == 204
    assert client.get("/fitness/overview", headers=headers).json()["recent_workouts"] == []
    session.expire_all()
    retained = session.get(Workout, workout.id)
    assert retained is not None
    assert retained.deleted_at is not None
    assert session.query(WorkoutSource).filter_by(workout_id=workout.id).count() == 1
