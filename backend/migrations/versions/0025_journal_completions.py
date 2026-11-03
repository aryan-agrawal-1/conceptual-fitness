"""Explicit daily check-in completion, synchronized per journal date."""
from alembic import op
import sqlalchemy as sa

revision = "0025_journal_completions"
down_revision = "0024_journal_storage"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "journal_completions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("journal_date", sa.Date(), nullable=False),
        sa.Column("completed", sa.Boolean(), nullable=False),
        sa.Column("first_completed_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("timezone", sa.String(80), nullable=False),
        sa.Column("edited_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("mutation_id", sa.String(36), nullable=False),
        sa.Column("revision", sa.Integer(), nullable=False),
        sa.UniqueConstraint("user_id", "journal_date", name="uq_journal_completion_day"),
    )
    op.create_index("ix_journal_completions_user_revision", "journal_completions", ["user_id", "revision"])


def downgrade() -> None:
    op.drop_table("journal_completions")
