from __future__ import annotations

import enum
import json
from dataclasses import dataclass
from datetime import date, datetime
from tempfile import SpooledTemporaryFile
from typing import BinaryIO, Callable
from zipfile import ZIP_DEFLATED, ZipFile

from sqlalchemy import inspect, select
from sqlalchemy.orm import Session

from app.core.security import utcnow
from app.models import (
    DailyBaseline,
    DailyContext,
    DailyScore,
    DailySummary,
    ExerciseCatalogItem,
    ExerciseFavorite,
    GoogleAccount,
    HistoricalBackfill,
    MetricDailyRollup,
    MetricHourlyRollup,
    MetricInterval,
    MetricMinuteRollup,
    MetricSample,
    RawHealthRecord,
    RoutineExercise,
    SleepSession,
    StrainTarget,
    SyncCursor,
    User,
    UserProfile,
    Workout,
    WorkoutExercise,
    WorkoutMatchRejection,
    WorkoutRoutine,
    WorkoutSet,
    WorkoutSource,
)


EXPORT_SCHEMA_VERSION = "1.0"
EXPORT_CATEGORIES = {"health_and_workouts", "journal", "derived_insights", "personalization"}


@dataclass(frozen=True)
class TableExport:
    model: type
    statement: Callable[[str], object]
    excluded: frozenset[str] = frozenset()


def build_account_export(
    session: Session,
    *,
    user_id: str,
    categories: set[str],
    local_insights: list[dict[str, object]],
) -> BinaryIO:
    if not categories or not categories <= EXPORT_CATEGORIES:
        raise ValueError("At least one supported export category is required")

    generated_at = utcnow()
    archive = SpooledTemporaryFile(max_size=10 * 1024 * 1024)
    files: dict[str, dict[str, object]] = {}
    with ZipFile(archive, "w", compression=ZIP_DEFLATED) as output:
        for category in sorted(categories):
            filename = f"{category}.json"
            counts = write_category(
                output,
                filename=filename,
                category=category,
                specs=category_specs(category),
                session=session,
                user_id=user_id,
                local_insights=local_insights if category == "derived_insights" else [],
            )
            files[filename] = {"category": category, "record_counts": counts}

        output.writestr(
            "manifest.json",
            json.dumps(
                {
                    "schema_version": EXPORT_SCHEMA_VERSION,
                    "generated_at": generated_at,
                    "selected_categories": sorted(categories),
                    "files": files,
                },
                default=json_default,
                indent=2,
                sort_keys=True,
            ),
        )
    archive.seek(0)
    return archive


def write_category(
    output: ZipFile,
    *,
    filename: str,
    category: str,
    specs: tuple[TableExport, ...],
    session: Session,
    user_id: str,
    local_insights: list[dict[str, object]],
) -> dict[str, int]:
    counts: dict[str, int] = {}
    with output.open(filename, "w") as target:
        target.write(
            json.dumps(
                {"schema_version": EXPORT_SCHEMA_VERSION, "category": category},
                sort_keys=True,
            )[:-1].encode()
        )
        target.write(b',"tables":{')
        first_table = True
        for spec in specs:
            if not first_table:
                target.write(b",")
            first_table = False
            table_name = spec.model.__tablename__
            target.write(json.dumps(table_name).encode() + b":[")
            count = 0
            for row in session.scalars(spec.statement(user_id).execution_options(yield_per=500)):
                if count:
                    target.write(b",")
                target.write(json.dumps(row_payload(row, spec.excluded), default=json_default).encode())
                count += 1
            target.write(b"]")
            counts[table_name] = count

        if local_insights:
            if not first_table:
                target.write(b",")
            target.write(b'"client_daily_insights":')
            target.write(json.dumps(local_insights, default=json_default).encode())
            counts["client_daily_insights"] = len(local_insights)
        target.write(b"}}")
    return counts


def row_payload(row, excluded: frozenset[str]) -> dict[str, object]:
    return {
        column.key: getattr(row, column.key)
        for column in inspect(type(row)).columns
        if column.key not in excluded
    }


def json_default(value):
    if isinstance(value, (date, datetime)):
        return value.isoformat()
    if isinstance(value, enum.Enum):
        return value.value
    raise TypeError(f"Unsupported export value: {type(value).__name__}")


def by_user(model):
    return lambda user_id: select(model).where(model.user_id == user_id).order_by(model.id)


def category_specs(category: str) -> tuple[TableExport, ...]:
    if category == "personalization":
        return (
            TableExport(User, lambda user_id: select(User).where(User.id == user_id)),
            TableExport(UserProfile, by_user(UserProfile)),
            TableExport(
                GoogleAccount,
                by_user(GoogleAccount),
                frozenset({"encrypted_refresh_token", "last_error"}),
            ),
            TableExport(
                SyncCursor,
                lambda user_id: select(SyncCursor)
                .join(GoogleAccount, SyncCursor.google_account_id == GoogleAccount.id)
                .where(GoogleAccount.user_id == user_id)
                .order_by(SyncCursor.id),
                frozenset({"last_page_token", "last_error"}),
            ),
            TableExport(
                HistoricalBackfill,
                lambda user_id: select(HistoricalBackfill)
                .join(GoogleAccount, HistoricalBackfill.google_account_id == GoogleAccount.id)
                .where(GoogleAccount.user_id == user_id)
                .order_by(HistoricalBackfill.id),
                frozenset({"last_page_token", "last_error"}),
            ),
        )
    if category == "journal":
        return (TableExport(DailyContext, by_user(DailyContext)),)
    if category == "derived_insights":
        return tuple(
            TableExport(model, by_user(model))
            for model in (DailySummary, DailyBaseline, DailyScore, StrainTarget)
        )
    return (
        *(TableExport(model, by_user(model)) for model in (
            RawHealthRecord,
            MetricSample,
            MetricInterval,
            MetricMinuteRollup,
            MetricHourlyRollup,
            MetricDailyRollup,
            SleepSession,
            Workout,
            WorkoutSource,
            ExerciseFavorite,
            WorkoutRoutine,
            WorkoutMatchRejection,
        )),
        TableExport(
            WorkoutExercise,
            lambda user_id: select(WorkoutExercise)
            .join(Workout, WorkoutExercise.workout_id == Workout.id)
            .where(Workout.user_id == user_id)
            .order_by(WorkoutExercise.id),
        ),
        TableExport(
            WorkoutSet,
            lambda user_id: select(WorkoutSet)
            .join(WorkoutExercise, WorkoutSet.workout_exercise_id == WorkoutExercise.id)
            .join(Workout, WorkoutExercise.workout_id == Workout.id)
            .where(Workout.user_id == user_id)
            .order_by(WorkoutSet.id),
        ),
        TableExport(ExerciseCatalogItem, by_user(ExerciseCatalogItem)),
        TableExport(
            RoutineExercise,
            lambda user_id: select(RoutineExercise)
            .join(WorkoutRoutine, RoutineExercise.routine_id == WorkoutRoutine.id)
            .where(WorkoutRoutine.user_id == user_id)
            .order_by(RoutineExercise.id),
        ),
    )
