"""production metric storage policy

Revision ID: 0011_metric_storage_policy
Revises: 0010_drop_provider_record_ledger
Create Date: 2026-06-23
"""

from alembic import op


revision = "0011_metric_storage_policy"
down_revision = "0010_drop_provider_record_ledger"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.drop_index("ix_metric_minute_rollups_user_metric_time", table_name="metric_minute_rollups")


def downgrade() -> None:
    op.create_index(
        "ix_metric_minute_rollups_user_metric_time",
        "metric_minute_rollups",
        ["user_id", "metric", "bucket_start"],
    )
