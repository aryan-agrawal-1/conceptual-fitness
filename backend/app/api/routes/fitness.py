from __future__ import annotations

from datetime import UTC, date, datetime
from typing import Any, Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, HTTPException, Query, status
from pydantic import BaseModel, Field, model_validator
from sqlalchemy import delete, func, or_, select

from app.api.deps import CurrentUser, DbSession
from app.core.security import utcnow
from app.models import (
    ExerciseCatalogItem,
    ExerciseFavorite,
    RoutineExercise,
    UserProfile,
    Workout,
    WorkoutExercise,
    WorkoutMatchRejection,
    WorkoutRoutine,
    WorkoutSet,
    WorkoutSource,
)
from app.services.workout_records import (
    HIGH_MATCH_SCORE,
    attach_source_to_workout,
    find_workout_matches,
)


router = APIRouter(prefix="/fitness", tags=["fitness"])


MeasurementSchema = Literal[
    "reps_load",
    "bodyweight_reps",
    "assisted_reps",
    "duration",
    "duration_load",
    "carry",
    "cardio",
]


class SetWrite(BaseModel):
    set_type: Literal["working", "warmup", "drop"] = "working"
    status: Literal["planned", "completed"] = "planned"
    drop_group_id: str | None = None
    reps: int | None = Field(default=None, ge=0, le=10000)
    load_value: float | None = Field(default=None, ge=0, le=100000)
    load_unit: Literal["kg", "lb"] | None = None
    load_per_implement: float | None = Field(default=None, ge=0, le=100000)
    implement_count: int | None = Field(default=None, ge=1, le=20)
    side_count: int | None = Field(default=None, ge=1, le=2)
    duration_seconds: int | None = Field(default=None, ge=0, le=604800)
    distance_meters: float | None = Field(default=None, ge=0, le=1000000)
    assistance_kg: float | None = Field(default=None, ge=0, le=10000)
    added_load_kg: float | None = Field(default=None, ge=0, le=10000)
    rir: float | None = Field(default=None, ge=0, le=20)
    notes: str | None = Field(default=None, max_length=1000)
    completed_at: datetime | None = None


class WorkoutExerciseWrite(BaseModel):
    exercise_id: str | None = None
    name: str = Field(..., min_length=1, max_length=180)
    measurement_schema: MeasurementSchema
    group_id: str | None = None
    primary_muscles: list[str] = Field(default_factory=list)
    secondary_muscles: list[str] = Field(default_factory=list)
    rest_seconds: int | None = Field(default=None, ge=0, le=7200)
    notes: str | None = Field(default=None, max_length=2000)
    sets: list[SetWrite] = Field(default_factory=list)


class WorkoutCreate(BaseModel):
    client_id: str = Field(..., min_length=8, max_length=36)
    workout_type: str = Field(default="strength", min_length=1, max_length=120)
    title: str | None = Field(default=None, max_length=160)
    start_time: datetime
    end_time: datetime | None = None
    timezone: str = Field(default="UTC", min_length=1, max_length=80)
    status: Literal["active", "completed"] = "active"
    notes: str | None = Field(default=None, max_length=10000)
    session_rpe: float | None = Field(default=None, ge=0, le=10)
    exercises: list[WorkoutExerciseWrite] = Field(default_factory=list)

    @model_validator(mode="after")
    def validate_times(self) -> "WorkoutCreate":
        if self.end_time is not None and self.end_time < self.start_time:
            raise ValueError("end_time must not be before start_time")
        if self.status == "completed" and self.end_time is None:
            raise ValueError("completed workouts require end_time")
        return self


class WorkoutUpdate(BaseModel):
    revision: int = Field(..., ge=1)
    workout_type: str = Field(default="strength", min_length=1, max_length=120)
    title: str | None = Field(default=None, max_length=160)
    start_time: datetime
    end_time: datetime | None = None
    timezone: str = Field(default="UTC", min_length=1, max_length=80)
    status: Literal["active", "completed"] = "active"
    notes: str | None = Field(default=None, max_length=10000)
    session_rpe: float | None = Field(default=None, ge=0, le=10)
    exercises: list[WorkoutExerciseWrite] = Field(default_factory=list)

    @model_validator(mode="after")
    def validate_times(self) -> "WorkoutUpdate":
        if self.end_time is not None and self.end_time < self.start_time:
            raise ValueError("end_time must not be before start_time")
        if self.status == "completed" and self.end_time is None:
            raise ValueError("completed workouts require end_time")
        return self


class RoutineExerciseWrite(BaseModel):
    exercise_id: str | None = None
    name: str = Field(..., min_length=1, max_length=180)
    measurement_schema: MeasurementSchema
    group_id: str | None = None
    target_sets: int | None = Field(default=None, ge=1, le=100)
    target_reps_min: int | None = Field(default=None, ge=0, le=10000)
    target_reps_max: int | None = Field(default=None, ge=0, le=10000)
    target_load_value: float | None = Field(default=None, ge=0, le=100000)
    target_load_unit: Literal["kg", "lb"] | None = None
    target_duration_seconds: int | None = Field(default=None, ge=0, le=604800)
    target_distance_meters: float | None = Field(default=None, ge=0, le=1000000)
    target_rir: float | None = Field(default=None, ge=0, le=20)
    rest_seconds: int | None = Field(default=None, ge=0, le=7200)
    notes: str | None = Field(default=None, max_length=2000)


