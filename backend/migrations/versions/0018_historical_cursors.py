"""Keep historical pagination separate from current sync cursors."""

from alembic import op
import sqlalchemy as sa

revision = "0018_historical_cursors"
down_revision = "0017_historical_backfills"
branch_labels = None
depends_on = None


def upgrade() -> None:
    for name in ("last_successful_start", "last_successful_end"):
        op.add_column("historical_backfills", sa.Column(name, sa.Date(), nullable=True))
    for name in ("last_successful_start_at", "last_successful_end_at"):
        op.add_column("historical_backfills", sa.Column(name, sa.DateTime(timezone=True), nullable=True))
    op.add_column("historical_backfills", sa.Column("last_page_token", sa.Text(), nullable=True))


def downgrade() -> None:
    for name in (
        "last_page_token", "last_successful_end_at", "last_successful_start_at",
        "last_successful_end", "last_successful_start",
    ):
        op.drop_column("historical_backfills", name)
