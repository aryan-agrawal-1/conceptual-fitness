"""add first-party app auth sessions

Revision ID: 0004_app_auth_sessions
Revises: 0003_profile_fitness_goal
Create Date: 2026-06-22
"""

from alembic import op
import sqlalchemy as sa


revision = "0004_app_auth_sessions"
down_revision = "0003_profile_fitness_goal"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("oauth_states", sa.Column("device_id_hash", sa.String(length=64), nullable=True))

    op.create_table(
        "app_sessions",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("device_id_hash", sa.String(length=64), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_used_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("user_agent", sa.String(length=256), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_app_sessions_device_id_hash"), "app_sessions", ["device_id_hash"])
    op.create_index(op.f("ix_app_sessions_expires_at"), "app_sessions", ["expires_at"])
    op.create_index(op.f("ix_app_sessions_user_id"), "app_sessions", ["user_id"])
    op.create_index("ix_app_sessions_user_active", "app_sessions", ["user_id", "revoked_at"])

    op.create_table(
        "app_access_tokens",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("session_id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("token_hash", sa.String(length=64), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["session_id"], ["app_sessions.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_app_access_tokens_expires_at"), "app_access_tokens", ["expires_at"])
    op.create_index(op.f("ix_app_access_tokens_session_id"), "app_access_tokens", ["session_id"])
    op.create_index(op.f("ix_app_access_tokens_token_hash"), "app_access_tokens", ["token_hash"], unique=True)
    op.create_index(op.f("ix_app_access_tokens_user_id"), "app_access_tokens", ["user_id"])

    op.create_table(
        "app_refresh_tokens",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("session_id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("token_hash", sa.String(length=64), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("used_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["session_id"], ["app_sessions.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_app_refresh_tokens_expires_at"), "app_refresh_tokens", ["expires_at"])
    op.create_index(op.f("ix_app_refresh_tokens_session_id"), "app_refresh_tokens", ["session_id"])
    op.create_index(op.f("ix_app_refresh_tokens_token_hash"), "app_refresh_tokens", ["token_hash"], unique=True)
    op.create_index(op.f("ix_app_refresh_tokens_user_id"), "app_refresh_tokens", ["user_id"])

    op.create_table(
        "app_auth_codes",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("code_hash", sa.String(length=64), nullable=False),
        sa.Column("device_id_hash", sa.String(length=64), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_app_auth_codes_code_hash"), "app_auth_codes", ["code_hash"], unique=True)
    op.create_index(op.f("ix_app_auth_codes_device_id_hash"), "app_auth_codes", ["device_id_hash"])
    op.create_index(op.f("ix_app_auth_codes_expires_at"), "app_auth_codes", ["expires_at"])
    op.create_index(op.f("ix_app_auth_codes_user_id"), "app_auth_codes", ["user_id"])


def downgrade() -> None:
    op.drop_index(op.f("ix_app_auth_codes_user_id"), table_name="app_auth_codes")
    op.drop_index(op.f("ix_app_auth_codes_expires_at"), table_name="app_auth_codes")
    op.drop_index(op.f("ix_app_auth_codes_device_id_hash"), table_name="app_auth_codes")
    op.drop_index(op.f("ix_app_auth_codes_code_hash"), table_name="app_auth_codes")
    op.drop_table("app_auth_codes")

    op.drop_index(op.f("ix_app_refresh_tokens_user_id"), table_name="app_refresh_tokens")
    op.drop_index(op.f("ix_app_refresh_tokens_token_hash"), table_name="app_refresh_tokens")
    op.drop_index(op.f("ix_app_refresh_tokens_session_id"), table_name="app_refresh_tokens")
    op.drop_index(op.f("ix_app_refresh_tokens_expires_at"), table_name="app_refresh_tokens")
    op.drop_table("app_refresh_tokens")

    op.drop_index(op.f("ix_app_access_tokens_user_id"), table_name="app_access_tokens")
    op.drop_index(op.f("ix_app_access_tokens_token_hash"), table_name="app_access_tokens")
    op.drop_index(op.f("ix_app_access_tokens_session_id"), table_name="app_access_tokens")
    op.drop_index(op.f("ix_app_access_tokens_expires_at"), table_name="app_access_tokens")
    op.drop_table("app_access_tokens")

    op.drop_index("ix_app_sessions_user_active", table_name="app_sessions")
    op.drop_index(op.f("ix_app_sessions_user_id"), table_name="app_sessions")
    op.drop_index(op.f("ix_app_sessions_expires_at"), table_name="app_sessions")
    op.drop_index(op.f("ix_app_sessions_device_id_hash"), table_name="app_sessions")
    op.drop_table("app_sessions")

    op.drop_column("oauth_states", "device_id_hash")
