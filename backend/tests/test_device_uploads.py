from __future__ import annotations

import json
from datetime import date, datetime, timedelta, timezone
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.core.security import encrypt_secret
from app.main import app
from app.models import (
    ConnectionStatus,
    DeletedDeviceRecord,
    DeviceSyncProgress,
    HealthConnection,
    MetricSample,
    RawHealthRecord,
    User,
)
from app.services.app_auth import create_app_auth_code, device_id_digest
from app.services.health_dates import get_or_create_profile
from app.tasks import sync as sync_tasks
from tests.oauth_fakes import FakeGoogleClient

HEART_RATE = "HKQuantityTypeIdentifierHeartRate"
SLEEP = "HKCategoryTypeIdentifierSleepAnalysis"


@pytest.fixture
def rebuilds(monkeypatch) -> list[tuple[str, date, date]]:
    queued: list[tuple[str, date, date]] = []
    monkeypatch.setattr(
        "app.api.routes.device_uploads.enqueue_score_rebuild",
        lambda user_id, start, end: queued.append((user_id, start, end)) or True,
    )
    return queued


def signed_in(session, *, timezone_name: str = "Europe/London") -> tuple[TestClient, User]:
    user = User(email="person@example.com")
    session.add(user)
    session.commit()
    get_or_create_profile(session, user.id).timezone = timezone_name
    session.commit()
    device_id = f"test-device-{uuid4()}"
    code = create_app_auth_code(session, user_id=user.id, device_id_hash=device_id_digest(device_id))
    client = TestClient(app)
    tokens = client.post("/auth/exchange", json={"code": code, "device_id": device_id}).json()
    client.headers["Authorization"] = f"Bearer {tokens['access_token']}"
    return client, user


def connected(session, **kwargs) -> tuple[TestClient, User]:
    client, user = signed_in(session, **kwargs)
    assert client.post("/connections/apple-health").status_code == 200
    return client, user


def sample(record_id: str = "A1", start: str = "2026-11-09T23:30:00+00:00", **overrides) -> dict:
    start_time = datetime.fromisoformat(start)
    return {
        "id": record_id,
        "start": start,
        "end": (start_time + timedelta(minutes=1)).isoformat(),
        "value": 62.0,
        "unit": "count/min",
        "source": {"name": "Apple Watch", "device_model": "Watch", "product_type": "Watch7,1"},
    } | overrides


def batch(samples=(), deleted_ids=(), **overrides) -> dict:
    return {
        "data_type": HEART_RATE,
        "phase": "current",
        "range_start": "2026-11-09",
        "range_end": "2026-11-10",
        "samples": list(samples),
        "deleted_ids": list(deleted_ids),
        "anchor": "anchor-1",
    } | overrides


def test_connecting_apple_health_replaces_and_revokes_the_fitbit_connection(session, monkeypatch) -> None:
    client, user = signed_in(session)
    google = FakeGoogleClient()
    monkeypatch.setattr("app.google_health.client.GoogleHealthClient", lambda: google)
    session.add(
        HealthConnection(
            user_id=user.id,
            status=ConnectionStatus.connected,
            encrypted_refresh_token=encrypt_secret("fitbit-token"),
        )
    )
    session.commit()

    response = client.post("/connections/apple-health")

    session.expire_all()
    connections = {c.provider: c for c in session.scalars(select(HealthConnection))}
    assert response.json()["provider"] == "apple_health"
    assert connections["apple_health"].status == ConnectionStatus.connected
    assert connections["google_health"].status == ConnectionStatus.disconnected
    assert google.revoked == ["fitbit-token"]
    assert client.get("/auth/me").json()["health_connection"]["provider"] == "apple_health"


def test_reconnecting_reuses_the_same_connection(session) -> None:
    client, _ = connected(session)
    client.post("/connections/apple-health/disconnect")

    client.post("/connections/apple-health")

    assert len(session.scalars(select(HealthConnection)).all()) == 1


def test_uploads_need_an_apple_health_connection(session, rebuilds) -> None:
    client, _ = signed_in(session)

    response = client.post("/ingest/apple-health/batches", json=batch([sample()]))

    assert response.status_code == 409
    assert response.json()["detail"] == {"code": "apple_health_not_connected"}


