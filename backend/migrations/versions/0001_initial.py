"""initial backend schema

Revision ID: 0001_initial
Revises:
Create Date: 2026-06-15
"""

from alembic import op
import sqlalchemy as sa


revision = "0001_initial"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("email", sa.String(length=320), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_table(
        "google_accounts",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("health_user_id", sa.String(length=128), nullable=True),
        sa.Column("legacy_user_id", sa.String(length=128), nullable=True),
        sa.Column("granted_scopes", sa.JSON(), nullable=False),
        sa.Column("encrypted_refresh_token", sa.Text(), nullable=True),
        sa.Column("access_token_expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "status",
            sa.Enum("connected", "disconnected", "errored", name="connectionstatus"),
            nullable=False,
        ),
        sa.Column("connected_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("disconnected_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_token_refresh_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_sync_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_error", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("health_user_id", name="uq_google_accounts_health_user_id"),
        sa.UniqueConstraint("legacy_user_id", name="uq_google_accounts_legacy_user_id"),
    )
    op.create_index(op.f("ix_google_accounts_user_id"), "google_accounts", ["user_id"])
    op.create_table(
        "oauth_states",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("state_hash", sa.String(length=64), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=True),
        sa.Column("redirect_after", sa.Text(), nullable=True),
        sa.Column("scopes", sa.JSON(), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_oauth_states_state_hash"), "oauth_states", ["state_hash"], unique=True)
    op.create_table(
        "raw_health_records",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("google_account_id", sa.String(length=36), nullable=False),
        sa.Column("data_type", sa.String(length=80), nullable=False),
        sa.Column("source_record_id", sa.Text(), nullable=False),
        sa.Column("source_platform", sa.String(length=80), nullable=True),
        sa.Column("source_device", sa.String(length=160), nullable=True),
        sa.Column("start_time", sa.DateTime(timezone=True), nullable=True),
        sa.Column("end_time", sa.DateTime(timezone=True), nullable=True),
        sa.Column("civil_date", sa.Date(), nullable=True),
        sa.Column("raw_json", sa.JSON(), nullable=False),
        sa.Column("content_hash", sa.String(length=64), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["google_account_id"], ["google_accounts.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("google_account_id", "data_type", "source_record_id", name="uq_raw_record"),
    )
    op.create_index(
        "ix_raw_records_user_data_type_date",
        "raw_health_records",
        ["user_id", "data_type", "civil_date"],
    )
    op.create_index(op.f("ix_raw_health_records_google_account_id"), "raw_health_records", ["google_account_id"])
    op.create_index(op.f("ix_raw_health_records_user_id"), "raw_health_records", ["user_id"])
    op.create_table(
        "metric_samples",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("raw_record_id", sa.String(length=36), nullable=True),
        sa.Column("metric", sa.String(length=80), nullable=False),
        sa.Column("observed_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("civil_date", sa.Date(), nullable=True),
        sa.Column("value", sa.Float(), nullable=False),
        sa.Column("unit", sa.String(length=32), nullable=False),
        sa.Column("source_platform", sa.String(length=80), nullable=True),
        sa.Column("source_device", sa.String(length=160), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["raw_record_id"], ["raw_health_records.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("raw_record_id", "metric", "observed_at", name="uq_metric_sample"),
    )
    op.create_index("ix_metric_samples_user_metric_time", "metric_samples", ["user_id", "metric", "observed_at"])
    op.create_index(op.f("ix_metric_samples_user_id"), "metric_samples", ["user_id"])
    op.create_table(
        "metric_intervals",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("raw_record_id", sa.String(length=36), nullable=True),
        sa.Column("metric", sa.String(length=80), nullable=False),
        sa.Column("start_time", sa.DateTime(timezone=True), nullable=False),
        sa.Column("end_time", sa.DateTime(timezone=True), nullable=False),
        sa.Column("civil_date", sa.Date(), nullable=True),
        sa.Column("value", sa.Float(), nullable=False),
        sa.Column("unit", sa.String(length=32), nullable=False),
        sa.Column("source_platform", sa.String(length=80), nullable=True),
        sa.Column("source_device", sa.String(length=160), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["raw_record_id"], ["raw_health_records.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("raw_record_id", "metric", "start_time", "end_time", name="uq_metric_interval"),
    )
    op.create_index("ix_metric_intervals_user_metric_date", "metric_intervals", ["user_id", "metric", "civil_date"])
    op.create_index(op.f("ix_metric_intervals_user_id"), "metric_intervals", ["user_id"])
    op.create_table(
        "sleep_sessions",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("raw_record_id", sa.String(length=36), nullable=True),
        sa.Column("start_time", sa.DateTime(timezone=True), nullable=False),
        sa.Column("end_time", sa.DateTime(timezone=True), nullable=False),
        sa.Column("civil_date", sa.Date(), nullable=True),
        sa.Column("minutes_asleep", sa.Integer(), nullable=True),
        sa.Column("minutes_awake", sa.Integer(), nullable=True),
        sa.Column("minutes_in_sleep_period", sa.Integer(), nullable=True),
        sa.Column("stages_summary", sa.JSON(), nullable=False),
        sa.Column("stages", sa.JSON(), nullable=False),
        sa.Column("is_main_sleep", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["raw_record_id"], ["raw_health_records.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("raw_record_id", name="uq_sleep_session_raw_record"),
    )
    op.create_index(op.f("ix_sleep_sessions_user_id"), "sleep_sessions", ["user_id"])
    op.create_table(
        "workouts",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("raw_record_id", sa.String(length=36), nullable=True),
        sa.Column("workout_type", sa.String(length=120), nullable=True),
        sa.Column("start_time", sa.DateTime(timezone=True), nullable=False),
        sa.Column("end_time", sa.DateTime(timezone=True), nullable=False),
        sa.Column("civil_date", sa.Date(), nullable=True),
        sa.Column("duration_seconds", sa.Integer(), nullable=True),
        sa.Column("raw_summary", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["raw_record_id"], ["raw_health_records.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("raw_record_id", name="uq_workout_raw_record"),
    )
    op.create_index(op.f("ix_workouts_user_id"), "workouts", ["user_id"])
    op.create_table(
        "daily_summaries",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("summary_date", sa.Date(), nullable=False),
        sa.Column("steps", sa.Integer(), nullable=True),
        sa.Column("active_calories", sa.Float(), nullable=True),
        sa.Column("total_calories", sa.Float(), nullable=True),
        sa.Column("distance_meters", sa.Float(), nullable=True),
        sa.Column("resting_heart_rate", sa.Float(), nullable=True),
        sa.Column("heart_rate_variability", sa.Float(), nullable=True),
        sa.Column("oxygen_saturation", sa.Float(), nullable=True),
        sa.Column("respiratory_rate", sa.Float(), nullable=True),
        sa.Column("sleep_minutes", sa.Integer(), nullable=True),
        sa.Column("workout_count", sa.Integer(), nullable=False),
        sa.Column("data_quality", sa.String(length=32), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("user_id", "summary_date", name="uq_daily_summary_user_date"),
    )
    op.create_index(op.f("ix_daily_summaries_summary_date"), "daily_summaries", ["summary_date"])
    op.create_index(op.f("ix_daily_summaries_user_id"), "daily_summaries", ["user_id"])
    op.create_table(
        "sync_cursors",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("google_account_id", sa.String(length=36), nullable=False),
        sa.Column("data_type", sa.String(length=80), nullable=False),
        sa.Column("last_successful_start", sa.Date(), nullable=True),
        sa.Column("last_successful_end", sa.Date(), nullable=True),
        sa.Column(
            "status",
            sa.Enum("pending", "running", "succeeded", "failed", name="syncstatus"),
            nullable=False,
        ),
        sa.Column("last_page_token", sa.Text(), nullable=True),
        sa.Column("last_error", sa.Text(), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["google_account_id"], ["google_accounts.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("google_account_id", "data_type", name="uq_sync_cursor"),
    )
    op.create_index(op.f("ix_sync_cursors_google_account_id"), "sync_cursors", ["google_account_id"])


def downgrade() -> None:
    op.drop_table("sync_cursors")
    op.drop_table("daily_summaries")
    op.drop_table("workouts")
    op.drop_table("sleep_sessions")
    op.drop_table("metric_intervals")
    op.drop_table("metric_samples")
    op.drop_table("raw_health_records")
    op.drop_table("oauth_states")
    op.drop_table("google_accounts")
    op.drop_table("users")
    sa.Enum(name="syncstatus").drop(op.get_bind(), checkfirst=True)
    sa.Enum(name="connectionstatus").drop(op.get_bind(), checkfirst=True)

