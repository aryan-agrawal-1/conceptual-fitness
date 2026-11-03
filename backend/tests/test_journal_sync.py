from dataclasses import replace
from datetime import date, datetime, timedelta, timezone
import importlib.util
import json
from pathlib import Path
from uuid import uuid4
from zipfile import ZipFile

from alembic.migration import MigrationContext
from alembic.operations import Operations
from cryptography.fernet import Fernet
from fastapi.testclient import TestClient
import pytest
from sqlalchemy import select, text

from app.core.config import get_settings
from app.main import app
from app.models import JournalCompletion, JournalEntry, JournalPreference, JournalState, User, UserProfile
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


def test_changes_advertise_the_latest_catalogue_version(session, auth_headers):
    _, headers = account(session, auth_headers)
    page = TestClient(app).get("/journal/changes", headers=headers).json()
    assert page["catalogue_version"] == 1


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


def completion(day="2026-10-24", *, completed=True, first="2026-10-25T08:00:00Z",
               stamp="2026-10-25T08:00:00Z", mutation_id=None, timezone_name="Europe/London"):
    return dict(journal_date=day, completed=completed, first_completed_at=first, timezone=timezone_name,
                edited_at=stamp, mutation_id=mutation_id or str(uuid4()))


def test_completion_retries_are_idempotent_and_do_not_invalidate_analysis(session, auth_headers):
    user, headers = account(session, auth_headers)
    client = TestClient(app)
    change = completion()
    first = client.post("/journal/sync", headers=headers, json={"completions": [change]})
    assert first.status_code == 200
    saved = first.json()["acknowledgements"][0]
    assert saved["kind"] == "completion"
    assert saved["journal_date"] == "2026-10-24"
    assert saved["completed"] is True
    assert saved["timezone"] == "Europe/London"
    assert client.post("/journal/sync", headers=headers, json={"completions": [change]}).json() == first.json()
    state = session.get(JournalState, user.id)
    assert state.revision == 1
    assert state.analysis_revision == 0
    assert state.analysis_dirty_from is None
    feed = client.get("/journal/changes", headers=headers).json()["changes"]
    assert [row["kind"] for row in feed] == ["completion"]


def test_withdrawn_completion_keeps_the_first_completion_in_any_delivery_order(session, auth_headers):
    _, headers = account(session, auth_headers)
    client = TestClient(app)
    earned = completion(first="2026-10-25T08:00:00Z", stamp="2026-10-25T08:00:00Z")
    withdrawn = completion(completed=False, first="2026-10-25T08:00:00Z", stamp="2026-10-25T09:00:00Z")
    again = completion(first="2026-10-26T07:00:00Z", stamp="2026-10-26T07:00:00Z",
                       timezone_name="Asia/Tokyo")
    results = []
    for order in ((earned, withdrawn, again), (again, withdrawn, earned)):
        for change in order:
            change = {**change, "journal_date": "2026-10-24" if order[0] is earned else "2026-10-23"}
            result = client.post("/journal/sync", headers=headers, json={"completions": [change]})
            assert result.status_code == 200
        results.append(result.json()["acknowledgements"][0])
    for result in results:
        assert result["completed"] is True
        assert result["first_completed_at"].startswith("2026-10-25T08:00:00")
        assert result["timezone"] == "Europe/London"
    assert results[0]["mutation_id"] == results[1]["mutation_id"] == again["mutation_id"]


def test_late_earlier_completion_is_visible_to_other_devices(session, auth_headers):
    _, headers = account(session, auth_headers)
    client = TestClient(app)
    client.post("/journal/sync", headers=headers, json={"completions": [
        completion(first="2026-10-26T07:00:00Z", stamp="2026-10-26T07:00:00Z")]})
    cursor = client.get("/journal/changes", headers=headers).json()["cursor"]
    # This offline device completed first but edited earlier, so only the first completion changes.
    client.post("/journal/sync", headers=headers, json={"completions": [
        completion(completed=False, first="2026-10-25T08:00:00Z", stamp="2026-10-25T09:00:00Z")]})
    change = client.get(f"/journal/changes?after={cursor}", headers=headers).json()["changes"][0]
    assert change["completed"] is True
    assert change["first_completed_at"].startswith("2026-10-25T08:00:00")


def test_completion_validation_is_payload_free_and_future_stamps_are_rejected(session, auth_headers, caplog):
    _, headers = account(session, auth_headers)
    client = TestClient(app)
    invalid = client.post("/journal/sync", headers=headers, json={"completions": [
        completion(timezone_name="Not/AZone")]})
    assert invalid.status_code == 422
    assert "Not/AZone" not in invalid.text
    future = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
    ahead = client.post("/journal/sync", headers=headers, json={"completions": [completion(first=future)]})
    assert ahead.status_code == 422
    assert ahead.json()["detail"]["code"] == "clock_ahead"
    assert "Not/AZone" not in caplog.text


