from importlib import import_module

import sqlalchemy as sa
from alembic.migration import MigrationContext
from alembic.operations import Operations


def test_device_key_migration_round_trip() -> None:
    engine = sa.create_engine("sqlite://")
    metadata = sa.MetaData()
    sa.Table("users", metadata, sa.Column("id", sa.String(36), primary_key=True))
    sa.Table(
        "app_sessions",
        metadata,
        sa.Column("id", sa.String(36), primary_key=True),
    )
    sa.Table("oauth_states", metadata, sa.Column("id", sa.String(36), primary_key=True))
    sa.Table("app_auth_codes", metadata, sa.Column("id", sa.String(36), primary_key=True))
    sa.Table(
        "sensitive_action_grants",
        metadata,
        sa.Column("id", sa.String(36), primary_key=True),
    )
    metadata.create_all(engine)
    migration = import_module("migrations.versions.0023_device_key_step_up")

    with engine.begin() as connection:
        migration.op = Operations(MigrationContext.configure(connection))
        migration.upgrade()
        inspector = sa.inspect(connection)
        assert "device_public_key" in {
            column["name"] for column in inspector.get_columns("app_sessions")
        }
        assert "session_id" in {
            column["name"] for column in inspector.get_columns("sensitive_action_grants")
        }

        migration.downgrade()
        inspector = sa.inspect(connection)
        assert "device_public_key" not in {
            column["name"] for column in inspector.get_columns("app_sessions")
        }
        assert "session_id" not in {
            column["name"] for column in inspector.get_columns("sensitive_action_grants")
        }
