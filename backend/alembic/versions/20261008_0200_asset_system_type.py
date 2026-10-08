"""Equipment system configuration: ANDROID, WINDOWS or PLC."""
import sqlalchemy as sa
from alembic import op
revision = "e284b085a3b7"
down_revision = "d173a974f2a6"
branch_labels = None
depends_on = None

def upgrade():
    op.add_column("assets", sa.Column("system_type", sa.String(16), nullable=True))

def downgrade():
    op.drop_column("assets", "system_type")
