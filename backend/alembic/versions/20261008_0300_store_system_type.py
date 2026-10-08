"""System configuration belongs to the store, not each asset.

Copies any value recorded on a store's assets to the store, then drops the
asset column added by e284b085a3b7.
"""
import sqlalchemy as sa
from alembic import op
revision = "f395c196b4c8"
down_revision = "e284b085a3b7"
branch_labels = None
depends_on = None

def upgrade():
    op.add_column("stores", sa.Column("system_type", sa.String(16), nullable=True))
    op.execute(
        """
        UPDATE stores SET system_type = (
            SELECT a.system_type FROM assets a
            WHERE a.store_id = stores.id AND a.system_type IS NOT NULL
            GROUP BY a.system_type ORDER BY count(*) DESC, a.system_type LIMIT 1
        )
        """
    )
    # SQLite 는 3.35 부터 칸 삭제를 지원한다. 표를 다시 만드는 batch 방식은 SQLite 가
    # 읽지 못하는 식 인덱스(uq_assets_serial_no_category_live 등)를 잃으므로 쓰지 않는다.
    if op.get_bind().dialect.name == "sqlite":
        op.execute("ALTER TABLE assets DROP COLUMN system_type")
    else:
        op.drop_column("assets", "system_type")

def downgrade():
    op.add_column("assets", sa.Column("system_type", sa.String(16), nullable=True))
    op.drop_column("stores", "system_type")
