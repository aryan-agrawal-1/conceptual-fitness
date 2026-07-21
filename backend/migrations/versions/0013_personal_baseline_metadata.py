"""add personal baseline calculation metadata

Revision ID: 0013_baseline_metadata
Revises: 0012_metric_hourly_rollups
Create Date: 2026-07-21
"""

from alembic import op
import sqlalchemy as sa


revision = "0013_baseline_metadata"
down_revision = "0012_metric_hourly_rollups"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "daily_baselines",
        sa.Column("metadata_json", sa.JSON(), nullable=False, server_default=sa.text("'{}'")),
    )


def downgrade() -> None:
    op.drop_column("daily_baselines", "metadata_json")
