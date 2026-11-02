"""Durable journal responses, per-key preferences and analysis invalidation."""
from alembic import op
import sqlalchemy as sa

revision = "0024_journal_storage"
down_revision = "0023_device_key_step_up"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "journal_states",
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("revision", sa.Integer(), nullable=False),
        sa.Column("analysis_revision", sa.Integer(), nullable=False),
        sa.Column("analysis_dirty_from", sa.Date()),
    )
    op.create_table(
        "journal_entries",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("journal_date", sa.Date(), nullable=False),
        sa.Column("behaviour_id", sa.String(80), nullable=False),
        sa.Column("edited_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("mutation_id", sa.String(36), nullable=False),
        sa.Column("deleted", sa.Boolean(), nullable=False),
        sa.Column("response", sa.JSON()), sa.Column("normalized", sa.JSON()),
        sa.Column("revision", sa.Integer(), nullable=False),
        sa.UniqueConstraint("user_id", "journal_date", "behaviour_id", name="uq_journal_entry_day_item"),
    )
    op.create_index("ix_journal_entries_user_revision", "journal_entries", ["user_id", "revision"])
    op.create_table(
        "journal_preferences",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("key", sa.String(100), nullable=False), sa.Column("value", sa.Boolean(), nullable=False),
        sa.Column("edited_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("mutation_id", sa.String(36), nullable=False),
        sa.Column("revision", sa.Integer(), nullable=False),
        sa.UniqueConstraint("user_id", "key", name="uq_journal_preference_key"),
    )
    op.create_index("ix_journal_preferences_user_revision", "journal_preferences", ["user_id", "revision"])


def downgrade() -> None:
    op.drop_table("journal_preferences")
    op.drop_table("journal_entries")
    op.drop_table("journal_states")
