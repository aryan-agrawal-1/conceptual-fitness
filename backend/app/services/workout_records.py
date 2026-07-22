from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.models import (
    GoogleAccount,
    RawHealthRecord,
    Workout,
    WorkoutExercise,
    WorkoutSource,
)


HIGH_MATCH_SCORE = 0.82
MEDIUM_MATCH_SCORE = 0.58


def workout_match_score(
    *,
    left_start: datetime,
    left_end: datetime,
    left_type: str | None,
    right_start: datetime,
    right_end: datetime,
    right_type: str | None,
) -> float:
    left_start = _utc_naive(left_start)
    left_end = _utc_naive(left_end)
    right_start = _utc_naive(right_start)
    right_end = _utc_naive(right_end)
    left_seconds = max(1.0, (left_end - left_start).total_seconds())
    right_seconds = max(1.0, (right_end - right_start).total_seconds())
    overlap = max(
        0.0,
        (min(left_end, right_end) - max(left_start, right_start)).total_seconds(),
    )
    overlap_ratio = overlap / min(left_seconds, right_seconds)
    start_delta = abs((left_start - right_start).total_seconds())
    start_score = max(0.0, 1.0 - start_delta / (30 * 60))
    duration_score = min(left_seconds, right_seconds) / max(left_seconds, right_seconds)
    type_score = _type_similarity(left_type, right_type)
    return round(
        overlap_ratio * 0.5 + start_score * 0.2 + duration_score * 0.15 + type_score * 0.15,
        4,
    )


def find_workout_matches(
    session: Session,
    *,
    user_id: str,
    start_time: datetime,
    end_time: datetime,
    workout_type: str | None,
    exclude_id: str | None = None,
) -> list[tuple[Workout, float]]:
    statement = select(Workout).where(
        Workout.user_id == user_id,
        Workout.deleted_at.is_(None),
        Workout.start_time < end_time,
        Workout.end_time > start_time,
    )
    if exclude_id is not None:
        statement = statement.where(Workout.id != exclude_id)
    matches = []
    for candidate in session.scalars(statement).all():
        score = workout_match_score(
            left_start=start_time,
            left_end=end_time,
            left_type=workout_type,
            right_start=candidate.start_time,
            right_end=candidate.end_time,
            right_type=candidate.workout_type,
        )
        if score >= MEDIUM_MATCH_SCORE:
            matches.append((candidate, score))
    return sorted(matches, key=lambda item: item[1], reverse=True)


def normalize_provider_workout(
    session: Session,
    *,
    account: GoogleAccount,
    raw_record: RawHealthRecord,
    payload: dict[str, Any],
    start_time: datetime,
    end_time: datetime,
) -> Workout:
    workout_type = payload.get("exerciseType") or payload.get("activityType") or payload.get("type")
    source = session.scalar(
        select(WorkoutSource).where(WorkoutSource.raw_record_id == raw_record.id)
    )
    if source is not None:
        workout = session.get(Workout, source.workout_id)
        if workout is not None:
            _update_source(source, raw_record, payload, start_time, end_time)
            if not workout.is_user_edited:
                _update_provider_fields(workout, raw_record, payload, start_time, end_time, workout_type)
            session.add_all([source, workout])
            return workout

    legacy_workout = session.scalar(
        select(Workout).where(Workout.raw_record_id == raw_record.id)
    )
    if legacy_workout is not None:
        _update_provider_fields(
            legacy_workout, raw_record, payload, start_time, end_time, workout_type
        )
        session.add(legacy_workout)
        session.flush()
        session.add(
            WorkoutSource(
                user_id=account.user_id,
                workout_id=legacy_workout.id,
                raw_record_id=raw_record.id,
                provider="google_health",
                source_record_id=raw_record.source_record_id,
                source_platform=raw_record.source_platform,
                source_device=raw_record.source_device,
                start_time=start_time,
                end_time=end_time,
                payload=raw_record.raw_json,
            )
        )
        return legacy_workout

    matches = find_workout_matches(
        session,
        user_id=account.user_id,
        start_time=start_time,
        end_time=end_time,
        workout_type=workout_type,
    )
    manual_match = next(
        (
            candidate
            for candidate, score in matches
            if score >= HIGH_MATCH_SCORE and candidate.origin in {"manual", "mixed"}
        ),
        None,
    )
    if manual_match is None:
        manual_match = Workout(
            user_id=account.user_id,
            raw_record_id=raw_record.id,
            workout_type=workout_type,
            start_time=start_time,
            end_time=end_time,
            civil_date=raw_record.civil_date or start_time.date(),
            duration_seconds=int((end_time - start_time).total_seconds()),
            raw_summary=payload,
            status="completed",
            origin="wearable",
            completed_at=end_time,
            awaiting_wearable=False,
        )
        session.add(manual_match)
        session.flush()
    else:
        manual_match.origin = "mixed"
        manual_match.awaiting_wearable = False
        if manual_match.raw_record_id is None:
            manual_match.raw_record_id = raw_record.id
        session.add(manual_match)

    source = WorkoutSource(
        user_id=account.user_id,
        workout_id=manual_match.id,
        raw_record_id=raw_record.id,
        provider="google_health",
        source_record_id=raw_record.source_record_id,
        source_platform=raw_record.source_platform,
        source_device=raw_record.source_device,
        start_time=start_time,
        end_time=end_time,
        payload=raw_record.raw_json,
    )
    session.add(source)
    return manual_match