class RoutineWrite(BaseModel):
    name: str = Field(..., min_length=1, max_length=160)
    notes: str | None = Field(default=None, max_length=10000)
    scheduled_weekdays: list[int] = Field(default_factory=list)
    is_favorite: bool = False
    exercises: list[RoutineExerciseWrite] = Field(default_factory=list)

    @model_validator(mode="after")
    def validate_weekdays(self) -> "RoutineWrite":
        if any(day < 1 or day > 7 for day in self.scheduled_weekdays):
            raise ValueError("scheduled_weekdays must use ISO weekday values 1 through 7")
        self.scheduled_weekdays = sorted(set(self.scheduled_weekdays))
        return self


class CustomExerciseWrite(BaseModel):
    name: str = Field(..., min_length=1, max_length=180)
    aliases: list[str] = Field(default_factory=list)
    instructions: list[str] = Field(default_factory=list)
    equipment: str | None = Field(default=None, max_length=80)
    category: str | None = Field(default=None, max_length=80)
    movement_pattern: str | None = Field(default=None, max_length=80)
    primary_muscles: list[str] = Field(default_factory=list)
    secondary_muscles: list[str] = Field(default_factory=list)
    measurement_schema: MeasurementSchema
    default_rest_seconds: int | None = Field(default=None, ge=0, le=7200)


class SaveRoutineWrite(BaseModel):
    name: str = Field(..., min_length=1, max_length=160)
    scheduled_weekdays: list[int] = Field(default_factory=list)


@router.get("/overview")
def fitness_overview(
    session: DbSession,
    user: CurrentUser,
    recent_limit: int = Query(default=20, ge=1, le=100),
) -> dict[str, Any]:
    active = session.scalar(
        select(Workout)
        .where(
            Workout.user_id == user.id,
            Workout.status == "active",
            Workout.deleted_at.is_(None),
        )
        .order_by(Workout.start_time.desc())
    )
    routines = session.scalars(
        select(WorkoutRoutine)
        .where(
            WorkoutRoutine.user_id == user.id,
            WorkoutRoutine.is_archived.is_(False),
        )
        .order_by(WorkoutRoutine.is_favorite.desc(), WorkoutRoutine.updated_at.desc())
    ).all()
    recent = session.scalars(
        select(Workout)
        .where(
            Workout.user_id == user.id,
            Workout.status == "completed",
            Workout.deleted_at.is_(None),
        )
        .order_by(Workout.start_time.desc())
        .limit(recent_limit)
    ).all()
    weekday = _local_today(session, user.id).isoweekday()
    return {
        "active_workout": _workout_payload(session, active) if active else None,
        "due_routines": [
            _routine_payload(session, routine)
            for routine in routines
            if weekday in (routine.scheduled_weekdays or [])
        ],
        "routines": [_routine_payload(session, routine) for routine in routines],
        "recent_workouts": [_workout_payload(session, workout, include_sets=False) for workout in recent],
    }


@router.get("/exercises")
def list_exercises(
    session: DbSession,
    user: CurrentUser,
    query: str | None = Query(default=None, max_length=120),
    muscle: str | None = Query(default=None, max_length=80),
    equipment: str | None = Query(default=None, max_length=80),
    schema: str | None = Query(default=None, max_length=40),
    include_long_tail: bool = False,
    limit: int = Query(default=100, ge=1, le=300),
) -> list[dict[str, Any]]:
    statement = select(ExerciseCatalogItem).where(
        ExerciseCatalogItem.is_archived.is_(False),
        or_(ExerciseCatalogItem.user_id.is_(None), ExerciseCatalogItem.user_id == user.id),
    )
    if not include_long_tail:
        statement = statement.where(
            or_(ExerciseCatalogItem.is_curated.is_(True), ExerciseCatalogItem.user_id == user.id)
        )
    if equipment:
        statement = statement.where(func.lower(ExerciseCatalogItem.equipment) == equipment.lower())
    if schema:
        statement = statement.where(ExerciseCatalogItem.measurement_schema == schema)
    items = session.scalars(statement.order_by(ExerciseCatalogItem.name)).all()
    favorite_ids = set(
        session.scalars(
            select(ExerciseFavorite.exercise_id).where(ExerciseFavorite.user_id == user.id)
        ).all()
    )
    history_rows = session.execute(
        select(
            WorkoutExercise.exercise_id,
            func.count(WorkoutExercise.id),
            func.max(Workout.start_time),
        )
        .join(Workout, WorkoutExercise.workout_id == Workout.id)
        .where(
            Workout.user_id == user.id,
            Workout.status == "completed",
            Workout.deleted_at.is_(None),
            WorkoutExercise.exercise_id.is_not(None),
        )
        .group_by(WorkoutExercise.exercise_id)
    ).all()
    history = {row[0]: (int(row[1]), row[2]) for row in history_rows}
    query_value = (query or "").strip().lower()
    muscle_value = (muscle or "").strip().lower()
    filtered = [
        item
        for item in items
        if (
            not query_value
            or query_value in item.name.lower()
            or any(query_value in alias.lower() for alias in item.aliases or [])
        )
        and (
            not muscle_value
            or muscle_value in [value.lower() for value in (item.primary_muscles or [])]
            or muscle_value in [value.lower() for value in (item.secondary_muscles or [])]
        )
    ]
    filtered.sort(
        key=lambda item: (
            item.id not in favorite_ids,
            -(history.get(item.id, (0, None))[0]),
            not item.is_curated,
            item.name.lower(),
        )
    )
    return [
        _exercise_payload(
            item,
            is_favorite=item.id in favorite_ids,
            use_count=history.get(item.id, (0, None))[0],
            last_used_at=history.get(item.id, (0, None))[1],
        )
        for item in filtered[:limit]
    ]


