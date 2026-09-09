"""track historical backfill ranges

Revision ID: 0017_historical_backfills
Revises: 0016_exercise_unilateral
Create Date: 2026-09-01
"""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = "0017_historical_backfills"
down_revision = "0016_exercise_unilateral"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "historical_backfills",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("google_account_id", sa.String(length=36), nullable=False),
        sa.Column("data_type", sa.String(length=80), nullable=False),
        sa.Column("range_start", sa.Date(), nullable=False),
        sa.Column("range_end", sa.Date(), nullable=False),
        sa.Column(
            "status",
            postgresql.ENUM(
                "pending", "running", "succeeded", "failed", name="syncstatus", create_type=False
            ),
            nullable=False,
        ),
        sa.Column("last_error", sa.Text(), nullable=True),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["google_account_id"], ["google_accounts.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "google_account_id",
            "data_type",
            "range_start",
            "range_end",
            name="uq_historical_backfill_range",
        ),
    )
    op.create_index(
        op.f("ix_historical_backfills_google_account_id"),
        "historical_backfills",
        ["google_account_id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(
        op.f("ix_historical_backfills_google_account_id"),
        table_name="historical_backfills",
    )
    op.drop_table("historical_backfills")
