"""구 서버(CS_Record)의 재고 상태 규칙.

상태 13종(창고 · 사무실 · 설치 · 렌탈 중 · AS 대기 · AS 반출 · 바른 회수 · … · 폐기 ·
미상)은 코드 마스터 ASSET_STATUS 에 있고, 항목마다 `extra` 에 규칙이 적혀 있다::

    {"rule": "store" | "as" | "clear" | "free", "enum": "IN_USE", "place": "창고"}

- store : 매장이 있어야 하는 상태 (설치 · 렌탈 중). 우리 위치(창고)는 비운다.
- as    : AS 대기 · AS 반출 - 매장에 둔 채 상태만 바뀐다. 매장 재고에서 빠지지 않는다.
- clear : 창고 · 사무실 · 미상 - 매장·세트를 자동으로 비우고 `place` 이름의 위치로 보낸다.
- free  : 그 밖(브랜드 회수 · 폐기) - 매장을 비우되 위치는 요청대로 둔다.

`enum` 은 Asset.status(6종 enum)를 세부 상태에서 유도하는 값이다. 두 칸이 따로
들어오면 어긋날 수 있으므로, 세부 상태를 정하면 enum 은 여기서 따라간다.

규칙을 이름이 아니라 extra 에 두는 이유: 관리 화면에서 항목 이름을 바꿔도(예:
'AS 반출' -> 'AS 출고') 동작이 유지돼야 한다. 이름 기반 표는 extra 가 비어 있는
옛 행을 채우는 데만 쓴다(bootstrap 이 서버를 켤 때 한 번 채운다).
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Literal

from fastapi import status as http
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core.errors import AppError
from app.models.admin import CodeGroup, CodeItem
from app.models.enums import AssetStatus
from app.models.inventory import Asset, Location
from app.models.store import Store
from app.services import code_master

STATUS_GROUP = "ASSET_STATUS"
CATEGORY_GROUP = "ASSET_CATEGORY"
MAKER_GROUP = "ASSET_MAKER"
MODEL_GROUP = "ASSET_MODEL"

RuleKind = Literal["store", "as", "clear", "free"]


@dataclass(frozen=True, slots=True)
class StatusRule:
    kind: RuleKind
    enum: AssetStatus
    place: str | None = None  # clear 규칙일 때 보낼 위치 이름 (창고 · 사무실)

    def as_extra(self) -> dict:
        d: dict = {"rule": self.kind, "enum": self.enum.value}
        if self.place:
            d["place"] = self.place
        return d


# 이름 -> 규칙. 구 서버 app.py 의 STORE_STATUSES / AS_STATUSES / CLEAR_BRAND_STATUSES
# 를 그대로 옮긴 것. extra 가 없는 항목에만 쓴다.
RULES_BY_NAME: dict[str, StatusRule] = {
    "창고": StatusRule("clear", AssetStatus.IN_STOCK, "창고"),
    "사무실": StatusRule("clear", AssetStatus.IN_STOCK, "사무실"),
    "미상": StatusRule("clear", AssetStatus.LOST),
    "설치": StatusRule("store", AssetStatus.IN_USE),
    "렌탈 중": StatusRule("store", AssetStatus.LOANED),
    "AS 대기": StatusRule("as", AssetStatus.REPAIR),
    "AS 반출": StatusRule("as", AssetStatus.REPAIR),
    "폐기": StatusRule("free", AssetStatus.DISPOSED),
}

# 구 서버 기본 상태 목록과 순서. 새 저장소를 처음 만들 때 이 순서로 심는다.
DEFAULT_STATUSES: list[str] = [
    "창고",
    "사무실",
    "설치",
    "렌탈 중",
    "AS 대기",
    "AS 반출",
    "바른 회수",
    "자담 회수",
    "삼성 회수",
    "해외 회수",
    "기타 회수",
    "폐기",
    "미상",
]

# 매장 미운영 때 장비를 보낼 상태. 브랜드 이름과 회수 상태 이름이 다른 것만 적는다.
# 그 밖은 '<브랜드> 회수' 가 목록에 있으면 그것.
CLOSE_RECOVER_ALIAS: dict[str, str] = {"바른치킨": "바른 회수", "자담치킨": "자담 회수"}


def rule_by_name(name: str) -> StatusRule:
    if name in RULES_BY_NAME:
        return RULES_BY_NAME[name]
    if name.endswith("회수"):
        return StatusRule("free", AssetStatus.IN_STOCK)
    return StatusRule("free", AssetStatus.IN_STOCK)


def rule_of(item: CodeItem) -> StatusRule:
    """항목의 규칙. extra 가 채워져 있으면 그것, 없으면 이름으로 추정."""
    extra = item.extra if isinstance(item.extra, dict) else {}
    kind = extra.get("rule")
    if kind in ("store", "as", "clear", "free"):
        try:
            enum = AssetStatus(extra.get("enum") or rule_by_name(item.name).enum.value)
        except ValueError:
            enum = rule_by_name(item.name).enum
        return StatusRule(kind, enum, extra.get("place") or None)
    return rule_by_name(item.name)


# --------------------------------------------------------------- lookups
def status_group(db: Session) -> CodeGroup | None:
    return db.scalar(select(CodeGroup).where(CodeGroup.code == STATUS_GROUP))


def status_items(db: Session, active_only: bool = True) -> list[CodeItem]:
    return code_master.items(db, STATUS_GROUP, active_only=active_only)


def find_status_item(db: Session, name: str) -> CodeItem | None:
    group = status_group(db)
    if group is None:
        return None
    return db.scalar(
        select(CodeItem).where(
            CodeItem.group_id == group.id,
            CodeItem.name == name,
            CodeItem.deleted_at.is_(None),
        )
    )


def find_status_item_by_rule(
    db: Session, kind: RuleKind, enum: AssetStatus | None = None
) -> CodeItem | None:
    """규칙 종류(와 enum)로 첫 항목을 찾는다. 이름이 바뀌어도 동작하게."""
    for item in status_items(db):
        r = rule_of(item)
        if r.kind == kind and (enum is None or r.enum == enum):
            return item
    return None


def load_status_item(db: Session, item_id: uuid.UUID) -> CodeItem:
    item = db.get(CodeItem, item_id)
    if item is None or item.deleted_at is not None:
        raise AppError(
            "STATUS_NOT_FOUND", "상태 코드를 찾을 수 없습니다.", http.HTTP_404_NOT_FOUND
        )
    group = status_group(db)
    if group is None or item.group_id != group.id:
        raise AppError(
            "STATUS_NOT_FOUND", "자산 상태 코드가 아닙니다.", http.HTTP_400_BAD_REQUEST
        )
    return item


def location_by_name(db: Session, name: str) -> Location | None:
    return db.scalar(
        select(Location)
        .where(
            Location.name == name,
            Location.deleted_at.is_(None),
            Location.is_active.is_(True),
        )
        .order_by(Location.sort_order)
    )


def load_store(db: Session, store_id: uuid.UUID) -> Store:
    store = db.scalar(
        select(Store).where(Store.id == store_id, Store.deleted_at.is_(None))
    )
    if store is None:
        raise AppError(
            "STORE_NOT_FOUND",
            "매장을 찾을 수 없습니다. [매장]에서 먼저 추가하세요.",
            http.HTTP_404_NOT_FOUND,
        )
    return store


def category_name(db: Session, category_id: uuid.UUID | None) -> str | None:
    if category_id is None:
        return None
    item = db.get(CodeItem, category_id)
    return item.name if item else None


# --------------------------------------------------------------- the rule
def apply_status(
    db: Session,
    asset: Asset,
    item: CodeItem,
    *,
    requested_location_id: uuid.UUID | None = None,
) -> None:
    """세부 상태를 자산에 적용하고 매장·위치·세트를 규칙대로 정리한다.

    `asset.store_id` 는 호출 전에 목적지 매장으로 맞춰 둔다(있으면). 위치는
    `requested_location_id`(요청) 가 있으면 그것을, 없으면 현재 값을 바탕으로 한다.
    """
    rule = rule_of(item)
    asset.status_item_id = item.id
    asset.status = rule.enum

    if rule.kind == "store":
        if asset.store_id is None:
            raise AppError(
                "STORE_REQUIRED",
                f'상태가 "{item.name}"이면 매장을 고르세요.',
                http.HTTP_400_BAD_REQUEST,
            )
        asset.location_id = None
        return

    if rule.kind == "as":
        # 매장에 있으면 그대로 두고 상태만 바뀐다. 매장이 없으면 장소(위치)에 둔다.
        if asset.store_id is not None:
            asset.location_id = None
        elif requested_location_id is not None:
            asset.location_id = requested_location_id
        return

    # clear · free: 매장을 떠난다. 세트는 그 매장 안에서만 뜻이 있다.
    asset.store_id = None
    asset.set_no = 0
    if requested_location_id is not None:
        # 자리를 직접 골랐으면 그 자리 (구 서버도 place 를 적으면 그대로 두었다)
        asset.location_id = requested_location_id
        return
    if rule.kind == "clear":
        target = location_by_name(db, rule.place) if rule.place else None
        if target is not None:
            asset.location_id = target.id
        elif rule.enum == AssetStatus.LOST:
            asset.location_id = None


def default_item_for_destination(
    db: Session,
    *,
    store_id: uuid.UUID | None,
    location_id: uuid.UUID | None,
    leaving_store: bool = False,
) -> CodeItem | None:
    """상태를 고르지 않고 자리만 옮길 때 어울리는 세부 상태.

    매장으로 가면 '설치', 이름이 창고·사무실인 위치로 가면 그 이름의 상태. 매장을 떠나
    다른 위치로 가면 '창고'(매장 상태를 달고 창고에 있을 수는 없으니). 그 밖은 건드리지
    않는다(None). 구 서버는 이동 때 상태를 반드시 고르게 했는데, 여기서는 빠졌을 때 채워 준다.
    """
    if store_id is not None:
        return find_status_item(db, "설치") or find_status_item_by_rule(
            db, "store", AssetStatus.IN_USE
        )
    if location_id is not None:
        loc = db.get(Location, location_id)
        if loc is not None:
            for item in status_items(db):
                r = rule_of(item)
                if r.kind == "clear" and r.place == loc.name:
                    return item
    if leaving_store:
        return find_status_item(db, "창고") or find_status_item_by_rule(
            db, "clear", AssetStatus.IN_STOCK
        )
    return None


def is_at_store_rule(item: CodeItem | None) -> bool:
    """매장에 있는 상태인가 (설치 · 렌탈 중 · AS 대기 · AS 반출)."""
    return item is not None and rule_of(item).kind in ("store", "as")


def is_movable_on_close(item: CodeItem | None) -> bool:
    """미운영 때 회수 대상인가: 설치 · AS 대기 · AS 반출. 렌탈 중은 대응 기록이 관리한다."""
    if item is None:
        return False
    r = rule_of(item)
    return r.kind == "as" or (r.kind == "store" and r.enum != AssetStatus.LOANED)


def recover_options(db: Session, brand_name: str | None) -> list[CodeItem]:
    """미운영 시 장비를 보낼 수 있는 곳: [브랜드 회수 상태(있으면), 창고, 사무실]. 첫 항목이 기본값."""
    items = {i.name: i for i in status_items(db)}
    out: list[CodeItem] = []
    if brand_name:
        own = CLOSE_RECOVER_ALIAS.get(brand_name, f"{brand_name} 회수")
        if own in items:
            out.append(items[own])
    for name in ("창고", "사무실"):
        if name in items:
            out.append(items[name])
    return out


# --------------------------------------------------------------- serials
def normalise_serial(serial: str | None) -> str | None:
    s = (serial or "").strip()
    return s or None


def serial_taken(
    db: Session,
    category_id: uuid.UUID | None,
    serial: str,
    exclude_id: uuid.UUID | None = None,
) -> Asset | None:
    """같은 종류 안에서 S/N 은 하나다 (구 서버 UNIQUE(kind, serial)). 대소문자는 무시."""
    stmt = select(Asset).where(
        Asset.deleted_at.is_(None),
        func.lower(Asset.serial_no) == serial.lower(),
    )
    if category_id is None:
        stmt = stmt.where(Asset.category_id.is_(None))
    else:
        stmt = stmt.where(Asset.category_id == category_id)
    if exclude_id is not None:
        stmt = stmt.where(Asset.id != exclude_id)
    return db.scalar(stmt.limit(1))


def find_asset_by_serial(
    db: Session, serial: str, category_id: uuid.UUID | None = None
) -> Asset | None:
    stmt = select(Asset).where(
        Asset.deleted_at.is_(None),
        func.lower(Asset.serial_no) == serial.strip().lower(),
    )
    if category_id is not None:
        stmt = stmt.where(Asset.category_id == category_id)
    return db.scalar(stmt.order_by(Asset.created_at).limit(1))


def next_managed_serial(
    db: Session, category_id: uuid.UUID, prefix: str = "NG-"
) -> str:
    """비전동 그리퍼 관리 번호: NG-0001, NG-0002 … (S/N 이 없는 장비를 세기 위한 번호)."""
    rows = db.scalars(
        select(Asset.serial_no).where(
            Asset.category_id == category_id,
            Asset.serial_no.like(f"{prefix}%"),
        )
    ).all()
    n = 0
    for s in rows:
        try:
            n = max(n, int((s or "")[len(prefix) :]))
        except ValueError:
            continue
    return f"{prefix}{n + 1:04d}"
