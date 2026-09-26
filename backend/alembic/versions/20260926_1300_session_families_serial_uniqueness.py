"""Session families for immediate revocation; live serial uniqueness."""
from alembic import op
import sqlalchemy as sa

revision = '83c49d102fa1'
down_revision = '2cca8909675d'
branch_labels = None
depends_on = None


def upgrade():
    duplicates = op.get_bind().execute(sa.text("SELECT category_id, lower(trim(serial_no)), count(*) FROM assets WHERE deleted_at IS NULL AND serial_no IS NOT NULL AND trim(serial_no) <> '' GROUP BY category_id, lower(trim(serial_no)) HAVING count(*) > 1")).fetchall()
    if duplicates:
        raise RuntimeError('Duplicate live asset serials exist. Resolve duplicates before migration; no rows are removed automatically.')
    with op.batch_alter_table('refresh_tokens') as batch:
        batch.add_column(sa.Column('session_id', sa.Uuid(), nullable=True))
    op.execute(sa.text('UPDATE refresh_tokens SET session_id = id'))
    with op.batch_alter_table('refresh_tokens') as batch:
        batch.alter_column('session_id', existing_type=sa.Uuid(), nullable=False)
        batch.create_index('ix_refresh_tokens_session_id', ['session_id'])
    with op.batch_alter_table('devices') as batch:
        batch.add_column(sa.Column('session_id', sa.Uuid(), nullable=True))
        batch.create_index('ix_devices_session_id', ['session_id'])
    op.execute(sa.text("CREATE UNIQUE INDEX uq_assets_category_serial_live ON assets (category_id, lower(trim(serial_no))) WHERE deleted_at IS NULL AND serial_no IS NOT NULL AND trim(serial_no) <> '' AND category_id IS NOT NULL"))
    op.execute(sa.text("CREATE UNIQUE INDEX uq_assets_serial_no_category_live ON assets (lower(trim(serial_no))) WHERE deleted_at IS NULL AND serial_no IS NOT NULL AND trim(serial_no) <> '' AND category_id IS NULL"))


def downgrade():
    op.drop_index('uq_assets_serial_no_category_live', table_name='assets')
    op.drop_index('uq_assets_category_serial_live', table_name='assets')
    with op.batch_alter_table('devices') as batch:
        batch.drop_index('ix_devices_session_id')
        batch.drop_column('session_id')
    with op.batch_alter_table('refresh_tokens') as batch:
        batch.drop_index('ix_refresh_tokens_session_id')
        batch.drop_column('session_id')
