"""Keep current sync running until derived scores are committed."""

from alembic import op
import sqlalchemy as sa

revision = "0019_sync_lifecycle"
down_revision = "0018_historical_cursors"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("google_accounts", sa.Column("sync_started_at", sa.DateTime(timezone=True)))


def downgrade() -> None:
    op.drop_column("google_accounts", "sync_started_at")
