"""slim provider ledger key indexes

Revision ID: 0009_slim_provider_ledger
Revises: 0008_hash_provider_ledger_ids
Create Date: 2026-06-23
"""

from alembic import op
import sqlalchemy as sa


revision = "0009_slim_provider_ledger"
down_revision = "0008_hash_provider_ledger_ids"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.drop_index(op.f("ix_provider_record_ledger_user_id"), table_name="provider_record_ledger")
    op.drop_index(
        op.f("ix_provider_record_ledger_google_account_id"),
        table_name="provider_record_ledger",
    )
    op.drop_constraint("uq_provider_record_ledger", "provider_record_ledger", type_="unique")
    op.drop_constraint("provider_record_ledger_pkey", "provider_record_ledger", type_="primary")
    op.drop_column("provider_record_ledger", "id")
    op.create_primary_key(
        "provider_record_ledger_pkey",
        "provider_record_ledger",
        ["google_account_id", "data_type", "source_record_hash"],
    )


def downgrade() -> None:
    op.add_column(
        "provider_record_ledger",
        sa.Column("id", sa.String(length=36), nullable=True),
    )
    op.execute("update provider_record_ledger set id = gen_random_uuid()::text")
    op.alter_column("provider_record_ledger", "id", nullable=False)
    op.drop_constraint("provider_record_ledger_pkey", "provider_record_ledger", type_="primary")
    op.create_primary_key("provider_record_ledger_pkey", "provider_record_ledger", ["id"])
    op.create_unique_constraint(
        "uq_provider_record_ledger",
        "provider_record_ledger",
        ["google_account_id", "data_type", "source_record_hash"],
    )
    op.create_index(
        op.f("ix_provider_record_ledger_google_account_id"),
        "provider_record_ledger",
        ["google_account_id"],
    )
    op.create_index(op.f("ix_provider_record_ledger_user_id"), "provider_record_ledger", ["user_id"])