@router.post("/exercises", status_code=status.HTTP_201_CREATED)
def create_custom_exercise(
    payload: CustomExerciseWrite,
    session: DbSession,
    user: CurrentUser,
) -> dict[str, Any]:
    item = ExerciseCatalogItem(
        user_id=user.id,
        source="custom",
        name=payload.name.strip(),
        aliases=payload.aliases,
        instructions=payload.instructions,
        equipment=_clean_optional(payload.equipment),
        category=_clean_optional(payload.category),
        movement_pattern=_clean_optional(payload.movement_pattern),
        primary_muscles=payload.primary_muscles,
        secondary_muscles=payload.secondary_muscles,
        measurement_schema=payload.measurement_schema,
        default_rest_seconds=payload.default_rest_seconds,
        is_curated=False,
    )
    session.add(item)
    session.commit()
    session.refresh(item)
    return _exercise_payload(item)


@router.patch("/exercises/{exercise_id}")
def update_custom_exercise(
    exercise_id: str,
    payload: CustomExerciseWrite,
    session: DbSession,
    user: CurrentUser,
) -> dict[str, Any]:
    item = _user_custom_exercise(session, user.id, exercise_id)
    item.name = payload.name.strip()
    item.aliases = payload.aliases
    item.instructions = payload.instructions
    item.equipment = _clean_optional(payload.equipment)
    item.category = _clean_optional(payload.category)
    item.movement_pattern = _clean_optional(payload.movement_pattern)
    item.primary_muscles = payload.primary_muscles
    item.secondary_muscles = payload.secondary_muscles
    item.measurement_schema = payload.measurement_schema
    item.default_rest_seconds = payload.default_rest_seconds
    session.add(item)
    session.commit()
    session.refresh(item)
    return _exercise_payload(item)


@router.delete("/exercises/{exercise_id}", status_code=status.HTTP_204_NO_CONTENT)
def archive_custom_exercise(
    exercise_id: str,
    session: DbSession,
    user: CurrentUser,
) -> None:
    item = _user_custom_exercise(session, user.id, exercise_id)
    item.is_archived = True
    session.add(item)
    session.commit()


@router.post("/exercises/{exercise_id}/favorite", status_code=status.HTTP_204_NO_CONTENT)
def favorite_exercise(exercise_id: str, session: DbSession, user: CurrentUser) -> None:
    _catalog_item_for_user(session, user.id, exercise_id)
    existing = session.scalar(
        select(ExerciseFavorite).where(
            ExerciseFavorite.user_id == user.id,
            ExerciseFavorite.exercise_id == exercise_id,
        )
    )
    if existing is None:
        session.add(ExerciseFavorite(user_id=user.id, exercise_id=exercise_id))
        session.commit()


@router.delete("/exercises/{exercise_id}/favorite", status_code=status.HTTP_204_NO_CONTENT)
def unfavorite_exercise(exercise_id: str, session: DbSession, user: CurrentUser) -> None:
    session.execute(
        delete(ExerciseFavorite).where(
            ExerciseFavorite.user_id == user.id,
            ExerciseFavorite.exercise_id == exercise_id,
        )
    )
    session.commit()


@router.get("/exercises/{exercise_id}/history")
def exercise_history(
    exercise_id: str,
    session: DbSession,
    user: CurrentUser,
    limit: int = Query(default=20, ge=1, le=100),
) -> dict[str, Any]:
    item = _catalog_item_for_user(session, user.id, exercise_id)
    rows = session.execute(
        select(WorkoutSet, WorkoutExercise, Workout)
        .join(WorkoutExercise, WorkoutSet.workout_exercise_id == WorkoutExercise.id)
        .join(Workout, WorkoutExercise.workout_id == Workout.id)
        .where(
            Workout.user_id == user.id,
            Workout.status == "completed",
            Workout.deleted_at.is_(None),
            WorkoutExercise.exercise_id == exercise_id,
            WorkoutSet.status == "completed",
        )
        .order_by(Workout.start_time.desc(), WorkoutSet.order_index)
    ).all()
    sessions: dict[str, dict[str, Any]] = {}
    best_e1rm: float | None = None
    max_load_kg: float | None = None
    max_reps: int | None = None
    total_volume_kg = 0.0
    for set_row, _, workout in rows:
        session_row = sessions.setdefault(
            workout.id,
            {
                "workout_id": workout.id,
                "title": workout.title or _default_workout_title(workout.workout_type),
                "start_time": workout.start_time,
                "sets": [],
            },
        )
        set_payload = _set_payload(set_row)
        e1rm = _set_e1rm_kg(set_row)
        if e1rm is not None:
            set_payload["estimated_one_rep_max_kg"] = e1rm
            best_e1rm = max(best_e1rm or 0, e1rm)
        if set_row.load_value is not None:
            load_kg = _load_kg(set_row.load_value, set_row.load_unit)
            max_load_kg = max(max_load_kg or 0, load_kg)
            if set_row.reps is not None:
                total_volume_kg += load_kg * set_row.reps
        if set_row.reps is not None:
            max_reps = max(max_reps or 0, set_row.reps)
        session_row["sets"].append(set_payload)
    return {
        "exercise": _exercise_payload(item),
        "records": {
            "estimated_one_rep_max_kg": round(best_e1rm, 2) if best_e1rm else None,
            "max_load_kg": round(max_load_kg, 2) if max_load_kg else None,
            "max_reps": max_reps,
            "total_volume_kg": round(total_volume_kg, 2),
        },
        "sessions": list(sessions.values())[:limit],
    }


