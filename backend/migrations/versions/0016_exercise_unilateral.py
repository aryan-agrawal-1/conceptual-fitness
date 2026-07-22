"""add unilateral exercise semantics

Revision ID: 0016_exercise_unilateral
Revises: 0015_fitness_context
Create Date: 2026-07-22
"""

from alembic import op
import sqlalchemy as sa


revision = "0016_exercise_unilateral"
down_revision = "0015_fitness_context"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "exercise_catalog",
        sa.Column("is_unilateral", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.alter_column("exercise_catalog", "is_unilateral", server_default=None)


def downgrade() -> None:
    op.drop_column("exercise_catalog", "is_unilateral")
