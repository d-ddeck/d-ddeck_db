"""Per-attachment comment (e.g. a caption under a board photo)."""
import sqlalchemy as sa
from alembic import op
revision = "a5b6c7d8e9f0"
down_revision = "f395c196b4c8"
branch_labels = None
depends_on = None

def upgrade():
    op.add_column("attachments", sa.Column("comment", sa.String(500), nullable=True))

def downgrade():
    op.drop_column("attachments", "comment")
