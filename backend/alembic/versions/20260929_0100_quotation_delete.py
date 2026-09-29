"""Allow soft deletion of saved quotations."""
import sqlalchemy as sa
from alembic import op
revision = "a840d641cf73"
down_revision = "f739c530be62"
branch_labels = None
depends_on = None

def upgrade():
    op.add_column("quotation_revisions", sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True))

def downgrade():
    op.drop_column("quotation_revisions", "deleted_at")
