"""Idempotent supplemental history import. No writes to the legacy source."""

from datetime import datetime, timezone
from uuid import UUID, uuid5

from app.models.admin import AuditLog, CodeGroup, CodeItem
from app.models.board import Board
from app.models.enums import AuditAction, BoardType, ModuleKey, MovementType
from app.models.inventory import Asset, AssetMovement
from app.models.service import ServiceTicket
from app.models.store import Store
from sqlalchemy import select

NAMESPACE = UUID("27d3dc3c-5036-44df-80e6-e31522780bd9")


def migrate(db, src, stats, users, to_utc, code_for):
    tables = {
        row[0]
        for row in src.execute("SELECT name FROM sqlite_master WHERE type='table'")
    }
    tickets = {
        row.legacy_no: row
        for row in db.scalars(
            select(ServiceTicket).where(ServiceTicket.legacy_no.is_not(None))
        )
    }
    created = reused = 0
    if "change_log" in tables:
        for identifier, number, at, author, action, field, old, new in src.execute(
            'SELECT id, record_no, at, "by", action, field, old, new FROM change_log ORDER BY id'
        ):
            key = uuid5(NAMESPACE, f"change_log:{identifier}")
            if db.get(AuditLog, key):
                reused += 1
                continue
            ticket = tickets.get(number)
            actor = users.get(author)
            db.add(
                AuditLog(
                    id=key,
                    created_at=to_utc(at) or datetime(1970, 1, 1, tzinfo=timezone.utc),
                    actor_id=actor.id if actor else None,
                    actor_email=actor.email if actor else None,
                    action=AuditAction.UPDATE,
                    module=ModuleKey.SERVICE,
                    entity_type="service_ticket" if ticket else "legacy_service_ticket",
                    entity_id=str(ticket.id) if ticket else str(number),
                    summary=f"구 서버 {action} ({author})",
                    changes={field or "내용": [old, new]},
                )
            )
            created += 1
        stats.add("대응 변경 이력", created, reused)
    created = reused = 0
    if "asset_log" in tables:
        asset_map = {row.asset_no: row for row in db.scalars(select(Asset))}
        for identifier, asset_id, at, author, action, detail, number in src.execute(
            'SELECT id, asset_id, at, "by", action, detail, record_no FROM asset_log ORDER BY id'
        ):
            key = uuid5(NAMESPACE, f"asset_log:{identifier}")
            if db.get(AssetMovement, key) or db.get(AuditLog, key):
                reused += 1
                continue
            asset = asset_map.get(f"AST-L-{asset_id:05d}")
            # Reused assets may predate this importer and lack the AST-L number.
            if asset is None:
                source = src.execute(
                    "SELECT kind, serial FROM assets WHERE id=?", (asset_id,)
                ).fetchone()
                if source:
                    asset = db.scalar(
                        select(Asset)
                        .join(CodeItem, Asset.category_id == CodeItem.id)
                        .join(CodeGroup, CodeItem.group_id == CodeGroup.id)
                        .where(
                            CodeGroup.code == "ASSET_CATEGORY",
                            CodeItem.name == source[0],
                            Asset.serial_no == source[1],
                        )
                    )
            actor = users.get(author)
            when = to_utc(at) or datetime(1970, 1, 1, tzinfo=timezone.utc)
            ticket = tickets.get(number)
            if asset is not None:
                db.add(
                    AssetMovement(
                        id=key,
                        asset_id=asset.id,
                        movement_type=MovementType.MOVE,
                        moved_at=when,
                        created_at=when,
                        updated_at=when,
                        moved_by_id=actor.id if actor else None,
                        reason=f"구 서버 {action} ({author}): {detail}",
                        reference_type="service_ticket"
                        if ticket
                        else "legacy_asset_log",
                        reference_id=ticket.id if ticket else None,
                    )
                )
            else:
                # Deleted legacy assets still retain their history in audit logs.
                db.add(
                    AuditLog(
                        id=key,
                        created_at=when,
                        actor_id=actor.id if actor else None,
                        actor_email=actor.email if actor else None,
                        action=AuditAction.UPDATE,
                        module=ModuleKey.INVENTORY,
                        entity_type="legacy_asset",
                        entity_id=str(asset_id),
                        summary=f"구 서버 {action} ({author}): {detail}",
                    )
                )
            created += 1
        stats.add("재고 변경 이력", created, reused)
    changed = 0
    for number, author in src.execute("SELECT no, updated_by FROM records"):
        ticket, actor = tickets.get(number), users.get(author)
        if ticket and actor and ticket.updated_by_id is None:
            ticket.updated_by_id = actor.id
            changed += 1
        elif ticket and not actor and author:
            key = uuid5(NAMESPACE, f"records.updated_by:{number}")
            if db.get(AuditLog, key) is None:
                db.add(
                    AuditLog(
                        id=key,
                        created_at=ticket.updated_at or ticket.received_at,
                        action=AuditAction.UPDATE,
                        module=ModuleKey.SERVICE,
                        entity_type="service_ticket",
                        entity_id=str(ticket.id),
                        summary=f"구 서버 최종 수정자: {author} (현재 계정 미연결)",
                        changes={"updated_by": [None, author]},
                    )
                )
                changed += 1
    stats.add("대응 수정자", changed, 0)
    for name, active in src.execute("SELECT name, active FROM stores"):
        store = db.scalar(select(Store).where(Store.name == name))
        if store:
            store.is_active = bool(active)
    created = reused = 0
    for name, order, active in src.execute(
        "SELECT value, sort, active FROM lists WHERE kind IN ('doc_category', 'doc_board')"
    ):
        code = "NOTICE" if name == "공지사항" else f"LEGACY_{code_for(name)}"
        board = db.scalar(select(Board).where(Board.code == code))
        if board:
            reused += 1
        else:
            db.add(
                Board(
                    code=code,
                    name=name,
                    type=BoardType.ARCHIVE,
                    sort_order=order,
                    is_active=bool(active),
                )
            )
            db.flush()
            created += 1
    stats.add("빈 자료 게시판", created, reused)
    db.flush()