def test_completion_pages_export_and_cascade(session, auth_headers):
    owner, headers = account(session, auth_headers)
    client = TestClient(app)
    changes = [completion(day=f"2026-10-{day}") for day in (21, 22, 23)]
    assert client.post("/journal/sync", headers=headers, json={"completions": changes}).status_code == 200
    cursor, seen = 0, []
    while True:
        page = client.get(f"/journal/changes?after={cursor}&limit=2", headers=headers).json()
        seen.extend(page["changes"])
        cursor = page["cursor"]
        if not page["has_more"]:
            break
    assert sorted(row["journal_date"] for row in seen) == ["2026-10-21", "2026-10-22", "2026-10-23"]
    with ZipFile(build_account_export(
        session, user_id=owner.id, categories={"journal"}, local_insights=[],
        local_journal={"completions": [changes[0]]},
    )) as archive:
        tables = json.loads(archive.read("journal.json"))["tables"]
        assert len(tables["journal_completions"]) == 3
        assert tables["client_journal_completions"][0]["journal_date"] == "2026-10-21"
    session.delete(owner)
    session.commit()
    assert session.scalar(select(JournalCompletion)) is None


NOTE_TEXT = "Argument about the paperwork, slept badly"


def note_edit(body=NOTE_TEXT, **kwargs):
    return edit("daily_note", value={"type": "text", "value": body}, **kwargs)


def stored_columns(session):
    return [" ".join(str(column) for column in row) for row in session.execute(
        text("SELECT response, normalized FROM journal_entries ORDER BY behaviour_id")
    )]


def use_journal_key(monkeypatch, key):
    settings = replace(get_settings(), journal_encryption_key=key)
    monkeypatch.setattr("app.db.sealed_json.get_settings", lambda: settings)


def test_note_text_is_encrypted_at_rest_and_readable_through_every_route(session, auth_headers):
    owner, headers = account(session, auth_headers)
    client = TestClient(app)
    synced = client.post("/journal/sync", headers=headers, json={
        "entries": [note_edit(), edit(value={"type": "rating", "value": 4})],
        "preferences": [pref("opt_in:reflection")],
    })
    assert synced.status_code == 200
    note_ack = next(row for row in synced.json()["acknowledgements"] if row.get("behaviour_id") == "daily_note")
    assert note_ack["response"]["answer"] == {"type": "text", "value": NOTE_TEXT}

    session.expire_all()
    note_columns, mood_columns = stored_columns(session)
    assert NOTE_TEXT not in note_columns
    assert "ciphertext" in note_columns
    assert "ciphertext" not in mood_columns
    assert '"rating"' in mood_columns

    feed = client.get("/journal/changes", headers=headers).json()["changes"]
    note = next(row for row in feed if row.get("behaviour_id") == "daily_note")
    assert note["response"]["answer"]["value"] == NOTE_TEXT
    assert note["normalized"]["canonical_answer"]["value"] == NOTE_TEXT
    entries = client.get("/journal/entries?start=2026-10-24&end=2026-10-24", headers=headers).json()
    assert NOTE_TEXT in json.dumps(entries)
    with ZipFile(build_account_export(session, user_id=owner.id, categories={"journal"}, local_insights=[])) as archive:
        exported = json.loads(archive.read("journal.json"))["tables"]["journal_entries"]
    assert NOTE_TEXT in json.dumps(exported)
    assert "ciphertext" not in json.dumps(exported)

    client.post("/journal/sync", headers=headers, json={"entries": [
        edit("daily_note", deleted=True, stamp="2026-10-26T12:00:00Z"),
    ]})
    session.expire_all()
    assert "ciphertext" not in stored_columns(session)[0]
    session.delete(owner)
    session.commit()
    assert session.scalar(select(JournalEntry)) is None


def test_unreadable_note_text_is_retryable_and_payload_free(session, auth_headers, monkeypatch, caplog):
    _, headers = account(session, auth_headers)
    client = TestClient(app)
    assert client.post("/journal/sync", headers=headers, json={
        "entries": [note_edit()], "preferences": [pref("opt_in:reflection")],
    }).status_code == 200
    use_journal_key(monkeypatch, Fernet.generate_key().decode())
    session.expire_all()
    response = client.get("/journal/changes", headers=headers)
    assert response.status_code == 503
    assert NOTE_TEXT not in response.text
    assert "reason=note_text_unavailable" in caplog.text
    assert NOTE_TEXT not in caplog.text


