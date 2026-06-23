"""add onboarding profile fields

Revision ID: 0005_onboarding_profile_fields
Revises: 0004_app_auth_sessions
Create Date: 2026-06-23
"""

from alembic import op
import sqlalchemy as sa


revision = "0005_onboarding_profile_fields"
down_revision = "0004_app_auth_sessions"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("users", sa.Column("first_name", sa.String(length=80), nullable=True))
    op.add_column("users", sa.Column("last_name", sa.String(length=80), nullable=True))

    op.add_column(
        "user_profiles",
        sa.Column("weather_enabled", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.add_column(
        "user_profiles",
        sa.Column("location_permission_status", sa.String(length=32), nullable=True),
    )
    op.add_column(
        "user_profiles",
        sa.Column(
            "height_source_preference",
            sa.String(length=32),
            nullable=False,
            server_default="google",
        ),
    )
    op.add_column(
        "user_profiles",
        sa.Column(
            "weight_source_preference",
            sa.String(length=32),
            nullable=False,
            server_default="google",
        ),
    )
    op.add_column(
        "user_profiles",
        sa.Column("onboarding_completed_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("user_profiles", "onboarding_completed_at")
    op.drop_column("user_profiles", "weight_source_preference")
    op.drop_column("user_profiles", "height_source_preference")
    op.drop_column("user_profiles", "location_permission_status")
    op.drop_column("user_profiles", "weather_enabled")

    op.drop_column("users", "last_name")
    op.drop_column("users", "first_name")
