"""Atomic per-item LWW registers and a durable, account-scoped change feed.

Completion is deliberately separate from response persistence, and streaks are not stored
here. Every accepted change to a statistical input invalidates future journal analyses in the
same transaction; notes and completion do not, because neither is an observation the analysis uses.
"""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import AwareDatetime, Field, StrictBool, field_validator, model_validator
from pydantic_core import PydanticCustomError
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.security import utcnow
from app.journal import JournalModel, ManualJournalResponse
from app.models import JournalCompletion, JournalEntry, JournalPreference, JournalState, User
from app.services.health_dates import get_or_create_profile, local_date_for_profile
from app.services.journal_catalogue import (
    AI_CONSENT_KEYS, CATALOGUE_V1, CATALOGUES, SENSITIVE_CATEGORIES, STATISTICAL_BEHAVIOURS,
    normalize_journal_response,
)


CLOCK_AHEAD = "clock_ahead"
PRIVATE_STATISTICAL_INPUTS = tuple(
    item for item in CATALOGUE_V1.behaviours
    if item.category_id in SENSITIVE_CATEGORIES and item.id in STATISTICAL_BEHAVIOURS
)
PRIVATE_INPUT_KEYS = frozenset(
    {f"opt_in:{item.category_id}" for item in PRIVATE_STATISTICAL_INPUTS}
    | {f"pin:{item.id}" for item in PRIVATE_STATISTICAL_INPUTS}
)


class JournalMutation(JournalModel):
    edited_at: AwareDatetime
    mutation_id: str

    @field_validator("mutation_id")
    @classmethod
    def canonical_id(cls, value: str) -> str:
        return str(UUID(value))

    @field_validator("edited_at")
    @classmethod
    def bounded_clock(cls, value: datetime) -> datetime:
        if value > utcnow() + timedelta(minutes=5):
            raise PydanticCustomError(CLOCK_AHEAD, "Edit timestamp is too far in the future")
        return value.astimezone(timezone.utc)


class EntryMutation(JournalMutation):
    journal_date: date
    behaviour_id: str = Field(min_length=1, max_length=80)
    deleted: StrictBool = False
    response: ManualJournalResponse | None = None

    @model_validator(mode="after")
    def matching_response(self) -> EntryMutation:
        if self.deleted:
            if self.response is not None:
                raise ValueError("Deletion cannot include an answer")
        elif (self.response is None or self.response.journal_date != self.journal_date
              or self.response.behaviour_id != self.behaviour_id):
            raise ValueError("Response must match its journal key")
        return self


class PreferenceMutation(JournalMutation):
    key: str = Field(min_length=1, max_length=100)
    value: StrictBool

    @field_validator("key")
    @classmethod
    def known_key(cls, value: str) -> str:
        keys = {f"pin:{item.id}" for item in CATALOGUE_V1.behaviours}
        keys |= {f"opt_in:{item}" for item in SENSITIVE_CATEGORIES} | AI_CONSENT_KEYS
        if value not in keys:
            raise ValueError("Unknown journal preference")
        return value


class CompletionMutation(JournalMutation):
    journal_date: date
    completed: StrictBool
    first_completed_at: AwareDatetime
    timezone: str = Field(min_length=1, max_length=80)

    @field_validator("first_completed_at")
    @classmethod
    def bounded_first_completion(cls, value: datetime) -> datetime:
        return cls.bounded_clock(value)

    @field_validator("timezone")
    @classmethod
    def known_timezone(cls, value: str) -> str:
        try:
            ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError) as exc:
            raise ValueError("Unknown timezone") from exc
        return value


class JournalSync(JournalModel):
    entries: list[EntryMutation] = Field(default_factory=list, max_length=100)
    preferences: list[PreferenceMutation] = Field(default_factory=list, max_length=100)
    completions: list[CompletionMutation] = Field(default_factory=list, max_length=100)


def aware(value: datetime) -> datetime:
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value


def wins(mutation: JournalMutation, row: JournalEntry | JournalPreference | JournalCompletion) -> bool:
    return (mutation.edited_at, mutation.mutation_id) > (aware(row.edited_at), row.mutation_id)


def entry_payload(row: JournalEntry) -> dict:
    return dict(kind="entry", journal_date=row.journal_date, behaviour_id=row.behaviour_id,
                edited_at=aware(row.edited_at), mutation_id=row.mutation_id, deleted=row.deleted,
                response=row.response, normalized=row.normalized, revision=row.revision)


def preference_payload(row: JournalPreference) -> dict:
    return dict(kind="preference", key=row.key, value=row.value, edited_at=aware(row.edited_at),
                mutation_id=row.mutation_id, revision=row.revision)


def completion_payload(row: JournalCompletion) -> dict:
    return dict(kind="completion", journal_date=row.journal_date, completed=row.completed,
                first_completed_at=aware(row.first_completed_at), timezone=row.timezone,
                edited_at=aware(row.edited_at), mutation_id=row.mutation_id, revision=row.revision)


def apply_completion(session: Session, state: JournalState, user_id: str, mutation: CompletionMutation) -> dict:
    """The current state is last-write-wins; the earliest completion always survives.

    Later edits can make a day incomplete without losing the moment it was first completed,
    which is what lets streak calculation keep days already earned.
    """
    row = session.scalar(select(JournalCompletion).where(
        JournalCompletion.user_id == user_id, JournalCompletion.journal_date == mutation.journal_date,
    ))
    newer = row is None or wins(mutation, row)
    earlier = row is not None and mutation.first_completed_at < aware(row.first_completed_at)
    if newer or earlier:
        state.revision += 1
        if row is None:
            row = JournalCompletion(user_id=user_id, journal_date=mutation.journal_date,
                                    first_completed_at=mutation.first_completed_at,
                                    timezone=mutation.timezone)
        if newer:
            row.completed = mutation.completed
            row.edited_at, row.mutation_id = mutation.edited_at, mutation.mutation_id
        if earlier:
            row.first_completed_at, row.timezone = mutation.first_completed_at, mutation.timezone
        row.revision = state.revision
        session.add(row)
        session.flush()
    return completion_payload(row)


