"""구 서버(CS_Record)의 대응 기록 입력 규칙과 재고 연동.

엑셀 "서비스 대응일지 통합"에서 온 규칙을 그대로 옮겼다:
  * 서비스구분 1 은 필수. 증상(세부분류)은 그 구분에 딸린 것만.
    로봇팔 · 제어박스 · 전동 그리퍼(설정 maker_required_categories)는 제조사 필수.
  * 렌탈 O 면 종류 · 시리얼 · 회수 예정일 필수, 시리얼은 재고에 있는 S/N 만
    (설정 rental_serial_must_exist). 회수 O 면 실제 회수일 필수. 렌탈 X 면 렌탈 칸을 비운다.
  * 종결에는 대응 내용(require_result_note)과 대응인원(require_responder_on_complete).
  * 렌탈 저장 → 그 S/N 장비를 매장 '렌탈 중'으로, 회수 → '창고'로 (재고 이력에 기록 번호 남김).
"""

from __future__ import annotations

import re
import uuid
from datetime import date

from fastapi import status as http
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.errors import AppError
from app.core.security import now_utc
from app.models.admin import CodeGroup, CodeItem
from app.models.enums import AssetStatus, ModuleKey, MovementType
from app.models.inventory import AssetMovement
from app.models.service import (
    ServiceTicket,
    ServiceTicketCause,
    ServiceTicketResponder,
)
from app.models.store import Store
from app.models.user import User
from app.services import asset_movement, asset_rules, settings_store

DEFAULT_MAKER_CATEGORIES = ["로봇팔", "제어박스", "전동 그리퍼"]
SERIAL_SPLIT = re.compile(r"[\s,;/]+")


def split_serials(text: str | None) -> list[str]:
    return [s for s in SERIAL_SPLIT.split(text or "") if s]


def _group_id(db: Session, code: str) -> uuid.UUID | None:
    return db.scalar(select(CodeGroup.id).where(CodeGroup.code == code))


def _item(
    db: Session, item_id: uuid.UUID | None, group_code: str, what: str
) -> CodeItem | None:
    if item_id is None:
        return None
    item = db.get(CodeItem, item_id)
    gid = _group_id(db, group_code)
    if (
        item is None
        or item.deleted_at is not None
        or not item.is_active
        or (gid is not None and item.group_id != gid)
    ):
        raise AppError(
            "CODE_NOT_FOUND", f"{what} 값이 목록에 없습니다.", http.HTTP_400_BAD_REQUEST
        )
    return item


def maker_required_categories(db: Session) -> set[str]:
    v = settings_store.get(
        db, ModuleKey.SERVICE, "maker_required_categories", DEFAULT_MAKER_CATEGORIES
    )
    return {str(x) for x in (v or [])}


# --------------------------------------------------------------- 원인
def validate_causes(
    db: Session, causes: list
) -> list[tuple[uuid.UUID, uuid.UUID | None, uuid.UUID | None]]:
    """원인 목록을 검사해 (서비스구분, 증상, 제조사) id 튜플로. 저장은 set_causes 가 한다.

    접수 행을 만들기 전에 부르므로, 규칙에 어긋나면 번호를 채번하지도 않는다.
    """
    max_causes = int(settings_store.get(db, ModuleKey.SERVICE, "max_causes", 10) or 10)
    if len(causes) > max_causes:
        raise AppError(
            "TOO_MANY_CAUSES", f"서비스구분은 최대 {max_causes}개까지 넣을 수 있습니다."
        )
    if not causes and settings_store.get(
        db, ModuleKey.SERVICE, "require_category", True
    ):
        raise AppError("CATEGORY_REQUIRED", "서비스구분 1을 고르세요.")
    need_maker = maker_required_categories(db)
    out: list[tuple[uuid.UUID, uuid.UUID | None, uuid.UUID | None]] = []
    for i, c in enumerate(causes, 1):
        cat = _item(db, c.category_id, "SERVICE_CATEGORY", f"서비스구분 {i}")
        if cat is None:
            raise AppError("CATEGORY_REQUIRED", f"서비스구분 {i}을 고르세요.")
        sym = _item(db, c.symptom_id, "SERVICE_SYMPTOM", f"증상 {i}")
        if sym is not None and sym.parent_id is not None and sym.parent_id != cat.id:
            raise AppError(
                "SYMPTOM_MISMATCH",
                f'증상 {i}이(가) 서비스구분 "{cat.name}"에 속하지 않습니다.',
            )
        maker = _item(db, c.maker_id, "ASSET_MAKER", f"제조사 {i}")
        if cat.name in need_maker:
            if maker is None:
                raise AppError(
                    "MAKER_REQUIRED",
                    f"서비스구분 {i}이(가) {cat.name}이면 제조사를 고르세요. "
                    f"(목록에 없으면 [관리]→[분류 코드]의 자산 제조사에 추가)",
                )
            if maker.parent_id is not None:
                parent = db.get(CodeItem, maker.parent_id)
                if parent is not None and parent.name != cat.name:
                    raise AppError(
                        "MAKER_MISMATCH",
                        f'제조사 {i} "{maker.name}"은(는) {cat.name} 제조사 목록에 없습니다.',
                    )
        else:
            maker = None
        out.append((cat.id, sym.id if sym else None, maker.id if maker else None))
    return out


