"""add canonical workout logging and exercise catalog

Revision ID: 0014_fitness_logging
Revises: 0013_baseline_metadata
Create Date: 2026-07-22
"""

from datetime import UTC, datetime
from uuid import uuid4

from alembic import op
import sqlalchemy as sa


revision = "0014_fitness_logging"
down_revision = "0013_baseline_metadata"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("workouts", sa.Column("client_id", sa.String(length=36), nullable=True))
    op.add_column("workouts", sa.Column("title", sa.String(length=160), nullable=True))
    op.add_column(
        "workouts",
        sa.Column("status", sa.String(length=24), nullable=False, server_default="completed"),
    )
    op.add_column(
        "workouts",
        sa.Column("origin", sa.String(length=24), nullable=False, server_default="wearable"),
    )
    op.add_column(
        "workouts",
        sa.Column("timezone", sa.String(length=80), nullable=False, server_default="UTC"),
    )
    op.add_column("workouts", sa.Column("notes", sa.Text(), nullable=True))
    op.add_column("workouts", sa.Column("session_rpe", sa.Float(), nullable=True))
    op.add_column(
        "workouts", sa.Column("revision", sa.Integer(), nullable=False, server_default="1")
    )
    op.add_column(
        "workouts",
        sa.Column("is_user_edited", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.add_column(
        "workouts",
        sa.Column("awaiting_wearable", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.add_column("workouts", sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("workouts", sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column(
        "workouts",
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
    )
    op.create_unique_constraint("uq_workout_user_client_id", "workouts", ["user_id", "client_id"])
    op.create_index(
        "ix_workouts_user_status_start", "workouts", ["user_id", "status", "start_time"]
    )
    op.execute("UPDATE workouts SET completed_at = end_time, updated_at = created_at")

    op.create_table(
        "exercise_catalog",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=True),
        sa.Column("external_id", sa.String(length=180), nullable=True),
        sa.Column("source", sa.String(length=40), nullable=False),
        sa.Column("source_version", sa.String(length=64), nullable=True),
        sa.Column("name", sa.String(length=180), nullable=False),
        sa.Column("aliases", sa.JSON(), nullable=False),
        sa.Column("instructions", sa.JSON(), nullable=False),
        sa.Column("media", sa.JSON(), nullable=False),
        sa.Column("force", sa.String(length=32), nullable=True),
        sa.Column("level", sa.String(length=32), nullable=True),
        sa.Column("mechanic", sa.String(length=32), nullable=True),
        sa.Column("equipment", sa.String(length=80), nullable=True),
        sa.Column("category", sa.String(length=80), nullable=True),
        sa.Column("movement_pattern", sa.String(length=80), nullable=True),
        sa.Column("primary_muscles", sa.JSON(), nullable=False),
        sa.Column("secondary_muscles", sa.JSON(), nullable=False),
        sa.Column("measurement_schema", sa.String(length=40), nullable=False),
        sa.Column("default_rest_seconds", sa.Integer(), nullable=True),
        sa.Column("is_curated", sa.Boolean(), nullable=False),
        sa.Column("is_archived", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("source", "external_id", name="uq_exercise_catalog_source_external"),
    )
    op.create_index(
        "ix_exercise_catalog_user_name", "exercise_catalog", ["user_id", "name"]
    )
    op.create_index(op.f("ix_exercise_catalog_user_id"), "exercise_catalog", ["user_id"])

    op.create_table(
        "workout_routines",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("name", sa.String(length=160), nullable=False),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("scheduled_weekdays", sa.JSON(), nullable=False),
        sa.Column("is_favorite", sa.Boolean(), nullable=False),
        sa.Column("is_archived", sa.Boolean(), nullable=False),
        sa.Column("last_performed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_workout_routines_user_archived", "workout_routines", ["user_id", "is_archived"]
    )
    op.create_index(op.f("ix_workout_routines_user_id"), "workout_routines", ["user_id"])

    op.create_table(
        "workout_sources",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("workout_id", sa.String(length=36), nullable=False),
        sa.Column("raw_record_id", sa.String(length=36), nullable=True),
        sa.Column("provider", sa.String(length=40), nullable=False),
        sa.Column("source_record_id", sa.Text(), nullable=False),
        sa.Column("source_platform", sa.String(length=80), nullable=True),
        sa.Column("source_device", sa.String(length=160), nullable=True),
        sa.Column("start_time", sa.DateTime(timezone=True), nullable=True),
        sa.Column("end_time", sa.DateTime(timezone=True), nullable=True),
        sa.Column("payload", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["raw_record_id"], ["raw_health_records.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["workout_id"], ["workouts.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("raw_record_id", name="uq_workout_source_raw_record"),
        sa.UniqueConstraint(
            "user_id", "provider", "source_record_id", name="uq_workout_source_identity"
        ),
    )
    op.create_index(op.f("ix_workout_sources_user_id"), "workout_sources", ["user_id"])
    op.create_index(op.f("ix_workout_sources_workout_id"), "workout_sources", ["workout_id"])

    op.create_table(
        "workout_exercises",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("workout_id", sa.String(length=36), nullable=False),
        sa.Column("exercise_id", sa.String(length=36), nullable=True),
        sa.Column("order_index", sa.Integer(), nullable=False),
        sa.Column("group_id", sa.String(length=36), nullable=True),
        sa.Column("name_snapshot", sa.String(length=180), nullable=False),
        sa.Column("measurement_schema", sa.String(length=40), nullable=False),
        sa.Column("primary_muscles", sa.JSON(), nullable=False),
        sa.Column("secondary_muscles", sa.JSON(), nullable=False),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["exercise_id"], ["exercise_catalog.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["workout_id"], ["workouts.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("workout_id", "order_index", name="uq_workout_exercise_order"),
    )
    op.create_index(
        "ix_workout_exercises_workout_order", "workout_exercises", ["workout_id", "order_index"]
    )
    op.create_index(op.f("ix_workout_exercises_exercise_id"), "workout_exercises", ["exercise_id"])

    op.create_table(
        "routine_exercises",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("routine_id", sa.String(length=36), nullable=False),
        sa.Column("exercise_id", sa.String(length=36), nullable=True),
        sa.Column("order_index", sa.Integer(), nullable=False),
        sa.Column("group_id", sa.String(length=36), nullable=True),
        sa.Column("name_snapshot", sa.String(length=180), nullable=False),
        sa.Column("measurement_schema", sa.String(length=40), nullable=False),
        sa.Column("target_sets", sa.Integer(), nullable=True),
        sa.Column("target_reps_min", sa.Integer(), nullable=True),
        sa.Column("target_reps_max", sa.Integer(), nullable=True),
        sa.Column("target_load_value", sa.Float(), nullable=True),
        sa.Column("target_load_unit", sa.String(length=16), nullable=True),
        sa.Column("target_duration_seconds", sa.Integer(), nullable=True),
        sa.Column("target_distance_meters", sa.Float(), nullable=True),
        sa.Column("target_rir", sa.Float(), nullable=True),
        sa.Column("rest_seconds", sa.Integer(), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["exercise_id"], ["exercise_catalog.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["routine_id"], ["workout_routines.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("routine_id", "order_index", name="uq_routine_exercise_order"),
    )
    op.create_index(op.f("ix_routine_exercises_exercise_id"), "routine_exercises", ["exercise_id"])
    op.create_index(op.f("ix_routine_exercises_routine_id"), "routine_exercises", ["routine_id"])

    op.create_table(
        "workout_sets",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("workout_exercise_id", sa.String(length=36), nullable=False),
        sa.Column("order_index", sa.Integer(), nullable=False),
        sa.Column("set_type", sa.String(length=24), nullable=False),
        sa.Column("status", sa.String(length=24), nullable=False),
        sa.Column("drop_group_id", sa.String(length=36), nullable=True),
        sa.Column("reps", sa.Integer(), nullable=True),
        sa.Column("load_value", sa.Float(), nullable=True),
        sa.Column("load_unit", sa.String(length=16), nullable=True),
        sa.Column("load_per_implement", sa.Float(), nullable=True),
        sa.Column("implement_count", sa.Integer(), nullable=True),
        sa.Column("side_count", sa.Integer(), nullable=True),
        sa.Column("duration_seconds", sa.Integer(), nullable=True),
        sa.Column("distance_meters", sa.Float(), nullable=True),
        sa.Column("assistance_kg", sa.Float(), nullable=True),
        sa.Column("added_load_kg", sa.Float(), nullable=True),
        sa.Column("rir", sa.Float(), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["workout_exercise_id"], ["workout_exercises.id"], ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "workout_exercise_id", "order_index", name="uq_workout_set_order"
        ),
    )
    op.create_index(
        op.f("ix_workout_sets_workout_exercise_id"),
        "workout_sets",
        ["workout_exercise_id"],
    )

    op.create_table(
        "workout_match_rejections",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("left_workout_id", sa.String(length=36), nullable=False),
        sa.Column("right_workout_id", sa.String(length=36), nullable=False),
        sa.Column("reason", sa.String(length=120), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["left_workout_id"], ["workouts.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["right_workout_id"], ["workouts.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "user_id", "left_workout_id", "right_workout_id", name="uq_workout_match_rejection"
        ),
    )
    op.create_index(
        op.f("ix_workout_match_rejections_user_id"), "workout_match_rejections", ["user_id"]
    )

    _backfill_workout_sources()


def _backfill_workout_sources() -> None:
    bind = op.get_bind()
    rows = bind.execute(
        sa.text(
            """
            SELECT w.id AS workout_id, w.user_id, r.id AS raw_record_id,
                   r.source_record_id, r.source_platform, r.source_device,
                   r.start_time, r.end_time, r.raw_json
            FROM workouts w
            JOIN raw_health_records r ON r.id = w.raw_record_id
            """
        )
    ).mappings()
    now = datetime.now(UTC)
    source_table = sa.table(
        "workout_sources",
        sa.column("id", sa.String()),
        sa.column("user_id", sa.String()),
        sa.column("workout_id", sa.String()),
        sa.column("raw_record_id", sa.String()),
        sa.column("provider", sa.String()),
        sa.column("source_record_id", sa.Text()),
        sa.column("source_platform", sa.String()),
        sa.column("source_device", sa.String()),
        sa.column("start_time", sa.DateTime(timezone=True)),
        sa.column("end_time", sa.DateTime(timezone=True)),
        sa.column("payload", sa.JSON()),
        sa.column("created_at", sa.DateTime(timezone=True)),
        sa.column("updated_at", sa.DateTime(timezone=True)),
    )
    for row in rows:
        bind.execute(
            source_table.insert().values(
                id=str(uuid4()),
                user_id=row["user_id"],
                workout_id=row["workout_id"],
                raw_record_id=row["raw_record_id"],
                provider="google_health",
                source_record_id=row["source_record_id"],
                source_platform=row["source_platform"],
                source_device=row["source_device"],
                start_time=row["start_time"],
                end_time=row["end_time"],
                payload=row["raw_json"] or {},
                created_at=now,
                updated_at=now,
            )
        )


def downgrade() -> None:
    op.drop_table("workout_match_rejections")
    op.drop_table("workout_sets")
    op.drop_table("routine_exercises")
    op.drop_table("workout_exercises")
    op.drop_table("workout_sources")
    op.drop_table("workout_routines")
    op.drop_table("exercise_catalog")
    op.drop_index("ix_workouts_user_status_start", table_name="workouts")
    op.drop_constraint("uq_workout_user_client_id", "workouts", type_="unique")
    for column in (
        "updated_at",
        "deleted_at",
        "completed_at",
        "awaiting_wearable",
        "is_user_edited",
        "revision",
        "session_rpe",
        "notes",
        "timezone",
        "origin",
        "status",
        "title",
        "client_id",
    ):
        op.drop_column("workouts", column)
