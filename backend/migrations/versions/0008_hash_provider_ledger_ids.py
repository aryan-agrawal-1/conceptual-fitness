"""hash provider ledger source ids

Revision ID: 0008_hash_provider_ledger_ids
Revises: 0007_metric_rollups_and_ledger
Create Date: 2026-06-23
"""

from alembic import op
import sqlalchemy as sa


revision = "0008_hash_provider_ledger_ids"
down_revision = "0007_metric_rollups_and_ledger"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "provider_record_ledger",
        sa.Column("source_record_hash", sa.String(length=64), nullable=True),
    )
    op.execute("update provider_record_ledger set source_record_hash = md5(source_record_id)")
    op.alter_column("provider_record_ledger", "source_record_hash", nullable=False)
    op.drop_constraint("uq_provider_record_ledger", "provider_record_ledger", type_="unique")
    op.drop_column("provider_record_ledger", "source_record_id")
    op.create_unique_constraint(
        "uq_provider_record_ledger",
        "provider_record_ledger",
        ["google_account_id", "data_type", "source_record_hash"],
    )


def downgrade() -> None:
    op.add_column(
        "provider_record_ledger",
        sa.Column("source_record_id", sa.Text(), nullable=True),
    )
    op.execute("update provider_record_ledger set source_record_id = source_record_hash")
    op.alter_column("provider_record_ledger", "source_record_id", nullable=False)
    op.drop_constraint("uq_provider_record_ledger", "provider_record_ledger", type_="unique")
    op.drop_column("provider_record_ledger", "source_record_hash")
    op.create_unique_constraint(
        "uq_provider_record_ledger",
        "provider_record_ledger",
        ["google_account_id", "data_type", "source_record_id"],
    )
