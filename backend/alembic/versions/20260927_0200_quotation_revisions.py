"""Immutable quotation revisions with PDF snapshots."""

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision = "c43194e8a260"
down_revision = "b9a381e076cf"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "quotation_revisions",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column(
            "ticket_id",
            sa.Uuid(),
            sa.ForeignKey("service_tickets.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column(
            "snapshot",
            sa.JSON().with_variant(postgresql.JSONB(), "postgresql"),
            nullable=False,
        ),
        sa.Column("filename", sa.String(200), nullable=False),
        sa.Column("pdf", sa.LargeBinary(), nullable=False),
        sa.Column("sha256", sa.String(64), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column(
            "created_by_id",
            sa.Uuid(),
            sa.ForeignKey("users.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("author_name", sa.String(200), nullable=False),
        sa.UniqueConstraint("ticket_id", "version", name="uq_quotation_ticket_version"),
    )
    op.create_index(
        "ix_quotation_revisions_ticket_id", "quotation_revisions", ["ticket_id"]
    )


def downgrade():
    op.drop_table("quotation_revisions")