def test_a_missing_key_queues_notes_without_blocking_typed_answers(session, auth_headers, monkeypatch, caplog):
    _, headers = account(session, auth_headers)
    client = TestClient(app)
    client.post("/journal/sync", headers=headers, json={"preferences": [pref("opt_in:reflection")]})
    use_journal_key(monkeypatch, "")
    assert client.post("/journal/sync", headers=headers, json={"entries": [note_edit()]}).status_code == 503
    assert NOTE_TEXT not in caplog.text
    session.rollback()
    assert session.scalar(select(JournalEntry)) is None
    assert client.post("/journal/sync", headers=headers, json={
        "entries": [edit(value={"type": "rating", "value": 4})],
    }).status_code == 200


def test_older_keys_keep_opening_notes_after_rotation(session, auth_headers, monkeypatch):
    _, headers = account(session, auth_headers)
    client = TestClient(app)
    client.post("/journal/sync", headers=headers, json={
        "entries": [note_edit()], "preferences": [pref("opt_in:reflection")],
    })
    old_key = get_settings().journal_encryption_key
    use_journal_key(monkeypatch, f"{Fernet.generate_key().decode()},{old_key}")
    session.expire_all()
    note = client.get("/journal/changes", headers=headers).json()["changes"]
    assert NOTE_TEXT in json.dumps(note)


def test_migration_seals_existing_notes_and_can_reverse(session):
    migration_path = Path(__file__).parents[1] / "migrations/versions/0026_seal_journal_notes.py"
    spec = importlib.util.spec_from_file_location("seal_journal_notes", migration_path)
    migration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)
    user = User()
    session.add(user)
    session.flush()
    value = json.dumps({"answer": {"type": "text", "value": NOTE_TEXT}, "journal_date": "2026-10-24"})
    insert = text(
        "INSERT INTO journal_entries (id, user_id, journal_date, behaviour_id, edited_at, mutation_id,"
        " deleted, response, normalized, revision) VALUES (:id, :user_id, '2026-10-24', :behaviour,"
        " '2026-10-25 12:00:00', :mutation, :deleted, :response, :response, 1)"
    )
    connection = session.connection()
    connection.execute(insert, dict(id=str(uuid4()), user_id=user.id, behaviour="daily_note",
                                    mutation=str(uuid4()), deleted=False, response=value))
    connection.execute(insert, dict(id=str(uuid4()), user_id=user.id, behaviour="energy",
                                    mutation=str(uuid4()), deleted=False,
                                    response=json.dumps({"answer": {"type": "rating", "value": 4}})))
    connection.execute(text(
        "INSERT INTO journal_entries (id, user_id, journal_date, behaviour_id, edited_at, mutation_id, deleted,"
        " revision) VALUES (:id, :user_id, '2026-10-23', 'daily_note', '2026-10-25 12:00:00', :mutation, :deleted, 2)"
    ), dict(id=str(uuid4()), user_id=user.id, mutation=str(uuid4()), deleted=True))
    with Operations.context(MigrationContext.configure(connection)):
        migration.upgrade()
        tombstone = connection.execute(text(
            "SELECT count(*) FROM journal_entries WHERE deleted AND response IS NULL"
        )).scalar_one()
        assert tombstone == 1
        sealed, energy = connection.execute(text(
            "SELECT response FROM journal_entries WHERE NOT deleted ORDER BY behaviour_id"
        )).scalars().all()
        assert NOTE_TEXT not in str(sealed)
        assert "ciphertext" in str(sealed)
        assert "ciphertext" not in str(energy)
        migration.upgrade()
        migration.downgrade()
    restored = connection.execute(text(
        "SELECT response FROM journal_entries WHERE behaviour_id = 'daily_note' AND NOT deleted"
    )).scalar_one()
    assert NOTE_TEXT in str(restored)
    assert "ciphertext" not in str(restored)
    session.rollback()


def test_note_edits_do_not_invalidate_analysis_but_inputs_still_do(session, auth_headers):
    user, headers = account(session, auth_headers)
    client = TestClient(app)
    client.post("/journal/sync", headers=headers, json={
        "entries": [note_edit()], "preferences": [pref("opt_in:reflection")],
    })
    client.post("/journal/sync", headers=headers, json={"entries": [
        edit("daily_note", deleted=True, stamp="2026-10-26T12:00:00Z"),
    ]})
    state = session.get(JournalState, user.id)
    assert state.analysis_revision == 0
    assert state.analysis_dirty_from is None
    client.post("/journal/sync", headers=headers, json={"entries": [
        edit(value={"type": "rating", "value": 4}, day="2026-10-20"),
        note_edit(day="2026-10-10", stamp="2026-10-26T13:00:00Z"),
    ]})
    session.expire_all()
    state = session.get(JournalState, user.id)
    assert state.analysis_revision == 1
    assert state.analysis_dirty_from == date(2026, 10, 20)
