"""Store contact defaults and historical service contact snapshot."""

import sqlalchemy as sa

from alembic import op

revision = "d527a318fc40"
down_revision = "c43194e8a260"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("stores") as batch:
        batch.add_column(sa.Column("contact_name", sa.String(150), nullable=True))
        batch.add_column(sa.Column("contact_phone", sa.String(50), nullable=True))
        batch.add_column(sa.Column("address", sa.String(300), nullable=True))
    with op.batch_alter_table("service_tickets") as batch:
        batch.add_column(sa.Column("contact_name", sa.String(150), nullable=True))


def downgrade():
    with op.batch_alter_table("service_tickets") as batch:
        batch.drop_column("contact_name")
    with op.batch_alter_table("stores") as batch:
        for column in ("address", "contact_phone", "contact_name"):
            batch.drop_column(column)
