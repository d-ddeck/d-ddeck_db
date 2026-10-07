"""Morning and afternoon task lines on work logs."""
import sqlalchemy as sa
from alembic import op
revision = "c062f863e195"
down_revision = "b951e752d084"
branch_labels = None
depends_on = None

def upgrade():
    op.add_column("worklogs", sa.Column("morning", sa.Text(), nullable=True))
    op.add_column("worklogs", sa.Column("afternoon", sa.Text(), nullable=True))

def downgrade():
    op.drop_column("worklogs", "afternoon")
    op.drop_column("worklogs", "morning")
