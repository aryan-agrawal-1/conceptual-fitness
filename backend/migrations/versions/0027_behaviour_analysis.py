from alembic import op
import sqlalchemy as sa

revision = "0027_behaviour_analysis"
down_revision = "0026_seal_journal_notes"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "behaviour_analysis_runs",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("algorithm_version", sa.String(40), nullable=False),
        sa.Column("map_version", sa.String(40), nullable=False),
        sa.Column("catalogue_version", sa.Integer(), nullable=False),
        sa.Column("trigger", sa.String(24), nullable=False),
        sa.Column("status", sa.String(24), nullable=False),
        sa.Column("error_code", sa.String(80), nullable=True),
        sa.Column("window_start", sa.Date(), nullable=False),
        sa.Column("window_end", sa.Date(), nullable=False),
        sa.Column("tracking_day", sa.Integer(), nullable=False),
        sa.Column("checkpoint_day", sa.Integer(), nullable=True),
        sa.Column("analysis_revision", sa.Integer(), nullable=False),
        sa.Column("settings", sa.JSON(), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_behaviour_analysis_runs_user_started", "behaviour_analysis_runs",
                    ["user_id", "started_at"])
    op.create_table(
        "behaviour_analysis_results",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("run_id", sa.String(36),
                  sa.ForeignKey("behaviour_analysis_runs.id", ondelete="CASCADE"), nullable=False),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("pair_id", sa.String(120), nullable=False),
        sa.Column("input_id", sa.String(80), nullable=False),
        sa.Column("outcome_id", sa.String(80), nullable=False),
        sa.Column("lag_days", sa.Integer(), nullable=False),
        sa.Column("tier", sa.String(24), nullable=False),
        sa.Column("stratum", sa.String(24), nullable=False),
        sa.Column("stage", sa.String(32), nullable=False),
        sa.Column("suppression_reason", sa.String(80), nullable=True),
        sa.Column("held_reason", sa.String(80), nullable=True),
        sa.Column("coding", sa.String(24), nullable=False),
        sa.Column("exposed_days", sa.Integer(), nullable=False),
        sa.Column("comparison_days", sa.Integer(), nullable=False),
        sa.Column("estimates", sa.JSON(), nullable=False),
        sa.Column("p_value", sa.Float(), nullable=True),
        sa.Column("q_value", sa.Float(), nullable=True),
        sa.Column("checks", sa.JSON(), nullable=False),
        sa.Column("labels", sa.JSON(), nullable=False),
        sa.Column("included_dates", sa.JSON(), nullable=False),
        sa.Column("excluded_days", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_behaviour_analysis_results_run", "behaviour_analysis_results", ["run_id"])
    op.create_index("ix_behaviour_analysis_results_user_pair", "behaviour_analysis_results",
                    ["user_id", "pair_id"])


def downgrade() -> None:
    op.drop_table("behaviour_analysis_results")
    op.drop_table("behaviour_analysis_runs")
