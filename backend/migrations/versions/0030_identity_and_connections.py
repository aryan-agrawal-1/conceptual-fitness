from alembic import op
import sqlalchemy as sa

revision = "0030_identity_and_connections"
down_revision = "0029_behaviour_experiments"
branch_labels = None
depends_on = None

CONNECTION_TABLES = ("raw_health_records", "sync_cursors", "historical_backfills")


def upgrade() -> None:
    op.rename_table("google_accounts", "health_connections")
    op.alter_column("health_connections", "health_user_id", new_column_name="external_user_id")
    op.alter_column("health_connections", "legacy_user_id", new_column_name="external_legacy_user_id")
    op.add_column(
        "health_connections",
        sa.Column("provider", sa.String(32), nullable=False, server_default="google_health"),
    )
    op.alter_column("health_connections", "provider", server_default=None)
    op.drop_constraint("uq_google_accounts_health_user_id", "health_connections", type_="unique")
    op.drop_constraint("uq_google_accounts_legacy_user_id", "health_connections", type_="unique")
    op.create_unique_constraint(
        "uq_health_connections_provider_external_user",
        "health_connections",
        ["provider", "external_user_id"],
    )
    op.create_unique_constraint(
        "uq_health_connections_provider_legacy_user",
        "health_connections",
        ["provider", "external_legacy_user_id"],
    )
    op.execute("ALTER INDEX google_accounts_pkey RENAME TO health_connections_pkey")
    op.execute("ALTER INDEX ix_google_accounts_user_id RENAME TO ix_health_connections_user_id")
    rename_foreign_key("health_connections", "user_id", "health_connections_user_id_fkey")
    op.execute(
        """
        UPDATE health_connections
        SET status = 'disconnected', disconnected_at = COALESCE(disconnected_at, now())
        WHERE status <> 'disconnected'
          AND id NOT IN (
            SELECT DISTINCT ON (user_id) id
            FROM health_connections
            WHERE status <> 'disconnected'
            ORDER BY user_id, connected_at DESC
          )
        """
    )
    op.create_index(
        "uq_health_connections_one_active",
        "health_connections",
        ["user_id"],
        unique=True,
        postgresql_where=sa.text("status <> 'disconnected'"),
    )

    for table in CONNECTION_TABLES:
        op.alter_column(table, "google_account_id", new_column_name="connection_id")
        op.execute(f"ALTER INDEX ix_{table}_google_account_id RENAME TO ix_{table}_connection_id")
        rename_foreign_key(table, "connection_id", f"{table}_connection_id_fkey")

    op.execute("DELETE FROM oauth_states")
    op.alter_column("oauth_states", "sensitive_action", new_column_name="purpose", nullable=False)

    op.create_table(
        "sign_in_identities",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("provider", sa.String(32), nullable=False),
        sa.Column("subject", sa.String(255), nullable=False),
        sa.Column("email", sa.String(320), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_signed_in_at", sa.DateTime(timezone=True), nullable=True),
        sa.UniqueConstraint("provider", "subject", name="uq_sign_in_identities_provider_subject"),
    )
    op.create_index("ix_sign_in_identities_user_id", "sign_in_identities", ["user_id"])


def downgrade() -> None:
    op.drop_index("ix_sign_in_identities_user_id", table_name="sign_in_identities")
    op.drop_table("sign_in_identities")

    op.execute("DELETE FROM oauth_states")
    op.alter_column("oauth_states", "purpose", new_column_name="sensitive_action", nullable=True)

    for table in CONNECTION_TABLES:
        op.alter_column(table, "connection_id", new_column_name="google_account_id")
        op.execute(f"ALTER INDEX ix_{table}_connection_id RENAME TO ix_{table}_google_account_id")
        rename_foreign_key(table, "google_account_id", f"{table}_google_account_id_fkey")

    op.drop_index("uq_health_connections_one_active", table_name="health_connections")
    rename_foreign_key("health_connections", "user_id", "google_accounts_user_id_fkey")
    op.execute("ALTER INDEX ix_health_connections_user_id RENAME TO ix_google_accounts_user_id")
    op.execute("ALTER INDEX health_connections_pkey RENAME TO google_accounts_pkey")
    op.drop_constraint("uq_health_connections_provider_legacy_user", "health_connections", type_="unique")
    op.drop_constraint("uq_health_connections_provider_external_user", "health_connections", type_="unique")
    op.drop_column("health_connections", "provider")
    op.alter_column("health_connections", "external_legacy_user_id", new_column_name="legacy_user_id")
    op.alter_column("health_connections", "external_user_id", new_column_name="health_user_id")
    op.create_unique_constraint("uq_google_accounts_health_user_id", "health_connections", ["health_user_id"])
    op.create_unique_constraint("uq_google_accounts_legacy_user_id", "health_connections", ["legacy_user_id"])
    op.rename_table("health_connections", "google_accounts")


def rename_foreign_key(table, column, new_name):
    inspector = sa.inspect(op.get_bind())
    for foreign_key in inspector.get_foreign_keys(table):
        if foreign_key["constrained_columns"] == [column] and foreign_key["name"] != new_name:
            op.execute(f'ALTER TABLE {table} RENAME CONSTRAINT "{foreign_key["name"]}" TO "{new_name}"')