def set_causes(
    db: Session, ticket: ServiceTicket, validated: list[tuple], *, is_new: bool
) -> None:
    """service_ticket_causes 를 통째로 바꾸고 대표 분류를 첫 항목으로."""
    if not is_new:
        for old in db.scalars(
            select(ServiceTicketCause).where(ServiceTicketCause.ticket_id == ticket.id)
        ).all():
            db.delete(old)
        db.flush()
    for i, (cat_id, sym_id, maker_id) in enumerate(validated, 1):
        db.add(
            ServiceTicketCause(
                ticket_id=ticket.id,
                seq=i,
                category_id=cat_id,
                symptom_id=sym_id,
                maker_id=maker_id,
            )
        )
    db.flush()  # 세션이 autoflush=False 라, 이어지는 조회가 보게
    ticket.category_id = validated[0][0] if validated else None
    ticket.symptom_id = validated[0][1] if validated else None


def apply_causes(
    db: Session, ticket: ServiceTicket, causes: list, *, is_new: bool
) -> None:
    set_causes(db, ticket, validate_causes(db, causes), is_new=is_new)


def sync_head_cause(db: Session, ticket: ServiceTicket) -> None:
    """대표 분류(category_id/symptom_id)만 온 옛 클라이언트용: seq 1 행을 맞춘다."""
    cat = _item(db, ticket.category_id, "SERVICE_CATEGORY", "서비스구분")
    sym = _item(db, ticket.symptom_id, "SERVICE_SYMPTOM", "증상")
    if sym is not None and (
        cat is None or (sym.parent_id is not None and sym.parent_id != cat.id)
    ):
        raise AppError("SYMPTOM_MISMATCH", "증상이 서비스구분에 속하지 않습니다.")
    head = db.scalar(
        select(ServiceTicketCause).where(
            ServiceTicketCause.ticket_id == ticket.id, ServiceTicketCause.seq == 1
        )
    )
    from types import SimpleNamespace

    rows = (
        []
        if ticket.category_id is None and ticket.symptom_id is None
        else [
            SimpleNamespace(
                category_id=ticket.category_id,
                symptom_id=ticket.symptom_id,
                maker_id=head.maker_id
                if head and head.category_id == ticket.category_id
                else None,
            )
        ]
    )
    validated = validate_causes(db, rows)
    if not validated:
        if head is not None:
            db.delete(head)
        return
    category_id, symptom_id, maker_id = validated[0]
    if head is None:
        db.add(
            ServiceTicketCause(
                ticket_id=ticket.id,
                seq=1,
                category_id=category_id,
                symptom_id=symptom_id,
                maker_id=maker_id,
            )
        )
    else:
        head.category_id, head.symptom_id, head.maker_id = (
            category_id,
            symptom_id,
            maker_id,
        )


# --------------------------------------------------------------- 대응인원
def validate_responder_ids(
    db: Session, responder_ids: list[uuid.UUID]
) -> list[uuid.UUID]:
    seen: list[uuid.UUID] = []
    for rid in responder_ids:
        if rid in seen:
            continue
        _item(db, rid, "SERVICE_RESPONDER", "대응인원")
        seen.append(rid)
    return seen


def set_responders(
    db: Session, ticket: ServiceTicket, responder_ids: list[uuid.UUID], *, is_new: bool
) -> None:
    if not is_new:
        for old in db.scalars(
            select(ServiceTicketResponder).where(
                ServiceTicketResponder.ticket_id == ticket.id
            )
        ).all():
            db.delete(old)
        db.flush()
    for i, rid in enumerate(responder_ids, 1):
        db.add(ServiceTicketResponder(ticket_id=ticket.id, seq=i, responder_id=rid))
    db.flush()  # 종결 검사(responder_count)가 바로 보게


