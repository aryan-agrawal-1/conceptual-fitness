"""Bind authentication sessions and sensitive actions to device keys.

Revision ID: 0023_device_key_step_up
Revises: 0022_account_deletion
"""

from alembic import op
import sqlalchemy as sa


revision = "0023_device_key_step_up"
down_revision = "0022_account_deletion"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("oauth_states", sa.Column("device_public_key", sa.String(length=88)))
    op.add_column("oauth_states", sa.Column("source_session_id", sa.String(length=36)))
    op.add_column("app_auth_codes", sa.Column("device_public_key", sa.String(length=88)))
    op.add_column("app_auth_codes", sa.Column("source_session_id", sa.String(length=36)))
    op.add_column("app_sessions", sa.Column("device_public_key", sa.String(length=88)))
    op.add_column("sensitive_action_grants", sa.Column("session_id", sa.String(length=36)))
    op.add_column("sensitive_action_grants", sa.Column("device_public_key", sa.String(length=88)))
    op.add_column("sensitive_action_grants", sa.Column("verified_at", sa.DateTime(timezone=True)))
    with op.batch_alter_table("sensitive_action_grants") as batch_op:
        batch_op.create_foreign_key(
            "fk_sensitive_action_grants_session_id_app_sessions",
            "app_sessions",
            ["session_id"],
            ["id"],
            ondelete="CASCADE",
        )
    op.create_index(
        op.f("ix_sensitive_action_grants_session_id"),
        "sensitive_action_grants",
        ["session_id"],
    )


def downgrade() -> None:
    op.drop_index(op.f("ix_sensitive_action_grants_session_id"), table_name="sensitive_action_grants")
    with op.batch_alter_table("sensitive_action_grants") as batch_op:
        batch_op.drop_constraint(
            "fk_sensitive_action_grants_session_id_app_sessions",
            type_="foreignkey",
        )
    op.drop_column("sensitive_action_grants", "verified_at")
    op.drop_column("sensitive_action_grants", "device_public_key")
    op.drop_column("sensitive_action_grants", "session_id")
    op.drop_column("app_sessions", "device_public_key")
    op.drop_column("app_auth_codes", "source_session_id")
    op.drop_column("app_auth_codes", "device_public_key")
    op.drop_column("oauth_states", "source_session_id")
    op.drop_column("oauth_states", "device_public_key")
