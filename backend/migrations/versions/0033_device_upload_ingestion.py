from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "0033_device_upload_ingestion"
down_revision = "0032_sign_in_with_apple"
branch_labels = None
depends_on = None

sync_status = postgresql.ENUM("pending", "running", "succeeded", "failed", name="syncstatus", create_type=False)


def upgrade() -> None:
    op.create_table(
        "device_sync_progress",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column(
            "connection_id",
            sa.String(36),
            sa.ForeignKey("health_connections.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("data_type", sa.String(80), nullable=False),
        sa.Column("phase", sa.String(16), nullable=False),
        sa.Column("range_start", sa.Date(), nullable=True),
        sa.Column("range_end", sa.Date(), nullable=True),
        sa.Column("anchor", sa.Text(), nullable=True),
        sa.Column("status", sync_status, nullable=False),
        sa.Column("samples_received", sa.Integer(), nullable=False),
        sa.Column("deletions_received", sa.Integer(), nullable=False),
        sa.Column("pending_rebuild_start", sa.Date(), nullable=True),
        sa.Column("pending_rebuild_end", sa.Date(), nullable=True),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("connection_id", "data_type", "phase", name="uq_device_sync_progress"),
    )
    op.create_index("ix_device_sync_progress_connection_id", "device_sync_progress", ["connection_id"])
    op.create_table(
        "deleted_device_records",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column(
            "connection_id",
            sa.String(36),
            sa.ForeignKey("health_connections.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("source_record_id", sa.String(64), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("connection_id", "source_record_id", name="uq_deleted_device_record"),
    )
    op.create_index("ix_deleted_device_records_connection_id", "deleted_device_records", ["connection_id"])


def downgrade() -> None:
    op.drop_index("ix_deleted_device_records_connection_id", table_name="deleted_device_records")
    op.drop_table("deleted_device_records")
    op.drop_index("ix_device_sync_progress_connection_id", table_name="device_sync_progress")
    op.drop_table("device_sync_progress")
