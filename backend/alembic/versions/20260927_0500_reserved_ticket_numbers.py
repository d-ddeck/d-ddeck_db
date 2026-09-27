"""Reserve issued ticket numbers across work type changes."""

import sqlalchemy as sa

from alembic import op

revision = "f739c530be62"
down_revision = "e628b429ad51"
branch_labels = None
depends_on = None


def upgrade():
    numbers = op.create_table(
        "service_ticket_numbers",
        sa.Column("ticket_no", sa.String(80), primary_key=True),
    )
    tickets = sa.table("service_tickets", sa.column("ticket_no", sa.String(80)))
    op.execute(
        numbers.insert().from_select(["ticket_no"], sa.select(tickets.c.ticket_no))
    )


def downgrade():
    op.drop_table("service_ticket_numbers")