@pytest.mark.parametrize(
    "payload",
    [
        batch(data_type="HKQuantityTypeIdentifierDietaryCaffeine"),
        batch([sample(end="2026-11-09T22:00:00+00:00")]),
        batch([sample(start="2026-11-09T23:30:00")]),
        batch([sample(record_id=str(n)) for n in range(1001)]),
        batch(phase="later"),
        batch(range_start="2026-11-11"),
    ],
)
def test_invalid_batches_are_rejected(session, rebuilds, payload) -> None:
    client, _ = connected(session)

    response = client.post("/ingest/apple-health/batches", json=payload)

    assert response.status_code == 422
    assert session.scalars(select(RawHealthRecord)).all() == []


def test_non_finite_values_are_rejected(session, rebuilds) -> None:
    client, _ = connected(session)
    body = json.dumps(batch([sample()])).replace("62.0", "NaN")

    response = client.post(
        "/ingest/apple-health/batches", content=body, headers={"Content-Type": "application/json"}
    )

    assert response.status_code == 422
    assert response.json()["detail"] == {"code": "invalid_batch", "fields": ["samples.0.value"]}
    assert "NaN" not in response.text and "62" not in response.text


def test_samples_are_stored_once_with_local_dates(session, rebuilds) -> None:
    client, user = connected(session, timezone_name="America/New_York")
    payload = batch([sample("A1"), sample("A2", start="2026-11-10T12:00:00+00:00")])

    first = client.post("/ingest/apple-health/batches", json=payload).json()
    second = client.post("/ingest/apple-health/batches", json=payload).json()

    records = {r.source_record_id: r for r in session.scalars(select(RawHealthRecord))}
    assert (first["stored"], first["unchanged"]) == (2, 0)
    assert (second["stored"], second["unchanged"]) == (0, 2)
    assert records["A1"].civil_date == date(2026, 11, 9)
    assert records["A2"].civil_date == date(2026, 11, 10)
    assert records["A1"].user_id == user.id
    assert records["A1"].source_platform == "APPLE_HEALTH"
    assert records["A1"].source_device == "Apple Watch"
    assert records["A1"].raw_json["value"] == 62.0


def test_changed_samples_replace_the_stored_copy(session, rebuilds) -> None:
    client, _ = connected(session)
    client.post("/ingest/apple-health/batches", json=batch([sample(value=60.0)]))

    response = client.post("/ingest/apple-health/batches", json=batch([sample(value=64.0)])).json()

    assert response["stored"] == 1
    assert session.scalar(select(RawHealthRecord)).raw_json["value"] == 64.0


def test_sleep_counts_toward_the_morning_it_ends(session, rebuilds) -> None:
    client, _ = connected(session)
    night = sample("S1", start="2026-11-09T22:30:00+00:00", category_value=3, value=None)
    night["end"] = "2026-11-10T06:30:00+00:00"

    client.post("/ingest/apple-health/batches", json=batch([night], data_type=SLEEP))

    assert session.scalar(select(RawHealthRecord)).civil_date == date(2026, 11, 10)


def test_deletions_remove_records_and_their_scores_inputs(session, rebuilds) -> None:
    client, user = connected(session)
    client.post("/ingest/apple-health/batches", json=batch([sample("A1"), sample("A2")]))
    raw = session.scalar(select(RawHealthRecord).where(RawHealthRecord.source_record_id == "A1"))
    session.add(
        MetricSample(
            user_id=user.id,
            raw_record_id=raw.id,
            metric="heart_rate",
            observed_at=datetime(2026, 11, 9, 23, 30, tzinfo=timezone.utc),
            civil_date=date(2026, 11, 9),
            value=62.0,
            unit="bpm",
        )
    )
    session.commit()

    response = client.post("/ingest/apple-health/batches", json=batch(deleted_ids=["A1", "never-seen"])).json()

    session.expire_all()
    assert response["deleted"] == 1
    assert [r.source_record_id for r in session.scalars(select(RawHealthRecord))] == ["A2"]
    assert session.scalars(select(MetricSample)).all() == []
    assert {d.source_record_id for d in session.scalars(select(DeletedDeviceRecord))} == {"A1", "never-seen"}


