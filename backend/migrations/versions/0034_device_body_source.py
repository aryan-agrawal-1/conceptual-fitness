from alembic import op

revision = "0034_device_body_source"
down_revision = "0033_device_upload_ingestion"
branch_labels = None
depends_on = None

COLUMNS = ("height_source_preference", "weight_source_preference")


def upgrade() -> None:
    for column in COLUMNS:
        op.execute(f"UPDATE user_profiles SET {column} = 'device' WHERE {column} = 'google'")
        op.alter_column("user_profiles", column, server_default="device")


def downgrade() -> None:
    for column in COLUMNS:
        op.execute(f"UPDATE user_profiles SET {column} = 'google' WHERE {column} = 'device'")
        op.alter_column("user_profiles", column, server_default="google")
