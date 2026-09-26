"""Extensible service work type; existing records remain unclassified."""

import sqlalchemy as sa

from alembic import op

revision = "b9a381e076cf"
down_revision = "ecdd8d8aea3c"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("service_tickets") as batch:
        batch.add_column(sa.Column("work_type_id", sa.Uuid(), nullable=True))
        batch.create_foreign_key(
            "fk_service_tickets_work_type",
            "code_items",
            ["work_type_id"],
            ["id"],
            ondelete="SET NULL",
        )
        batch.create_index("ix_service_tickets_work_type_id", ["work_type_id"])


def downgrade():
    with op.batch_alter_table("service_tickets") as batch:
        batch.drop_index("ix_service_tickets_work_type_id")
        batch.drop_constraint("fk_service_tickets_work_type", type_="foreignkey")
        batch.drop_column("work_type_id")
