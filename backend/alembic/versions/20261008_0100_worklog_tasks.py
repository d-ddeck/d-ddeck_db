"""Structured work log task entries (AM/PM, office/trip, place, title, detail)."""
import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql
revision = "d173a974f2a6"
down_revision = "c062f863e195"
branch_labels = None
depends_on = None

def upgrade():
    op.add_column("worklogs", sa.Column("tasks", sa.JSON().with_variant(postgresql.JSONB(), "postgresql"), nullable=True))

def downgrade():
    op.drop_column("worklogs", "tasks")
