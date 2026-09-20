"""Add profile goals, constraints, and unit preferences."""

from alembic import op
import sqlalchemy as sa


revision = "0020_profile_preferences"
down_revision = "0019_sync_lifecycle"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "user_profiles",
        sa.Column("secondary_goals", sa.JSON(), nullable=False, server_default="[]"),
    )
    op.add_column(
        "user_profiles",
        sa.Column("constraints", sa.JSON(), nullable=False, server_default="{}"),
    )
    op.add_column(
        "user_profiles",
        sa.Column("unit_system", sa.String(length=16), nullable=False, server_default="metric"),
    )


def downgrade() -> None:
    op.drop_column("user_profiles", "unit_system")
    op.drop_column("user_profiles", "constraints")
    op.drop_column("user_profiles", "secondary_goals")