def remove_provider_workouts(
    session: Session,
    *,
    raw_record_ids: list[str],
) -> None:
    if not raw_record_ids:
        return
    sources = session.scalars(
        select(WorkoutSource).where(WorkoutSource.raw_record_id.in_(raw_record_ids))
    ).all()
    sourced_raw_ids = {source.raw_record_id for source in sources}
    for source in sources:
        workout = session.get(Workout, source.workout_id)
        if workout is None:
            continue
        source_count = session.scalar(
            select(func.count()).select_from(WorkoutSource).where(
                WorkoutSource.workout_id == workout.id
            )
        ) or 0
        has_user_exercises = session.scalar(
            select(WorkoutExercise.id).where(WorkoutExercise.workout_id == workout.id).limit(1)
        ) is not None
        keep_canonical = workout.is_user_edited or has_user_exercises or source_count > 1
        if keep_canonical:
            session.delete(source)
            if workout.raw_record_id == source.raw_record_id:
                workout.raw_record_id = None
            if source_count <= 1:
                workout.origin = "manual"
            session.add(workout)
        else:
            session.delete(workout)
    legacy_workouts = session.scalars(
        select(Workout).where(
            Workout.raw_record_id.in_(raw_record_ids),
            Workout.raw_record_id.not_in(sourced_raw_ids),
        )
    ).all()
    for workout in legacy_workouts:
        has_user_exercises = session.scalar(
            select(WorkoutExercise.id).where(WorkoutExercise.workout_id == workout.id).limit(1)
        ) is not None
        if workout.is_user_edited or has_user_exercises:
            workout.raw_record_id = None
            workout.origin = "manual"
            session.add(workout)
        else:
            session.delete(workout)
    session.flush()


def attach_source_to_workout(
    session: Session,
    *,
    source_workout: Workout,
    target_workout: Workout,
) -> None:
    sources = session.scalars(
        select(WorkoutSource).where(WorkoutSource.workout_id == source_workout.id)
    ).all()
    for source in sources:
        source.workout_id = target_workout.id
        session.add(source)
    if target_workout.raw_record_id is None and source_workout.raw_record_id is not None:
        target_workout.raw_record_id = source_workout.raw_record_id
    target_workout.origin = "mixed" if target_workout.is_user_edited else source_workout.origin
    target_workout.awaiting_wearable = False
    session.add(target_workout)


def _update_provider_fields(
    workout: Workout,
    raw_record: RawHealthRecord,
    payload: dict[str, Any],
    start_time: datetime,
    end_time: datetime,
    workout_type: str | None,
) -> None:
    workout.raw_record_id = raw_record.id
    workout.workout_type = workout_type
    workout.start_time = start_time
    workout.end_time = end_time
    workout.civil_date = raw_record.civil_date or start_time.date()
    workout.duration_seconds = int((end_time - start_time).total_seconds())
    workout.raw_summary = payload
    workout.completed_at = end_time
    workout.awaiting_wearable = False


def _update_source(
    source: WorkoutSource,
    raw_record: RawHealthRecord,
    payload: dict[str, Any],
    start_time: datetime,
    end_time: datetime,
) -> None:
    source.source_record_id = raw_record.source_record_id
    source.source_platform = raw_record.source_platform
    source.source_device = raw_record.source_device
    source.start_time = start_time
    source.end_time = end_time
    source.payload = payload


def _type_similarity(left: str | None, right: str | None) -> float:
    left_value = (left or "").lower().replace("_", " ")
    right_value = (right or "").lower().replace("_", " ")
    if not left_value or not right_value:
        return 0.5
    if left_value == right_value:
        return 1.0
    strength_terms = {"strength", "weight", "resistance", "gym", "bodybuilding"}
    cardio_groups = (
        {"run", "running", "jogging", "treadmill"},
        {"cycle", "cycling", "bike", "biking"},
        {"walk", "walking", "hiking"},
        {"swim", "swimming"},
        {"row", "rowing"},
    )
    if any(term in left_value for term in strength_terms) and any(
        term in right_value for term in strength_terms
    ):
        return 0.9
    for group in cardio_groups:
        if any(term in left_value for term in group) and any(term in right_value for term in group):
            return 0.9
    return 0.0


def _utc_naive(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value
    return value.astimezone(UTC).replace(tzinfo=None)
