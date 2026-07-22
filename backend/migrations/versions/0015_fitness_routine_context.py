"""add routine context and exercise favourites

Revision ID: 0015_fitness_context
Revises: 0014_fitness_logging
Create Date: 2026-07-22
"""

from alembic import op
import sqlalchemy as sa


revision = "0015_fitness_context"
down_revision = "0014_fitness_logging"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("workouts", sa.Column("routine_id", sa.String(length=36), nullable=True))
    op.create_index(op.f("ix_workouts_routine_id"), "workouts", ["routine_id"])
    op.add_column("workout_exercises", sa.Column("rest_seconds", sa.Integer(), nullable=True))
    op.create_table(
        "exercise_favorites",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("exercise_id", sa.String(length=36), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["exercise_id"], ["exercise_catalog.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "user_id", "exercise_id", name="uq_exercise_favorite_user_exercise"
        ),
    )
    op.create_index(
        op.f("ix_exercise_favorites_exercise_id"), "exercise_favorites", ["exercise_id"]
    )
    op.create_index(op.f("ix_exercise_favorites_user_id"), "exercise_favorites", ["user_id"])


def downgrade() -> None:
    op.drop_table("exercise_favorites")
    op.drop_column("workout_exercises", "rest_seconds")
    op.drop_index(op.f("ix_workouts_routine_id"), table_name="workouts")
    op.drop_column("workouts", "routine_id")