def test_deleted_samples_are_not_brought_back_by_a_retried_batch(session, rebuilds) -> None:
    client, _ = connected(session)
    client.post("/ingest/apple-health/batches", json=batch([sample("A1")]))
    client.post("/ingest/apple-health/batches", json=batch(deleted_ids=["A1"]))

    response = client.post("/ingest/apple-health/batches", json=batch([sample("A1")])).json()

    assert response["ignored"] == 1
    assert session.scalars(select(RawHealthRecord)).all() == []


def test_progress_tracks_each_type_and_rebuilds_scores_on_the_final_batch(session, rebuilds) -> None:
    client, user = connected(session)

    partial = client.post(
        "/ingest/apple-health/batches", json=batch([sample("A1")], anchor="anchor-1")
    ).json()
    final = client.post(
        "/ingest/apple-health/batches",
        json=batch([sample("A2", start="2026-11-10T08:00:00+00:00")], anchor="anchor-2", final=True),
    ).json()
    progress = client.get("/ingest/apple-health/progress").json()

    assert partial["progress"]["status"] == "running"
    assert partial["rebuild_queued"] is False
    assert final["progress"]["status"] == "succeeded"
    assert final["rebuild_queued"] is True
    assert rebuilds == [(user.id, date(2026, 11, 9), date(2026, 11, 10))]
    assert progress["connection"]["last_sync_at"] is not None
    assert progress["types"][0] | {"updated_at": None, "completed_at": None} == {
        "data_type": HEART_RATE,
        "phase": "current",
        "status": "succeeded",
        "range_start": "2026-11-09",
        "range_end": "2026-11-10",
        "anchor": "anchor-2",
        "samples_received": 2,
        "deletions_received": 0,
        "rebuild_pending": False,
        "completed_at": None,
        "updated_at": None,
    }


def test_a_failed_rebuild_queue_is_retried_on_the_next_final_batch(session, monkeypatch) -> None:
    attempts: list[tuple[date, date]] = []
    monkeypatch.setattr(
        "app.api.routes.device_uploads.enqueue_score_rebuild",
        lambda user_id, start, end: (attempts.append((start, end)), len(attempts) > 1)[1],
    )
    client, _ = connected(session)

    first = client.post("/ingest/apple-health/batches", json=batch([sample("A1")], final=True)).json()
    second = client.post(
        "/ingest/apple-health/batches",
        json=batch([sample("A2", start="2026-11-10T08:00:00+00:00")], final=True),
    ).json()

    assert first["rebuild_queued"] is False
    assert first["progress"]["rebuild_pending"] is True
    assert second["rebuild_queued"] is True
    assert attempts[-1] == (date(2026, 11, 9), date(2026, 11, 10))
    assert session.scalar(select(DeviceSyncProgress)).pending_rebuild_start is None


def test_a_new_historical_window_restarts_its_progress(session, rebuilds) -> None:
    client, _ = connected(session)
    recent = batch(phase="historical", range_start="2026-10-27", range_end="2026-11-09", final=True)
    client.post("/ingest/apple-health/batches", json=recent)

    wider = client.post(
        "/ingest/apple-health/batches",
        json=batch(phase="historical", range_start="2026-08-12", range_end="2026-11-09"),
    ).json()

    assert wider["progress"]["status"] == "running"
    assert wider["progress"]["completed_at"] is None
    assert wider["progress"]["range_start"] == "2026-08-12"
    assert session.scalar(select(HealthConnection)).last_sync_at is None


def test_google_sync_actions_refuse_device_connections(session, rebuilds) -> None:
    client, _ = connected(session)

    assert client.post("/sync/current").status_code == 409
    assert client.post("/sync/current/historical-backfill/retry").status_code == 409


def test_scheduled_google_polling_skips_device_connections(session, monkeypatch) -> None:
    connected(session)
    monkeypatch.setattr(sync_tasks, "cleanup_high_volume_storage", lambda session, today: {})

    result = sync_tasks.sync_all_connected_accounts()

    assert result["synced"] == [] and result["failed"] == {} and result["skipped"] == {}


def test_rebuild_task_rebuilds_summaries_for_the_range(session) -> None:
    _, user = signed_in(session)

    result = sync_tasks.rebuild_scores(user.id, "2026-11-09", "2026-11-10")

    assert result["status"] == "ok"
