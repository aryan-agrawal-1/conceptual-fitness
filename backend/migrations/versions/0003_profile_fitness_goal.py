"""add fitness goal to user profiles

Revision ID: 0003_profile_fitness_goal
Revises: 0002_scores_and_baselines
Create Date: 2026-06-19
"""

from alembic import op
import sqlalchemy as sa


revision = "0003_profile_fitness_goal"
down_revision = "0002_scores_and_baselines"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("user_profiles", sa.Column("fitness_goal", sa.String(length=80), nullable=True))


def downgrade() -> None:
    op.drop_column("user_profiles", "fitness_goal")
