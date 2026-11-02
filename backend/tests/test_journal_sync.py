from datetime import date, datetime, timedelta, timezone
import json
from uuid import uuid4
from zipfile import ZipFile

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.main import app
from app.models import JournalEntry, JournalPreference, JournalState, User, UserProfile
from app.services.account_export import build_account_export


def edit(behaviour="mood", *, value=None, day="2026-10-24", stamp="2026-10-25T12:00:00Z",
         mutation_id=None, deleted=False, missing_reason=None):
    response = dict(journal_date=day, timezone="Europe/London", recorded_at=stamp,
                    behaviour_id=behaviour, answer=value)
    if missing_reason:
        response["missing_reason"] = missing_reason
    return dict(journal_date=day, behaviour_id=behaviour, edited_at=stamp,
                mutation_id=mutation_id or str(uuid4()), deleted=deleted,
                response=None if deleted else response)


def pref(key, value=True, *, stamp="2026-10-25T12:00:00Z"):
    return dict(key=key, value=value, edited_at=stamp, mutation_id=str(uuid4()))


def account(session, auth_headers):
    user = User(email="journal-owner@example.com")
    session.add(user)
    session.flush()
    session.add(UserProfile(user_id=user.id, timezone="Pacific/Auckland", fitness_goal="Better sleep"))
    session.commit()
    return user, auth_headers(user)


def test_offline_retry_crud_tombstones_and_historical_invalidation(session, auth_headers):
    user, headers = account(session, auth_headers)
    client = TestClient(app)
    assert client.get("/journal/changes").status_code == 401
    assert client.get("/journal/changes", headers=headers).json()["changes"] == []
    change = edit(value={"type": "rating", "value": 4})
    first = client.post("/journal/sync", headers=headers, json={"entries": [change]})
    assert first.status_code == 200
    assert first.json()["timezone"] == "Pacific/Auckland"
    assert first.json()["goals"] == ["Better sleep"]
    saved = first.json()["acknowledgements"][0]["response"]
    assert saved["timezone"] == "Europe/London"
    assert saved["journal_date"] == change["journal_date"]
    assert saved["recorded_at"] == change["response"]["recorded_at"]
    assert client.post("/journal/sync", headers=headers, json={"entries": [change]}).json() == first.json()
    state = session.get(JournalState, user.id)
    assert state.revision == state.analysis_revision == 1
    assert state.analysis_dirty_from == date(2026, 10, 24)
    update = edit(value={"type": "rating", "value": 2}, stamp="2026-10-25T13:00:00Z")
    assert client.post("/journal/sync", headers=headers, json={"entries": [update]}).status_code == 200
    delete = edit(deleted=True, stamp="2026-10-25T14:00:00Z")
    assert client.post("/journal/sync", headers=headers, json={"entries": [delete]}).status_code == 200
    stale = client.post("/journal/sync", headers=headers, json={"entries": [change]})
    assert stale.json()["acknowledgements"][0]["deleted"] is True
    rows = client.get("/journal/entries?start=2020-01-01&end=2020-12-31", headers=headers)
    assert rows.json() == []
    feed = client.get("/journal/changes", headers=headers).json()
    assert feed["changes"][0]["response"] is None
    assert feed["analysis_revision"] == 3
    restore = edit(value={"type": "rating", "value": 5}, stamp="2026-10-25T15:00:00Z")
    assert client.post("/journal/sync", headers=headers, json={"entries": [restore]}).status_code == 200
    rows = client.get("/journal/entries?start=2026-10-24&end=2026-10-24", headers=headers).json()
    assert rows[0]["response"]["answer"]["value"] == 5
    session.expire_all()
    assert session.get(JournalState, user.id).analysis_dirty_from == date(2026, 10, 24)


def test_concurrent_edits_converge_independent_of_delivery_order(session, auth_headers):
    user, headers = account(session, auth_headers)
    client = TestClient(app)
    low = edit(value={"type": "rating", "value": 1}, mutation_id="00000000-0000-0000-0000-000000000001")
    high = edit(value={"type": "rating", "value": 5}, mutation_id="00000000-0000-0000-0000-000000000002")
    for pair in ((low, high), (high, low)):
        for mutation in pair:
            assert client.post("/journal/sync", headers=headers, json={"entries": [mutation]}).status_code == 200
        row = session.scalar(select(JournalEntry).where(JournalEntry.user_id == user.id))
        session.refresh(row)
        assert row.response["answer"]["value"] == 5
    independent = edit("energy", value={"type": "rating", "value": 3})
    assert client.post("/journal/sync", headers=headers, json={"entries": [independent]}).status_code == 200
    assert len(client.get("/journal/changes", headers=headers).json()["changes"]) == 2


def test_sensitive_consent_normalization_missingness_and_no_provider_impersonation(session, auth_headers, caplog):
    user, headers = account(session, auth_headers)
    client = TestClient(app)
    caffeine = edit("caffeine", value={"type": "boolean", "value": True})
    caffeine["response"]["details"] = {"amount": {"type": "quantity", "value": 0.2, "unit": "g"}}
    assert client.post("/journal/sync", headers=headers, json={"entries": [caffeine]}).status_code == 422
    result = client.post("/journal/sync", headers=headers, json={
        "preferences": [pref("opt_in:substances")], "entries": [caffeine],
    })
    assert result.status_code == 200
    saved = result.json()["acknowledgements"][-1]
    assert saved["response"]["details"]["amount"]["unit"] == "g"
    assert saved["normalized"]["canonical_details"]["amount"] == {"type": "quantity", "value": 200, "unit": "mg"}
    missing = edit(value=None, missing_reason="skipped")
    assert client.post("/journal/sync", headers=headers, json={"entries": [missing]}).status_code == 200
    automatic = edit("travel", value={"type": "boolean", "value": False})
    automatic["response"]["kind"] = "automatic"
    rejected = client.post("/journal/sync", headers=headers, json={"entries": [automatic]})
    assert rejected.status_code == 422
    assert "automatic" not in rejected.text
    assert "journal-owner" not in caplog.text
    assert "caffeine" not in caplog.text
    assert "0.2" not in caplog.text
    # Revoke access: existing values remain user-owned, but new sensitive writes require consent.
    assert client.post("/journal/sync", headers=headers, json={"preferences": [
        pref("opt_in:substances", False, stamp="2026-10-25T13:00:00Z"),
    ]}).status_code == 200
    caffeine["edited_at"] = "2026-10-25T14:00:00Z"
    assert client.post("/journal/sync", headers=headers, json={"entries": [caffeine]}).status_code == 422
    assert client.post("/journal/sync", headers=headers, json={"entries": [
        edit("caffeine", deleted=True, stamp="2026-10-25T15:00:00Z"),
    ]}).status_code == 200