@router.get("/routines")
def list_routines(session: DbSession, user: CurrentUser) -> list[dict[str, Any]]:
    routines = session.scalars(
        select(WorkoutRoutine)
        .where(
            WorkoutRoutine.user_id == user.id,
            WorkoutRoutine.is_archived.is_(False),
        )
        .order_by(WorkoutRoutine.is_favorite.desc(), WorkoutRoutine.updated_at.desc())
    ).all()
    return [_routine_payload(session, routine) for routine in routines]


@router.post("/routines", status_code=status.HTTP_201_CREATED)
def create_routine(
    payload: RoutineWrite,
    session: DbSession,
    user: CurrentUser,
) -> dict[str, Any]:
    routine = WorkoutRoutine(
        user_id=user.id,
        name=payload.name.strip(),
        notes=_clean_optional(payload.notes),
        scheduled_weekdays=payload.scheduled_weekdays,
        is_favorite=payload.is_favorite,
    )
    session.add(routine)
    session.flush()
    _replace_routine_exercises(session, routine, payload.exercises, user.id)
    session.commit()
    session.refresh(routine)
    return _routine_payload(session, routine)


@router.put("/routines/{routine_id}")
def update_routine(
    routine_id: str,
    payload: RoutineWrite,
    session: DbSession,
    user: CurrentUser,
) -> dict[str, Any]:
    routine = _user_routine(session, user.id, routine_id)
    routine.name = payload.name.strip()
    routine.notes = _clean_optional(payload.notes)
    routine.scheduled_weekdays = payload.scheduled_weekdays
    routine.is_favorite = payload.is_favorite
    session.add(routine)
    _replace_routine_exercises(session, routine, payload.exercises, user.id)
    session.commit()
    session.refresh(routine)
    return _routine_payload(session, routine)


@router.delete("/routines/{routine_id}", status_code=status.HTTP_204_NO_CONTENT)
def archive_routine(routine_id: str, session: DbSession, user: CurrentUser) -> None:
    routine = _user_routine(session, user.id, routine_id)
    routine.is_archived = True
    session.add(routine)
    session.commit()


@router.post("/routines/{routine_id}/start", status_code=status.HTTP_201_CREATED)
def start_routine(
    routine_id: str,
    client_id: str,
    session: DbSession,
    user: CurrentUser,
) -> dict[str, Any]:
    routine = _user_routine(session, user.id, routine_id)
    existing = session.scalar(
        select(Workout).where(Workout.user_id == user.id, Workout.client_id == client_id)
    )
    if existing is not None:
        return _workout_payload(session, existing)
    if _active_workout(session, user.id) is not None:
        raise HTTPException(status_code=409, detail="An active workout already exists")
    start_time = utcnow()
    workout = Workout(
        user_id=user.id,
        client_id=client_id,
        routine_id=routine.id,
        title=routine.name,
        workout_type="strength",
        start_time=start_time,
        end_time=start_time,
        civil_date=start_time.date(),
        duration_seconds=0,
        status="active",
        origin="manual",
        timezone=_user_timezone(session, user.id),
        awaiting_wearable=True,
    )
    session.add(workout)
    session.flush()
    routine_items = session.scalars(
        select(RoutineExercise)
        .where(RoutineExercise.routine_id == routine.id)
        .order_by(RoutineExercise.order_index)
    ).all()
    for order, routine_item in enumerate(routine_items):
        item = WorkoutExercise(
            workout_id=workout.id,
            exercise_id=routine_item.exercise_id,
            order_index=order,
            group_id=routine_item.group_id,
            name_snapshot=routine_item.name_snapshot,
            measurement_schema=routine_item.measurement_schema,
            primary_muscles=_exercise_muscles(session, routine_item.exercise_id, primary=True),
            secondary_muscles=_exercise_muscles(session, routine_item.exercise_id, primary=False),
            rest_seconds=routine_item.rest_seconds,
            notes=routine_item.notes,
        )
        session.add(item)
        session.flush()
        for set_index in range(routine_item.target_sets or 0):
            session.add(
                WorkoutSet(
                    workout_exercise_id=item.id,
                    order_index=set_index,
                    reps=routine_item.target_reps_min,
                    load_value=routine_item.target_load_value,
                    load_unit=routine_item.target_load_unit,
                    duration_seconds=routine_item.target_duration_seconds,
                    distance_meters=routine_item.target_distance_meters,
                    rir=routine_item.target_rir,
                    status="planned",
                )
            )
    session.commit()
    return _workout_payload(session, workout)


@router.post("/workouts", status_code=status.HTTP_201_CREATED)
def create_workout(
    payload: WorkoutCreate,
    session: DbSession,
    user: CurrentUser,
) -> dict[str, Any]:
    existing = session.scalar(
        select(Workout).where(Workout.user_id == user.id, Workout.client_id == payload.client_id)
    )
    if existing is not None:
        return _workout_payload(session, existing)
    if payload.status == "active" and _active_workout(session, user.id) is not None:
        raise HTTPException(status_code=409, detail="An active workout already exists")

    end_time = payload.end_time or payload.start_time
    target = _high_confidence_wearable_match(
        session,
        user_id=user.id,
        start_time=payload.start_time,
        end_time=end_time,
        workout_type=payload.workout_type,
    )
    workout = target or Workout(user_id=user.id)
    workout.client_id = payload.client_id
    workout.origin = "mixed" if target else "manual"
    _apply_workout_document(session, workout, payload, user.id)
    if target is None:
        session.add(workout)
        session.flush()
    _replace_workout_exercises(session, workout, payload.exercises, user.id)
    session.commit()
    session.refresh(workout)
    return _workout_payload(session, workout)