def apply_responders(
    db: Session, ticket: ServiceTicket, responder_ids: list[uuid.UUID], *, is_new: bool
) -> None:
    set_responders(db, ticket, validate_responder_ids(db, responder_ids), is_new=is_new)


def responder_count(db: Session, ticket: ServiceTicket) -> int:
    return len(
        db.scalars(
            select(ServiceTicketResponder.id).where(
                ServiceTicketResponder.ticket_id == ticket.id
            )
        ).all()
    )


def require_responders_on_complete(db: Session, ticket: ServiceTicket) -> None:
    if not settings_store.get(
        db, ModuleKey.SERVICE, "require_responder_on_complete", True
    ):
        return
    if responder_count(db, ticket) == 0:
        raise AppError("RESPONDER_REQUIRED", "종결하려면 대응인원을 고르세요.")


# --------------------------------------------------------------- 렌탈
def validate_rental(db: Session, ticket: ServiceTicket) -> None:
    """렌탈 칸의 필수·종속 규칙. 값은 ticket 에 이미 올라와 있다."""
    if not ticket.is_rental:
        ticket.rental_type_id = None
        ticket.rental_serials = None
        ticket.rental_due_date = None
        ticket.rental_returned = False
        ticket.rental_return_date = None
        return
    if ticket.rental_type_id is None:
        raise AppError("RENTAL_TYPE_REQUIRED", "렌탈 장비 종류를 고르세요.")
    _item(db, ticket.rental_type_id, "SERVICE_RENTAL_TYPE", "렌탈 장비 종류")
    serials = split_serials(ticket.rental_serials)
    if not serials:
        raise AppError("RENTAL_SERIAL_REQUIRED", "렌탈 장비 시리얼을 입력하세요.")
    ticket.rental_serials = ", ".join(serials)  # 여러 개면 'A, B' 로 통일
    if settings_store.get(db, ModuleKey.SERVICE, "rental_serial_must_exist", True):
        missing = [
            s for s in serials if asset_rules.find_asset_by_serial(db, s) is None
        ]
        if missing:
            raise AppError(
                "RENTAL_SERIAL_UNKNOWN",
                f"재고에 없는 시리얼 넘버입니다: {', '.join(missing)}. "
                "재고에 등록된 S/N 을 입력하세요 (없으면 [재고] → 등록 먼저).",
                details={"missing": missing},
            )
    if ticket.rental_due_date is None:
        raise AppError("RENTAL_DUE_REQUIRED", "회수 예정일을 입력하세요.")
    if ticket.rental_returned and ticket.rental_return_date is None:
        raise AppError(
            "RENTAL_RETURN_DATE_REQUIRED",
            "회수 여부가 O 이면 실제 회수일을 입력하세요.",
        )
    if not ticket.rental_returned:
        ticket.rental_return_date = None


def sync_rental_assets(
    db: Session, ticket: ServiceTicket, user: User | None
) -> list[str]:
    """대응 기록의 렌탈 정보를 재고에 반영.

    렌탈 O · 미회수 → 그 S/N 장비를 그 매장 '렌탈 중'으로, 회수 O → '창고'로.
    재고에 없는 S/N 은 알려만 준다. 돌려주는 값은 안내 문구 목록.
    """
    if not ticket.is_rental or not ticket.rental_serials:
        return []
    want_name = "창고" if ticket.rental_returned else "렌탈 중"
    item = asset_rules.find_status_item(db, want_name)
    if item is None:
        item = asset_rules.find_status_item_by_rule(
            db,
            "clear" if ticket.rental_returned else "store",
            AssetStatus.IN_STOCK if ticket.rental_returned else AssetStatus.LOANED,
        )
    if item is None:
        return [f'재고 상태 목록에 "{want_name}"이(가) 없어 재고를 바꾸지 못했습니다.']

    store: Store | None = db.get(Store, ticket.store_id) if ticket.store_id else None
    msgs: list[str] = []
    for sn in split_serials(ticket.rental_serials):
        asset = asset_rules.find_asset_by_serial(db, sn)
        if asset is None:
            msgs.append(
                f"S/N {sn}은(는) 재고에 없어 상태를 바꾸지 못했습니다. [재고]에 등록한 뒤 기록을 다시 저장하면 연결됩니다."
            )
            continue
        before = (asset.status_item_id, asset.store_id, asset.location_id)
        before_label = _place_label(db, asset)
        movement = asset_movement.begin(
            asset,
            movement_type=MovementType.ASSIGN
            if not ticket.rental_returned
            else MovementType.RETURN,
            quantity=asset.quantity,
            moved_at=now_utc(),
            moved_by_id=user.id if user else None,
            reference_type="service_ticket",
            reference_id=ticket.id,
        )
        if ticket.rental_returned:
            asset.store_id = None
            asset_rules.apply_status(db, asset, item)
        else:
            if store is None:
                msgs.append(
                    f"S/N {sn}: 기록에 매장이 없어 '렌탈 중'으로 바꾸지 못했습니다."
                )
                continue
            asset.store_id = store.id
            asset.set_no = 0
            asset_rules.apply_status(db, asset, item)
        if (asset.status_item_id, asset.store_id, asset.location_id) == before:
            latest = db.scalar(
                select(AssetMovement)
                .where(AssetMovement.asset_id == asset.id)
                .order_by(
                    AssetMovement.created_at.desc(),
                    AssetMovement.moved_at.desc(),
                    AssetMovement.id.desc(),
                )
                .limit(1)
            )
            if (
                latest is not None
                and latest.reference_type == "service_ticket"
                and latest.reference_id == ticket.id
            ):
                continue
        asset.updated_by_id = user.id if user else None
        asset_movement.finish(movement, asset)
        movement.reason = f"대응 기록 {ticket.ticket_no} 렌탈" + (
            " 회수" if ticket.rental_returned else ""
        )
        db.add(movement)
        msgs.append(
            f"재고 {asset.name} {sn}: {before_label} → {_place_label(db, asset)}"
        )
    return msgs


