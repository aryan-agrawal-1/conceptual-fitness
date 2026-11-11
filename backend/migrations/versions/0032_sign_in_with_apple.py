from alembic import op
import sqlalchemy as sa

revision = "0032_sign_in_with_apple"
down_revision = "0031_hrv_measurement_type"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("sign_in_identities", sa.Column("encrypted_refresh_token", sa.Text(), nullable=True))
    op.add_column("health_connections", sa.Column("account_subject", sa.String(255), nullable=True))
    op.create_index(
        "ix_health_connections_account_subject", "health_connections", ["account_subject"]
    )
    op.add_column(
        "oauth_states",
        sa.Column("provider", sa.String(32), nullable=False, server_default="google"),
    )
    op.alter_column("oauth_states", "provider", server_default=None)


def downgrade() -> None:
    op.drop_column("oauth_states", "provider")
    op.drop_index("ix_health_connections_account_subject", table_name="health_connections")
    op.drop_column("health_connections", "account_subject")
    op.drop_column("sign_in_identities", "encrypted_refresh_token")
