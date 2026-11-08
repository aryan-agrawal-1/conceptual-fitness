from alembic import op
import sqlalchemy as sa

revision = "0028_behaviour_pattern_views"
down_revision = "0027_behaviour_analysis"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "behaviour_pattern_views",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("pair_id", sa.String(120), nullable=False),
        sa.Column("stratum", sa.String(24), nullable=False),
        sa.Column("stage_when_seen", sa.String(32), nullable=False),
        sa.Column("checkpoint_day", sa.Integer(), nullable=True),
        sa.Column("first_seen_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("user_id", "pair_id", "stratum", name="uq_behaviour_pattern_views_pair"),
    )


def downgrade() -> None:
    op.drop_table("behaviour_pattern_views")
