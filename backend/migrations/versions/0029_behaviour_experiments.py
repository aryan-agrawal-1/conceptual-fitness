from alembic import op
import sqlalchemy as sa

revision = "0029_behaviour_experiments"
down_revision = "0028_behaviour_pattern_views"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "behaviour_experiments",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("behaviour_id", sa.String(40), nullable=False),
        sa.Column("input_id", sa.String(80), nullable=False),
        sa.Column("pair_id", sa.String(120), nullable=False),
        sa.Column("outcome_id", sa.String(80), nullable=False),
        sa.Column("stratum", sa.String(24), nullable=False),
        sa.Column("status", sa.String(24), nullable=False),
        sa.Column("start_date", sa.Date(), nullable=False),
        sa.Column("end_date", sa.Date(), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("stopped_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_behaviour_experiments_user_started", "behaviour_experiments", ["user_id", "started_at"])


def downgrade() -> None:
    op.drop_index("ix_behaviour_experiments_user_started", table_name="behaviour_experiments")
    op.drop_table("behaviour_experiments")
