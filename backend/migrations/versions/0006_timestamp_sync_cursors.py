"""add timestamp sync cursor bounds

Revision ID: 0006_timestamp_sync_cursors
Revises: 0005_onboarding_profile_fields
Create Date: 2026-06-23
"""

from alembic import op
import sqlalchemy as sa


revision = "0006_timestamp_sync_cursors"
down_revision = "0005_onboarding_profile_fields"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "sync_cursors",
        sa.Column("last_successful_start_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "sync_cursors",
        sa.Column("last_successful_end_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("sync_cursors", "last_successful_end_at")
    op.drop_column("sync_cursors", "last_successful_start_at")
