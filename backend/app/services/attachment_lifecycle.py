from sqlalchemy import update

from app.core.security import now_utc
from app.models.admin import Attachment


def soft_delete(db, entity_type, entity_id):
    db.execute(
        update(Attachment)
        .where(
            Attachment.entity_type == entity_type,
            Attachment.entity_id == entity_id,
            Attachment.deleted_at.is_(None),
        )
        .values(deleted_at=now_utc())
    )
