"""add metric rollups and provider ledger

Revision ID: 0007_metric_rollups_and_ledger
Revises: 0006_timestamp_sync_cursors
Create Date: 2026-06-23
"""

from alembic import op
import sqlalchemy as sa


revision = "0007_metric_rollups_and_ledger"
down_revision = "0006_timestamp_sync_cursors"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "provider_record_ledger",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("google_account_id", sa.String(length=36), nullable=False),
        sa.Column("data_type", sa.String(length=80), nullable=False),
        sa.Column("source_record_id", sa.Text(), nullable=False),
        sa.Column("content_hash", sa.String(length=64), nullable=False),
        sa.Column("metric", sa.String(length=80), nullable=True),
        sa.Column("value", sa.Float(), nullable=True),
        sa.Column("unit", sa.String(length=32), nullable=True),
        sa.Column("source_platform", sa.String(length=80), nullable=True),
        sa.Column("source_device", sa.String(length=160), nullable=True),
        sa.Column("start_time", sa.DateTime(timezone=True), nullable=True),
        sa.Column("end_time", sa.DateTime(timezone=True), nullable=True),
        sa.Column("civil_date", sa.Date(), nullable=True),
        sa.Column("first_seen_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["google_account_id"], ["google_accounts.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "google_account_id",
            "data_type",
            "source_record_id",
            name="uq_provider_record_ledger",
        ),
    )
    op.create_index(
        "ix_provider_record_ledger_user_data_type_date",
        "provider_record_ledger",
        ["user_id", "data_type", "civil_date"],
    )
    op.create_index(
        op.f("ix_provider_record_ledger_google_account_id"),
        "provider_record_ledger",
        ["google_account_id"],
    )
    op.create_index(op.f("ix_provider_record_ledger_user_id"), "provider_record_ledger", ["user_id"])

    op.create_table(
        "metric_minute_rollups",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("metric", sa.String(length=80), nullable=False),
        sa.Column("bucket_start", sa.DateTime(timezone=True), nullable=False),
        sa.Column("civil_date", sa.Date(), nullable=False),
        sa.Column("avg_value", sa.Float(), nullable=True),
        sa.Column("min_value", sa.Float(), nullable=True),
        sa.Column("max_value", sa.Float(), nullable=True),
        sa.Column("sum_value", sa.Float(), nullable=True),
        sa.Column("sample_count", sa.Integer(), nullable=False),
        sa.Column("unit", sa.String(length=32), nullable=False),
        sa.Column("source_platform", sa.String(length=80), nullable=True),
        sa.Column("source_device", sa.String(length=160), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("user_id", "metric", "bucket_start", name="uq_metric_minute_rollup"),
    )
    op.create_index(
        "ix_metric_minute_rollups_user_metric_date",
        "metric_minute_rollups",
        ["user_id", "metric", "civil_date"],
    )
    op.create_index(
        "ix_metric_minute_rollups_user_metric_time",
        "metric_minute_rollups",
        ["user_id", "metric", "bucket_start"],
    )
    op.create_index(op.f("ix_metric_minute_rollups_user_id"), "metric_minute_rollups", ["user_id"])

    op.create_table(
        "metric_daily_rollups",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("metric", sa.String(length=80), nullable=False),
        sa.Column("civil_date", sa.Date(), nullable=False),
        sa.Column("avg_value", sa.Float(), nullable=True),
        sa.Column("min_value", sa.Float(), nullable=True),
        sa.Column("max_value", sa.Float(), nullable=True),
        sa.Column("sum_value", sa.Float(), nullable=True),
        sa.Column("sample_count", sa.Integer(), nullable=False),
        sa.Column("unit", sa.String(length=32), nullable=False),
        sa.Column("metadata_json", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("user_id", "metric", "civil_date", name="uq_metric_daily_rollup"),
    )
    op.create_index(
        "ix_metric_daily_rollups_user_metric_date",
        "metric_daily_rollups",
        ["user_id", "metric", "civil_date"],
    )
    op.create_index(op.f("ix_metric_daily_rollups_user_id"), "metric_daily_rollups", ["user_id"])


def downgrade() -> None:
    op.drop_table("metric_daily_rollups")
    op.drop_table("metric_minute_rollups")
    op.drop_table("provider_record_ledger")
