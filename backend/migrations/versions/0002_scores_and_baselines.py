"""add score and baseline tables

Revision ID: 0002_scores_and_baselines
Revises: 0001_initial
Create Date: 2026-06-18
"""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = "0002_scores_and_baselines"
down_revision = "0001_initial"
branch_labels = None
depends_on = None


score_status = sa.Enum(
    "waiting_for_sleep",
    "in_progress",
    "scored",
    "stale",
    "missing_data",
    name="scorestatus",
)

score_status_column = postgresql.ENUM(
    "waiting_for_sleep",
    "in_progress",
    "scored",
    "stale",
    "missing_data",
    name="scorestatus",
    create_type=False,
)


def upgrade() -> None:
    score_status.create(op.get_bind(), checkfirst=True)
    op.create_table(
        "user_profiles",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("timezone", sa.String(length=80), nullable=False),
        sa.Column("date_of_birth", sa.Date(), nullable=True),
        sa.Column("birth_year", sa.Integer(), nullable=True),
        sa.Column("sex", sa.String(length=32), nullable=True),
        sa.Column("height_cm", sa.Float(), nullable=True),
        sa.Column("weight_kg", sa.Float(), nullable=True),
        sa.Column("sleep_target_minutes", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("user_id", name="uq_user_profiles_user_id"),
    )
    op.create_index(op.f("ix_user_profiles_user_id"), "user_profiles", ["user_id"])

    op.create_table(
        "daily_baselines",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("baseline_date", sa.Date(), nullable=False),
        sa.Column("metric", sa.String(length=80), nullable=False),
        sa.Column("algorithm_version", sa.String(length=40), nullable=False),
        sa.Column("window_days", sa.Integer(), nullable=False),
        sa.Column("valid_day_count", sa.Integer(), nullable=False),
        sa.Column("mean_value", sa.Float(), nullable=True),
        sa.Column("median_value", sa.Float(), nullable=True),
        sa.Column("spread_value", sa.Float(), nullable=True),
        sa.Column("lower_bound", sa.Float(), nullable=True),
        sa.Column("upper_bound", sa.Float(), nullable=True),
        sa.Column("confidence_phase", sa.String(length=32), nullable=False),
        sa.Column("included_dates", sa.JSON(), nullable=False),
        sa.Column("exclusions", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "user_id",
            "baseline_date",
            "metric",
            "algorithm_version",
            name="uq_daily_baseline_user_date_metric_version",
        ),
    )
    op.create_index(op.f("ix_daily_baselines_baseline_date"), "daily_baselines", ["baseline_date"])
    op.create_index("ix_daily_baselines_user_metric_date", "daily_baselines", ["user_id", "metric", "baseline_date"])
    op.create_index(op.f("ix_daily_baselines_user_id"), "daily_baselines", ["user_id"])

    op.create_table(
        "daily_scores",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("score_date", sa.Date(), nullable=False),
        sa.Column("score_type", sa.String(length=40), nullable=False),
        sa.Column("algorithm_version", sa.String(length=40), nullable=False),
        sa.Column("value", sa.Float(), nullable=True),
        sa.Column("value_unit", sa.String(length=32), nullable=False),
        sa.Column("status", score_status_column, nullable=False),
        sa.Column("confidence_phase", sa.String(length=32), nullable=False),
        sa.Column("data_quality", sa.String(length=32), nullable=False),
        sa.Column("components", sa.JSON(), nullable=False),
        sa.Column("inputs", sa.JSON(), nullable=False),
        sa.Column("reasons", sa.JSON(), nullable=False),
        sa.Column("computed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "user_id",
            "score_date",
            "score_type",
            "algorithm_version",
            name="uq_daily_score_user_date_type_version",
        ),
    )
    op.create_index(op.f("ix_daily_scores_score_date"), "daily_scores", ["score_date"])
    op.create_index("ix_daily_scores_user_type_date", "daily_scores", ["user_id", "score_type", "score_date"])
    op.create_index(op.f("ix_daily_scores_user_id"), "daily_scores", ["user_id"])

    op.create_table(
        "strain_targets",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("week_start_date", sa.Date(), nullable=False),
        sa.Column("algorithm_version", sa.String(length=40), nullable=False),
        sa.Column("target_load_points", sa.Float(), nullable=True),
        sa.Column("chronic_load_points", sa.Float(), nullable=True),
        sa.Column("acute_load_points", sa.Float(), nullable=True),
        sa.Column("progress_load_points", sa.Float(), nullable=False),
        sa.Column("progress_ratio", sa.Float(), nullable=True),
        sa.Column("load_band", sa.String(length=32), nullable=False),
        sa.Column("confidence_phase", sa.String(length=32), nullable=False),
        sa.Column("components", sa.JSON(), nullable=False),
        sa.Column("inputs", sa.JSON(), nullable=False),
        sa.Column("computed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "user_id",
            "week_start_date",
            "algorithm_version",
            name="uq_strain_target_user_week_version",
        ),
    )
    op.create_index(op.f("ix_strain_targets_user_id"), "strain_targets", ["user_id"])
    op.create_index("ix_strain_targets_user_week", "strain_targets", ["user_id", "week_start_date"])
    op.create_index(op.f("ix_strain_targets_week_start_date"), "strain_targets", ["week_start_date"])

    op.create_table(
        "daily_contexts",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("context_date", sa.Date(), nullable=False),
        sa.Column("context_type", sa.String(length=80), nullable=False),
        sa.Column("source", sa.String(length=32), nullable=False),
        sa.Column("severity", sa.String(length=32), nullable=True),
        sa.Column("value", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_daily_contexts_context_date"), "daily_contexts", ["context_date"])
    op.create_index("ix_daily_contexts_user_date_type", "daily_contexts", ["user_id", "context_date", "context_type"])
    op.create_index(op.f("ix_daily_contexts_user_id"), "daily_contexts", ["user_id"])


def downgrade() -> None:
    op.drop_table("daily_contexts")
    op.drop_table("strain_targets")
    op.drop_table("daily_scores")
    op.drop_table("daily_baselines")
    op.drop_table("user_profiles")
    score_status.drop(op.get_bind(), checkfirst=True)