def test_changes_pagination_isolation_atomic_validation_export_and_cascade(session, auth_headers):
    owner, headers = account(session, auth_headers)
    other = User()
    session.add(other)
    session.commit()
    other_headers = auth_headers(other)
    client = TestClient(app)
    entries = [edit(item, value={"type": "boolean", "value": False})
               for item in ("travel", "worked_late", "night_shift")]
    result = client.post("/journal/sync", headers=headers, json={
        "entries": entries, "preferences": [pref("pin:travel"), pref("pin:worked_late")],
    })
    assert result.status_code == 200
    cursor, changes = 0, []
    while True:
        page = client.get(f"/journal/changes?after={cursor}&limit=2", headers=headers).json()
        changes.extend(page["changes"])
        cursor = page["cursor"]
        if not page["has_more"]:
            break
    assert len(changes) == 5
    assert len({row["revision"] for row in changes}) == 5
    assert client.get("/journal/changes", headers=other_headers).json()["changes"] == []
    invalid = edit(value={"type": "rating", "value": 8})
    assert client.post("/journal/sync", headers=headers, json={
        "entries": [invalid], "preferences": [pref("pin:energy")],
    }).status_code == 422
    assert session.scalar(select(JournalPreference).where(JournalPreference.key == "pin:energy")) is None
    with ZipFile(build_account_export(session, user_id=owner.id, categories={"journal"}, local_insights=[])) as archive:
        data = json.loads(archive.read("journal.json"))["tables"]
        assert len(data["journal_entries"]) == 3
        assert len(data["journal_preferences"]) == 2
        assert data["journal_states"][0]["analysis_revision"] == 1
    with ZipFile(build_account_export(
        session, user_id=owner.id, categories={"journal"}, local_insights=[],
        local_journal={"entries": [entries[0]], "preferences": []},
    )) as archive:
        local = json.loads(archive.read("journal.json"))["tables"]["client_journal_entries"]
        assert local[0]["response"]["answer"]["value"] is False
    session.delete(owner)
    session.commit()
    for model in (JournalEntry, JournalPreference, JournalState):
        assert session.scalar(select(model)) is None


def test_clock_ahead_is_actionable_retryable_and_payload_free(session, auth_headers, caplog):
    user, headers = account(session, auth_headers)
    client = TestClient(app)
    ahead = (datetime.now(timezone.utc) + timedelta(minutes=10)).isoformat()
    rejected = client.post("/journal/sync", headers=headers, json={"entries": [
        edit(value={"type": "rating", "value": 3}, stamp=ahead),
    ]})
    assert rejected.status_code == 422
    assert rejected.json()["detail"]["code"] == "clock_ahead"
    assert "clock" in rejected.json()["detail"]["message"]
    assert ahead not in rejected.text + caplog.text
    assert "reason=clock_ahead" in caplog.text
    assert session.scalar(select(JournalEntry).where(JournalEntry.user_id == user.id)) is None

    # Within the allowance the same edit is accepted, so correcting the clock clears the queue.
    close = (datetime.now(timezone.utc) + timedelta(minutes=4)).isoformat()
    accepted = client.post("/journal/sync", headers=headers, json={"entries": [
        edit(value={"type": "rating", "value": 3}, stamp=close),
    ]})
    assert accepted.status_code == 200


def test_other_invalid_requests_keep_the_generic_response(session, auth_headers):
    _, headers = account(session, auth_headers)
    rejected = TestClient(app).post("/journal/sync", headers=headers, json={"entries": [{"bad": 1}]})
    assert rejected.status_code == 422
    assert rejected.json()["detail"] == "Invalid journal request"


def test_sync_failure_is_retryable_and_payload_free(session, auth_headers, monkeypatch, caplog):
    user, headers = account(session, auth_headers)
    from app.api.routes import journal

    def fail(*args):
        raise RuntimeError("private health payload must not leak")

    monkeypatch.setattr(journal, "apply_sync", fail)
    response = TestClient(app).post("/journal/sync", headers=headers, json={"entries": []})
    assert response.status_code == 503
    assert "private health" not in caplog.text + response.text
    assert "reason=storage_failure" in caplog.text


def test_inflight_sync_cannot_write_after_deletion_scheduling(session, auth_headers):
    from app.core.security import utcnow
    from app.services.journal_storage import JournalAccountUnavailable, JournalSync, apply_sync
    import pytest

    user, headers = account(session, auth_headers)
    user.deletion_scheduled_for = utcnow()
    session.commit()
    with pytest.raises(JournalAccountUnavailable):
        apply_sync(session, user.id, JournalSync.model_validate({
            "entries": [edit(value={"type": "rating", "value": 3})],
        }))
    assert session.scalar(select(JournalEntry)) is None