@router.get("/workouts/{workout_id}")
def fitness_workout_detail(
    workout_id: str,
    session: DbSession,
    user: CurrentUser,
) -> dict[str, Any]:
    return _workout_payload(session, _user_workout(session, user.id, workout_id))


@router.put("/workouts/{workout_id}")
def update_workout(
    workout_id: str,
    payload: WorkoutUpdate,
    session: DbSession,
    user: CurrentUser,
) -> dict[str, Any]:
    workout = _user_workout(session, user.id, workout_id)
    if workout.revision != payload.revision:
        raise HTTPException(
            status_code=409,
            detail={"message": "Workout changed on another device", "current_revision": workout.revision},
        )
    _apply_workout_document(session, workout, payload, user.id)
    workout.revision += 1
    _replace_workout_exercises(session, workout, payload.exercises, user.id)
    session.commit()
    session.refresh(workout)
    return _workout_payload(session, workout)


@router.delete("/workouts/{workout_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_workout(workout_id: str, session: DbSession, user: CurrentUser) -> None:
    workout = _user_workout(session, user.id, workout_id)
    workout.deleted_at = utcnow()
    workout.status = "deleted"
    workout.revision += 1
    session.add(workout)
    session.commit()


@router.post("/workouts/{workout_id}/save-as-routine", status_code=status.HTTP_201_CREATED)
def save_workout_as_routine(
    workout_id: str,
    payload: SaveRoutineWrite,
    session: DbSession,
    user: CurrentUser,
) -> dict[str, Any]:
    workout = _user_workout(session, user.id, workout_id)
    if any(day < 1 or day > 7 for day in payload.scheduled_weekdays):
        raise HTTPException(status_code=422, detail="Weekdays must use values 1 through 7")
    routine = WorkoutRoutine(
        user_id=user.id,
        name=payload.name.strip(),
        scheduled_weekdays=sorted(set(payload.scheduled_weekdays)),
    )
    session.add(routine)
    session.flush()
    exercises = session.scalars(
        select(WorkoutExercise)
        .where(WorkoutExercise.workout_id == workout.id)
        .order_by(WorkoutExercise.order_index)
    ).all()
    for index, exercise in enumerate(exercises):
        sets = session.scalars(
            select(WorkoutSet)
            .where(
                WorkoutSet.workout_exercise_id == exercise.id,
                WorkoutSet.status == "completed",
            )
            .order_by(WorkoutSet.order_index)
        ).all()
        reps = [item.reps for item in sets if item.reps is not None]
        last_set = sets[-1] if sets else None
        session.add(
            RoutineExercise(
                routine_id=routine.id,
                exercise_id=exercise.exercise_id,
                order_index=index,
                group_id=exercise.group_id,
                name_snapshot=exercise.name_snapshot,
                measurement_schema=exercise.measurement_schema,
                target_sets=max(1, len(sets)),
                target_reps_min=min(reps) if reps else None,
                target_reps_max=max(reps) if reps else None,
                target_load_value=last_set.load_value if last_set else None,
                target_load_unit=last_set.load_unit if last_set else None,
                target_duration_seconds=last_set.duration_seconds if last_set else None,
                target_distance_meters=last_set.distance_meters if last_set else None,
                target_rir=last_set.rir if last_set else None,
                rest_seconds=exercise.rest_seconds,
                notes=exercise.notes,
            )
        )
    session.commit()
    return _routine_payload(session, routine)


@router.get("/workouts/{workout_id}/matches")
def workout_matches(
    workout_id: str,
    session: DbSession,
    user: CurrentUser,
) -> list[dict[str, Any]]:
    workout = _user_workout(session, user.id, workout_id)
    rejected = {
        tuple(sorted((row.left_workout_id, row.right_workout_id)))
        for row in session.scalars(
            select(WorkoutMatchRejection).where(WorkoutMatchRejection.user_id == user.id)
        ).all()
    }
    matches = find_workout_matches(
        session,
        user_id=user.id,
        start_time=workout.start_time,
        end_time=workout.end_time,
        workout_type=workout.workout_type,
        exclude_id=workout.id,
    )
    return [
        {
            "confidence": "high" if score >= HIGH_MATCH_SCORE else "medium",
            "score": score,
            "workout": _workout_payload(session, candidate, include_sets=False),
        }
        for candidate, score in matches
        if tuple(sorted((workout.id, candidate.id))) not in rejected
    ]


@router.post("/workouts/{workout_id}/merge/{other_workout_id}")
def merge_workouts(
    workout_id: str,
    other_workout_id: str,
    session: DbSession,
    user: CurrentUser,
) -> dict[str, Any]:
    target = _user_workout(session, user.id, workout_id)
    other = _user_workout(session, user.id, other_workout_id)
    attach_source_to_workout(session, source_workout=other, target_workout=target)
    target_exercises = session.scalar(
        select(func.count()).select_from(WorkoutExercise).where(WorkoutExercise.workout_id == target.id)
    ) or 0
    if target_exercises == 0:
        donor_exercises = session.scalars(
            select(WorkoutExercise)
            .where(WorkoutExercise.workout_id == other.id)
            .order_by(WorkoutExercise.order_index)
        ).all()
        for index, exercise in enumerate(donor_exercises):
            exercise.workout_id = target.id
            exercise.order_index = index
            session.add(exercise)
    other.deleted_at = utcnow()
    other.status = "merged"
    target.revision += 1
    session.add_all([target, other])
    session.commit()
    return _workout_payload(session, target)


@router.post("/workouts/{workout_id}/reject-match/{other_workout_id}", status_code=204)
def reject_workout_match(
    workout_id: str,
    other_workout_id: str,
    session: DbSession,
    user: CurrentUser,
) -> None:
    _user_workout(session, user.id, workout_id)
    _user_workout(session, user.id, other_workout_id)
    left, right = sorted((workout_id, other_workout_id))
    existing = session.scalar(
        select(WorkoutMatchRejection).where(
            WorkoutMatchRejection.user_id == user.id,
            WorkoutMatchRejection.left_workout_id == left,
            WorkoutMatchRejection.right_workout_id == right,
        )
    )
    if existing is None:
        session.add(
            WorkoutMatchRejection(
                user_id=user.id,
                left_workout_id=left,
                right_workout_id=right,
                reason="user_rejected",
            )
        )
        session.commit()


def _apply_workout_document(
    session: DbSession,
    workout: Workout,
    payload: WorkoutCreate | WorkoutUpdate,
    user_id: str,
) -> None:
    end_time = payload.end_time or payload.start_time
    workout.workout_type = payload.workout_type.strip()
    workout.title = _clean_optional(payload.title)
    workout.start_time = payload.start_time
    workout.end_time = end_time
    workout.civil_date = _local_date(payload.start_time, payload.timezone)
    workout.duration_seconds = max(0, int((end_time - payload.start_time).total_seconds()))
    workout.timezone = payload.timezone
    workout.status = payload.status
    workout.notes = _clean_optional(payload.notes)
    workout.session_rpe = payload.session_rpe
    workout.is_user_edited = True
    workout.awaiting_wearable = workout.origin in {"manual", "mixed"} and not _has_source(
        session, workout.id
    )
    workout.completed_at = end_time if payload.status == "completed" else None
    if payload.status == "completed" and workout.routine_id:
        routine = session.get(WorkoutRoutine, workout.routine_id)
        if routine is not None and routine.user_id == user_id:
            routine.last_performed_at = end_time
            session.add(routine)
    session.add(workout)


def _replace_workout_exercises(
    session: DbSession,
    workout: Workout,
    exercises: list[WorkoutExerciseWrite],
    user_id: str,
) -> None:
    existing_ids = session.scalars(
        select(WorkoutExercise.id).where(WorkoutExercise.workout_id == workout.id)
    ).all()
    if existing_ids:
        session.execute(delete(WorkoutSet).where(WorkoutSet.workout_exercise_id.in_(existing_ids)))
    session.execute(delete(WorkoutExercise).where(WorkoutExercise.workout_id == workout.id))
    session.flush()
    for order, payload in enumerate(exercises):
        catalog = _catalog_item_for_user(session, user_id, payload.exercise_id)
        exercise = WorkoutExercise(
            workout_id=workout.id,
            exercise_id=catalog.id if catalog else None,
            order_index=order,
            group_id=payload.group_id,
            name_snapshot=catalog.name if catalog else payload.name.strip(),
            measurement_schema=catalog.measurement_schema if catalog else payload.measurement_schema,
            primary_muscles=catalog.primary_muscles if catalog else payload.primary_muscles,
            secondary_muscles=catalog.secondary_muscles if catalog else payload.secondary_muscles,
            rest_seconds=payload.rest_seconds or (catalog.default_rest_seconds if catalog else None),
            notes=_clean_optional(payload.notes),
        )
        session.add(exercise)
        session.flush()
        for set_order, set_payload in enumerate(payload.sets):
            session.add(
                WorkoutSet(
                    workout_exercise_id=exercise.id,
                    order_index=set_order,
                    set_type=set_payload.set_type,
                    status=set_payload.status,
                    drop_group_id=set_payload.drop_group_id,
                    reps=set_payload.reps,
                    load_value=set_payload.load_value,
                    load_unit=set_payload.load_unit,
                    load_per_implement=set_payload.load_per_implement,
                    implement_count=set_payload.implement_count,
                    side_count=set_payload.side_count,
                    duration_seconds=set_payload.duration_seconds,
                    distance_meters=set_payload.distance_meters,
                    assistance_kg=set_payload.assistance_kg,
                    added_load_kg=set_payload.added_load_kg,
                    rir=set_payload.rir,
                    notes=_clean_optional(set_payload.notes),
                    completed_at=(
                        set_payload.completed_at or utcnow()
                        if set_payload.status == "completed"
                        else None
                    ),
                )
            )


def _replace_routine_exercises(
    session: DbSession,
    routine: WorkoutRoutine,
    exercises: list[RoutineExerciseWrite],
    user_id: str,
) -> None:
    session.execute(delete(RoutineExercise).where(RoutineExercise.routine_id == routine.id))
    session.flush()
    for order, payload in enumerate(exercises):
        catalog = _catalog_item_for_user(session, user_id, payload.exercise_id)
        session.add(
            RoutineExercise(
                routine_id=routine.id,
                exercise_id=catalog.id if catalog else None,
                order_index=order,
                group_id=payload.group_id,
                name_snapshot=catalog.name if catalog else payload.name.strip(),
                measurement_schema=catalog.measurement_schema if catalog else payload.measurement_schema,
                target_sets=payload.target_sets,
                target_reps_min=payload.target_reps_min,
                target_reps_max=payload.target_reps_max,
                target_load_value=payload.target_load_value,
                target_load_unit=payload.target_load_unit,
                target_duration_seconds=payload.target_duration_seconds,
                target_distance_meters=payload.target_distance_meters,
                target_rir=payload.target_rir,
                rest_seconds=payload.rest_seconds,
                notes=_clean_optional(payload.notes),
            )
        )


def _workout_payload(
    session: DbSession,
    workout: Workout,
    *,
    include_sets: bool = True,
) -> dict[str, Any]:
    source_rows = session.scalars(
        select(WorkoutSource)
        .where(WorkoutSource.workout_id == workout.id)
        .order_by(WorkoutSource.created_at)
    ).all()
    exercise_rows = session.scalars(
        select(WorkoutExercise)
        .where(WorkoutExercise.workout_id == workout.id)
        .order_by(WorkoutExercise.order_index)
    ).all()
    exercises = []
    completed_set_count = 0
    volume_kg = 0.0
    muscle_counts: dict[str, float] = {}
    for exercise in exercise_rows:
        sets = session.scalars(
            select(WorkoutSet)
            .where(WorkoutSet.workout_exercise_id == exercise.id)
            .order_by(WorkoutSet.order_index)
        ).all()
        completed = [item for item in sets if item.status == "completed"]
        completed_set_count += len(completed)
        for item in completed:
            if item.reps is not None and item.load_value is not None:
                load_kg = item.load_value * (0.45359237 if item.load_unit == "lb" else 1.0)
                volume_kg += item.reps * load_kg
        if completed:
            for muscle in exercise.primary_muscles or []:
                muscle_counts[muscle] = muscle_counts.get(muscle, 0) + len(completed)
            for muscle in exercise.secondary_muscles or []:
                muscle_counts[muscle] = muscle_counts.get(muscle, 0) + len(completed) * 0.5
        exercises.append(
            {
                "id": exercise.id,
                "exercise_id": exercise.exercise_id,
                "name": exercise.name_snapshot,
                "measurement_schema": exercise.measurement_schema,
                "order_index": exercise.order_index,
                "group_id": exercise.group_id,
                "primary_muscles": exercise.primary_muscles,
                "secondary_muscles": exercise.secondary_muscles,
                "rest_seconds": exercise.rest_seconds,
                "notes": exercise.notes,
                "sets": [_set_payload(item) for item in sets] if include_sets else [],
                "completed_set_count": len(completed),
                "planned_set_count": len(sets),
            }
        )
    return {
        "id": workout.id,
        "client_id": workout.client_id,
        "routine_id": workout.routine_id,
        "title": workout.title or _default_workout_title(workout.workout_type),
        "workout_type": workout.workout_type,
        "status": workout.status,
        "origin": workout.origin,
        "start_time": workout.start_time,
        "end_time": workout.end_time,
        "date": workout.civil_date,
        "duration_seconds": workout.duration_seconds,
        "timezone": workout.timezone,
        "notes": workout.notes,
        "session_rpe": workout.session_rpe,
        "revision": workout.revision,
        "awaiting_wearable": workout.awaiting_wearable,
        "completed_at": workout.completed_at,
        "updated_at": workout.updated_at,
        "summary": {
            "exercise_count": len(exercise_rows),
            "completed_set_count": completed_set_count,
            "volume_kg": round(volume_kg, 2),
        },
        "muscles_trained": [
            {"muscle": muscle, "set_equivalents": round(value, 1)}
            for muscle, value in sorted(muscle_counts.items(), key=lambda item: item[1], reverse=True)
        ],
        "sources": [
            {
                "id": row.id,
                "provider": row.provider,
                "source_record_id": row.source_record_id,
                "source_platform": row.source_platform,
                "source_device": row.source_device,
                "start_time": row.start_time,
                "end_time": row.end_time,
            }
            for row in source_rows
        ],
        "exercises": exercises if include_sets else [],
    }


def _set_payload(item: WorkoutSet) -> dict[str, Any]:
    return {
        "id": item.id,
        "order_index": item.order_index,
        "set_type": item.set_type,
        "status": item.status,
        "drop_group_id": item.drop_group_id,
        "reps": item.reps,
        "load_value": item.load_value,
        "load_unit": item.load_unit,
        "load_per_implement": item.load_per_implement,
        "implement_count": item.implement_count,
        "side_count": item.side_count,
        "duration_seconds": item.duration_seconds,
        "distance_meters": item.distance_meters,
        "assistance_kg": item.assistance_kg,
        "added_load_kg": item.added_load_kg,
        "rir": item.rir,
        "notes": item.notes,
        "completed_at": item.completed_at,
    }


def _routine_payload(session: DbSession, routine: WorkoutRoutine) -> dict[str, Any]:
    exercises = session.scalars(
        select(RoutineExercise)
        .where(RoutineExercise.routine_id == routine.id)
        .order_by(RoutineExercise.order_index)
    ).all()
    return {
        "id": routine.id,
        "name": routine.name,
        "notes": routine.notes,
        "scheduled_weekdays": routine.scheduled_weekdays,
        "is_favorite": routine.is_favorite,
        "last_performed_at": routine.last_performed_at,
        "exercises": [
            {
                "id": item.id,
                "exercise_id": item.exercise_id,
                "name": item.name_snapshot,
                "measurement_schema": item.measurement_schema,
                "order_index": item.order_index,
                "group_id": item.group_id,
                "target_sets": item.target_sets,
                "target_reps_min": item.target_reps_min,
                "target_reps_max": item.target_reps_max,
                "target_load_value": item.target_load_value,
                "target_load_unit": item.target_load_unit,
                "target_duration_seconds": item.target_duration_seconds,
                "target_distance_meters": item.target_distance_meters,
                "target_rir": item.target_rir,
                "rest_seconds": item.rest_seconds,
                "notes": item.notes,
            }
            for item in exercises
        ],
    }


def _exercise_payload(
    item: ExerciseCatalogItem,
    *,
    is_favorite: bool = False,
    use_count: int = 0,
    last_used_at: datetime | None = None,
) -> dict[str, Any]:
    return {
        "id": item.id,
        "external_id": item.external_id,
        "source": item.source,
        "name": item.name,
        "aliases": item.aliases,
        "instructions": item.instructions,
        "media": item.media,
        "equipment": item.equipment,
        "category": item.category,
        "movement_pattern": item.movement_pattern,
        "primary_muscles": item.primary_muscles,
        "secondary_muscles": item.secondary_muscles,
        "measurement_schema": item.measurement_schema,
        "default_rest_seconds": item.default_rest_seconds,
        "is_curated": item.is_curated,
        "is_custom": item.user_id is not None,
        "is_favorite": is_favorite,
        "use_count": use_count,
        "last_used_at": last_used_at,
    }


def _user_workout(session: DbSession, user_id: str, workout_id: str) -> Workout:
    workout = session.get(Workout, workout_id)
    if workout is None or workout.user_id != user_id or workout.deleted_at is not None:
        raise HTTPException(status_code=404, detail="Workout not found")
    return workout


def _active_workout(session: DbSession, user_id: str) -> Workout | None:
    return session.scalar(
        select(Workout).where(
            Workout.user_id == user_id,
            Workout.status == "active",
            Workout.deleted_at.is_(None),
        )
    )


def _user_routine(session: DbSession, user_id: str, routine_id: str) -> WorkoutRoutine:
    routine = session.get(WorkoutRoutine, routine_id)
    if routine is None or routine.user_id != user_id or routine.is_archived:
        raise HTTPException(status_code=404, detail="Routine not found")
    return routine


def _user_custom_exercise(
    session: DbSession,
    user_id: str,
    exercise_id: str,
) -> ExerciseCatalogItem:
    item = session.get(ExerciseCatalogItem, exercise_id)
    if item is None or item.user_id != user_id or item.source != "custom" or item.is_archived:
        raise HTTPException(status_code=404, detail="Custom exercise not found")
    return item


def _catalog_item_for_user(
    session: DbSession,
    user_id: str,
    exercise_id: str | None,
) -> ExerciseCatalogItem | None:
    if not exercise_id:
        return None
    item = session.get(ExerciseCatalogItem, exercise_id)
    if item is None or item.is_archived or item.user_id not in {None, user_id}:
        raise HTTPException(status_code=422, detail=f"Exercise {exercise_id} is unavailable")
    return item


def _high_confidence_wearable_match(
    session: DbSession,
    *,
    user_id: str,
    start_time: datetime,
    end_time: datetime,
    workout_type: str | None,
) -> Workout | None:
    for candidate, score in find_workout_matches(
        session,
        user_id=user_id,
        start_time=start_time,
        end_time=end_time,
        workout_type=workout_type,
    ):
        if score >= HIGH_MATCH_SCORE and candidate.origin == "wearable":
            return candidate
    return None


def _has_source(session: DbSession, workout_id: str | None) -> bool:
    if not workout_id:
        return False
    return session.scalar(
        select(WorkoutSource.id).where(WorkoutSource.workout_id == workout_id).limit(1)
    ) is not None


def _exercise_muscles(session: DbSession, exercise_id: str | None, *, primary: bool) -> list[str]:
    if not exercise_id:
        return []
    item = session.get(ExerciseCatalogItem, exercise_id)
    if item is None:
        return []
    return item.primary_muscles if primary else item.secondary_muscles


def _local_today(session: DbSession, user_id: str) -> date:
    timezone = _user_timezone(session, user_id)
    try:
        return datetime.now(ZoneInfo(timezone)).date()
    except ZoneInfoNotFoundError:
        return datetime.now(UTC).date()


def _local_date(value: datetime, timezone: str) -> date:
    try:
        return value.astimezone(ZoneInfo(timezone)).date()
    except ZoneInfoNotFoundError:
        return value.date()


def _user_timezone(session: DbSession, user_id: str) -> str:
    profile = session.scalar(select(UserProfile).where(UserProfile.user_id == user_id))
    return profile.timezone if profile else "UTC"


def _default_workout_title(workout_type: str | None) -> str:
    value = (workout_type or "workout").replace("_", " ").strip()
    return f"{value.title()} Workout" if value.lower() not in {"workout", "strength"} else "Strength Workout"


def _load_kg(value: float, unit: str | None) -> float:
    return value * 0.45359237 if unit == "lb" else value


def _set_e1rm_kg(item: WorkoutSet) -> float | None:
    if item.load_value is None or item.reps is None or item.reps < 1 or item.reps > 10:
        return None
    rir = item.rir if item.rir is not None and 0 <= item.rir <= 3 else 0
    return round(_load_kg(item.load_value, item.load_unit) * (1 + (item.reps + rir) / 30), 2)


def _clean_optional(value: str | None) -> str | None:
    cleaned = (value or "").strip()
    return cleaned or None