def unsync_rental_assets(
    db: Session,
    ticket: ServiceTicket,
    previous_serials: str | None,
    user: User,
) -> list[str]:
    """Return removed rentals only while this ticket still owns their latest movement."""
    kept = (
        {sn.casefold() for sn in split_serials(ticket.rental_serials)}
        if ticket.is_rental and ticket.deleted_at is None
        else set()
    )
    notices: list[str] = []
    for sn in split_serials(previous_serials):
        if sn.casefold() in kept:
            continue
        asset = asset_rules.find_asset_by_serial(db, sn)
        if asset is None or asset.status != AssetStatus.LOANED:
            continue
        latest = db.scalar(
            select(AssetMovement)
            .where(AssetMovement.asset_id == asset.id)
            .order_by(
                AssetMovement.created_at.desc(),
                AssetMovement.moved_at.desc(),
                AssetMovement.id.desc(),
            )
            .limit(1)
        )
        if (
            latest is None
            or latest.reference_type != "service_ticket"
            or latest.reference_id != ticket.id
        ):
            continue
        item = asset_rules.find_status_item_by_rule(db, "clear", AssetStatus.IN_STOCK)
        if item is None:
            raise AppError(
                "RENTAL_RETURN_STATUS_MISSING",
                "렌탈 연결을 해제하려면 창고 상태를 먼저 설정하세요.",
            )
        movement = asset_movement.begin(
            asset,
            movement_type=MovementType.RETURN,
            quantity=asset.quantity,
            moved_at=now_utc(),
            moved_by_id=user.id,
            reference_type="service_ticket",
            reference_id=ticket.id,
            reason=f"대응 기록 {ticket.ticket_no} 렌탈 연결 해제",
        )
        asset_rules.apply_status(db, asset, item)
        asset.holder_id = None
        asset.updated_by_id = user.id
        asset_movement.finish(movement, asset)
        db.add(movement)
        notices.append(f"재고 {asset.name} {sn}: 렌탈 연결 해제 → {item.name}")
    return notices


def _place_label(db: Session, asset) -> str:
    status = (
        db.get(CodeItem, asset.status_item_id).name
        if asset.status_item_id
        else asset.status.value
    )
    where = ""
    if asset.store_id:
        s = db.get(Store, asset.store_id)
        where = s.name if s else ""
    elif asset.location_id:
        from app.models.inventory import Location

        loc = db.get(Location, asset.location_id)
        where = loc.name if loc else ""
    return f"{status} {where}".strip()


# --------------------------------------------------------------- 매장
def resolve_store(db: Session, store_id: uuid.UUID | None) -> Store | None:
    if store_id is None:
        return None
    store = db.scalar(
        select(Store).where(Store.id == store_id, Store.deleted_at.is_(None))
    )
    if store is None:
        raise AppError(
            "STORE_NOT_FOUND", "매장을 찾을 수 없습니다.", http.HTTP_404_NOT_FOUND
        )
    return store


def as_date(v) -> date | None:
    return v if isinstance(v, date) else None


# 바깥에서 쓰는 이름
check_code = _item
