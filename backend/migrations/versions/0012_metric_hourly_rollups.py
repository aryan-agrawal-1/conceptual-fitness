"""add metric hourly rollups

Revision ID: 0012_metric_hourly_rollups
Revises: 0011_metric_storage_policy
Create Date: 2026-07-02
"""

from alembic import op
import sqlalchemy as sa


revision = "0012_metric_hourly_rollups"
down_revision = "0011_metric_storage_policy"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "metric_hourly_rollups",
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
        sa.UniqueConstraint("user_id", "metric", "bucket_start", name="uq_metric_hourly_rollup"),
    )
    op.create_index(
        "ix_metric_hourly_rollups_user_metric_date",
        "metric_hourly_rollups",
        ["user_id", "metric", "civil_date"],
    )
    op.create_index(op.f("ix_metric_hourly_rollups_user_id"), "metric_hourly_rollups", ["user_id"])


def downgrade() -> None:
    op.drop_table("metric_hourly_rollups")
