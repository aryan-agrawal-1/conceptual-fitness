"""Add purpose-bound sensitive action grants.

Revision ID: 0021_sensitive_action_grants
Revises: 0020_profile_preferences
"""

from alembic import op
import sqlalchemy as sa


revision = "0021_sensitive_action_grants"
down_revision = "0020_profile_preferences"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("oauth_states", sa.Column("sensitive_action", sa.String(length=32), nullable=True))
    op.create_table(
        "sensitive_action_grants",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("device_id_hash", sa.String(length=64), nullable=False),
        sa.Column("purpose", sa.String(length=32), nullable=False),
        sa.Column("token_hash", sa.String(length=64), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    for column in ("user_id", "device_id_hash", "purpose", "expires_at"):
        op.create_index(op.f(f"ix_sensitive_action_grants_{column}"), "sensitive_action_grants", [column])
    op.create_index(
        op.f("ix_sensitive_action_grants_token_hash"),
        "sensitive_action_grants",
        ["token_hash"],
        unique=True,
    )


def downgrade() -> None:
    for column in ("token_hash", "expires_at", "purpose", "device_id_hash", "user_id"):
        op.drop_index(op.f(f"ix_sensitive_action_grants_{column}"), table_name="sensitive_action_grants")
    op.drop_table("sensitive_action_grants")
    op.drop_column("oauth_states", "sensitive_action")
