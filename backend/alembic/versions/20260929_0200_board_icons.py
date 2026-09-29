"""Per-board selectable icons."""
import sqlalchemy as sa
from alembic import op
revision = "b951e752d084"
down_revision = "a840d641cf73"
branch_labels = None
depends_on = None

def upgrade():
    op.add_column("boards", sa.Column("icon", sa.String(32), nullable=False, server_default="auto"))

def downgrade():
    op.drop_column("boards", "icon")
