"""Allow full work type codes in newly issued ticket numbers."""

import sqlalchemy as sa

from alembic import op

revision = "e628b429ad51"
down_revision = "d527a318fc40"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("service_tickets") as batch:
        batch.alter_column(
            "ticket_no",
            existing_type=sa.String(40),
            type_=sa.String(80),
            existing_nullable=False,
        )


def downgrade():
    with op.batch_alter_table("service_tickets") as batch:
        batch.alter_column(
            "ticket_no",
            existing_type=sa.String(80),
            type_=sa.String(40),
            existing_nullable=False,
        )
