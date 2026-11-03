from alembic import op
import sqlalchemy as sa

from app.db.sealed_json import open_text, seal_text

revision = "0026_seal_journal_notes"
down_revision = "0025_journal_completions"
branch_labels = None
depends_on = None

entries = sa.table(
    "journal_entries", sa.column("id", sa.String), sa.column("behaviour_id", sa.String),
    sa.column("deleted", sa.Boolean), sa.column("response", sa.JSON), sa.column("normalized", sa.JSON),
)


def rewrite(transform):
    bind = op.get_bind()
    rows = bind.execute(sa.select(entries.c.id, entries.c.response, entries.c.normalized)
                        .where(entries.c.behaviour_id == "daily_note", entries.c.deleted.is_(False))).all()
    for row in rows:
        bind.execute(entries.update().where(entries.c.id == row.id).values(
            response=transform(row.response), normalized=transform(row.normalized),
        ))


def upgrade():
    rewrite(seal_text)


def downgrade():
    rewrite(open_text)
