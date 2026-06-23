"""drop provider record ledger

Revision ID: 0010_drop_provider_record_ledger
Revises: 0009_slim_provider_ledger
Create Date: 2026-06-23
"""

from alembic import op
import sqlalchemy as sa


revision = "0010_drop_provider_record_ledger"
down_revision = "0009_slim_provider_ledger"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.drop_table("provider_record_ledger")


def downgrade() -> None:
    op.create_table(
        "provider_record_ledger",
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("google_account_id", sa.String(length=36), nullable=False),
        sa.Column("data_type", sa.String(length=80), nullable=False),
        sa.Column("source_record_hash", sa.String(length=64), nullable=False),
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
        sa.PrimaryKeyConstraint(
            "google_account_id",
            "data_type",
            "source_record_hash",
            name="provider_record_ledger_pkey",
        ),
    )
    op.create_index(
        "ix_provider_record_ledger_user_data_type_date",
        "provider_record_ledger",
        ["user_id", "data_type", "civil_date"],
    )
