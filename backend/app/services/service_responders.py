"""Selectable service responders follow the active account directory.
Historical code items remain intact for existing service records/statistics.
"""

import uuid
from collections import Counter

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert

from app.models.admin import CodeItem
from app.models.enums import Role, UserStatus
from app.models.user import User


def historical(db, group_id):
    from app.models.service import ServiceTicketResponder

    return db.scalars(
        select(CodeItem).where(
            CodeItem.group_id == group_id,
            CodeItem.deleted_at.is_(None),
            CodeItem.id.in_(select(ServiceTicketResponder.responder_id)),
        ).order_by(CodeItem.name, CodeItem.id)
    ).all()


def selectable(db, group, *, include_historical=False):
    users = db.scalars(
        select(User)
        .where(
            User.status == UserStatus.APPROVED,
            User.deleted_at.is_(None),
            User.role != Role.SUPERADMIN,
        )
        .order_by(User.full_name, User.id)
    ).all()
    names = Counter(u.full_name for u in users)
    result = []
    for user in users:
        code = f"USER_{user.id.hex}"
        existing = next(
            (i for i in group.items if (i.extra or {}).get("user_id") == str(user.id)),
            None,
        )
        # Do not guess identity from a name: imported records may refer to a
        # different person with the same name.
        name = (
            user.full_name
            if names[user.full_name] == 1
            else f"{user.full_name} ({user.email})"
        )
        if existing is None:
            insert = (
                pg_insert if db.bind.dialect.name == "postgresql" else sqlite_insert
            )
            db.execute(
                insert(CodeItem)
                .values(
                    id=uuid.uuid5(group.id, code),
                    group_id=group.id,
                    code=code,
                    name=name[:120],
                    is_active=True,
                    sort_order=0,
                    extra={"user_id": str(user.id)},
                )
                .on_conflict_do_nothing(index_elements=["group_id", "code"])
            )
            existing = db.scalar(
                select(CodeItem).where(
                    CodeItem.group_id == group.id, CodeItem.code == code
                )
            )
        existing.name = name[:120]
        existing.is_active = True
        existing.deleted_at = None
        result.append(existing)
    if include_historical:
        seen = {item.id for item in result}
        result.extend(item for item in historical(db, group.id) if item.id not in seen)
    db.commit()
    return result