def metadata(session: Session, user_id: str) -> dict:
    profile = get_or_create_profile(session, user_id)
    state = session.get(JournalState, user_id)
    return dict(timezone=profile.timezone, today=local_date_for_profile(profile),
                catalogue_version=max(CATALOGUES),
                goals=[goal for goal in [profile.fitness_goal, *(profile.secondary_goals or [])] if goal],
                analysis_revision=state.analysis_revision if state else 0)


class JournalAccountUnavailable(RuntimeError):
    pass


def lock_account(session: Session, user_id: str) -> None:
    account = session.execute(select(User.deletion_scheduled_for).where(
        User.id == user_id,
    ).with_for_update()).one_or_none()
    if account is None or account[0] is not None:
        raise JournalAccountUnavailable


def apply_sync(session: Session, user_id: str, payload: JournalSync) -> dict:
    lock_account(session, user_id)
    state = session.get(JournalState, user_id)
    if state is None:
        state = JournalState(user_id=user_id, revision=0, analysis_revision=0)
        session.add(state)
    acknowledgements = []
    inputs_toggled = False
    for mutation in sorted(payload.preferences, key=lambda item: (item.edited_at, item.mutation_id)):
        row = session.scalar(select(JournalPreference).where(
            JournalPreference.user_id == user_id, JournalPreference.key == mutation.key,
        ))
        if row is None or wins(mutation, row):
            state.revision += 1
            if row is None:
                row = JournalPreference(user_id=user_id, key=mutation.key)
            inputs_toggled = inputs_toggled or (
                row.value != mutation.value and mutation.key in PRIVATE_INPUT_KEYS
            )
            row.value = mutation.value
            row.edited_at, row.mutation_id = mutation.edited_at, mutation.mutation_id
            row.revision = state.revision
            session.add(row)
            session.flush()
        acknowledgements.append(preference_payload(row))
    opted_in = {row.key.removeprefix("opt_in:") for row in session.scalars(
        select(JournalPreference).where(JournalPreference.user_id == user_id,
                                        JournalPreference.value.is_(True))
    ) if row.key.startswith("opt_in:")}
    known = {item.id for item in CATALOGUE_V1.behaviours}
    changed_days = set()
    for mutation in sorted(payload.entries, key=lambda item: (item.edited_at, item.mutation_id)):
        if mutation.behaviour_id not in known:
            raise ValueError("unknown_behaviour")
        row = session.scalar(select(JournalEntry).where(
            JournalEntry.user_id == user_id, JournalEntry.journal_date == mutation.journal_date,
            JournalEntry.behaviour_id == mutation.behaviour_id,
        ))
        if row is None or wins(mutation, row):
            normalized = None if mutation.deleted else normalize_journal_response(
                mutation.response, opted_in_categories=opted_in,
            ).model_dump(mode="json")
            state.revision += 1
            if row is None:
                row = JournalEntry(user_id=user_id, journal_date=mutation.journal_date,
                                   behaviour_id=mutation.behaviour_id)
            row.edited_at, row.mutation_id = mutation.edited_at, mutation.mutation_id
            row.deleted = mutation.deleted
            row.response = mutation.response.model_dump(mode="json") if mutation.response else None
            row.normalized = normalized
            row.revision = state.revision
            session.add(row)
            if mutation.behaviour_id in STATISTICAL_BEHAVIOURS:
                changed_days.add(mutation.journal_date)
            session.flush()
        acknowledgements.append(entry_payload(row))
    for mutation in sorted(payload.completions, key=lambda item: (item.edited_at, item.mutation_id)):
        acknowledgements.append(apply_completion(session, state, user_id, mutation))
    if inputs_toggled and not changed_days:
        state.analysis_revision += 1
    if changed_days:
        state.analysis_revision += 1
        state.analysis_dirty_from = min(changed_days | (
            {state.analysis_dirty_from} if state.analysis_dirty_from else set()
        ))
    session.flush()
    result = dict(acknowledgements=acknowledgements, **metadata(session, user_id))
    session.commit()
    return result


def changes(session: Session, user_id: str, after: int, limit: int) -> dict:
    lock_account(session, user_id)
    entries = session.scalars(select(JournalEntry).where(
        JournalEntry.user_id == user_id, JournalEntry.revision > after,
    ).order_by(JournalEntry.revision).limit(limit + 1)).all()
    preferences = session.scalars(select(JournalPreference).where(
        JournalPreference.user_id == user_id, JournalPreference.revision > after,
    ).order_by(JournalPreference.revision).limit(limit + 1)).all()
    completions = session.scalars(select(JournalCompletion).where(
        JournalCompletion.user_id == user_id, JournalCompletion.revision > after,
    ).order_by(JournalCompletion.revision).limit(limit + 1)).all()
    rows = sorted([*(entry_payload(row) for row in entries),
                   *(preference_payload(row) for row in preferences),
                   *(completion_payload(row) for row in completions)], key=lambda row: row["revision"])
    page = rows[:limit]
    cursor = page[-1]["revision"] if page else after
    return dict(changes=page, cursor=cursor, has_more=len(rows) > limit,
                **metadata(session, user_id))
