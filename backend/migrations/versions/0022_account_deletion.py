"""Add recoverable account deletion lifecycle."""

from alembic import op
import sqlalchemy as sa


revision = "0022_account_deletion"
down_revision = "0021_sensitive_action_grants"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("users", sa.Column("deletion_requested_at", sa.DateTime(timezone=True)))
    op.add_column("users", sa.Column("deletion_scheduled_for", sa.DateTime(timezone=True)))
    op.create_index(
        op.f("ix_users_deletion_scheduled_for"),
        "users",
        ["deletion_scheduled_for"],
    )


def downgrade() -> None:
    op.drop_index(op.f("ix_users_deletion_scheduled_for"), table_name="users")
    op.drop_column("users", "deletion_scheduled_for")
    op.drop_column("users", "deletion_requested_at")
