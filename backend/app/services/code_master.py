"""Consistent code item lookup, including ordering and soft-deletion policy."""

from sqlalchemy import select

from app.models.admin import CodeGroup, CodeItem


def items(db, group_code, *, active_only=True, parent_id=None):
    statement = (
        select(CodeItem)
        .join(CodeGroup, CodeGroup.id == CodeItem.group_id)
        .where(CodeGroup.code == group_code, CodeItem.deleted_at.is_(None))
    )
    if active_only:
        statement = statement.where(CodeItem.is_active.is_(True))
    if parent_id is not None:
        statement = statement.where(CodeItem.parent_id == parent_id)
    return list(db.scalars(statement.order_by(CodeItem.sort_order, CodeItem.name)))
