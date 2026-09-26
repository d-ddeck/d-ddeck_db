"""Inventory overview and export lookup data, independent of HTTP routing."""

from __future__ import annotations

from collections import Counter, defaultdict
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.admin import CodeItem
from app.models.enums import (
    AssetStatus,
)
from app.models.inventory import Asset, Location
from app.models.service import ServiceTicket
from app.models.store import Store
from app.schemas.common import CodeItemBrief
from app.schemas.inventory import (
    AttentionAsset,
    InventoryOverview,
    OverviewRow,
    RentalAsset,
)
from app.services import (
    asset_rules,
    code_master,
    stats,
)
from app.services.ticket_rules import split_serials


class _OverviewContext:
    """현황 · 엑셀이 같이 쓰는 이름표. 쿼리 몇 번으로 종류 · 상태 · 매장 · 브랜드 · 위치 이름을 끌어온다."""

    def __init__(self, db: Session, assets: list[Asset]):
        self.db = db
        self.kinds = _group_items(db, asset_rules.CATEGORY_GROUP, active_only=False)
        self.statuses = asset_rules.status_items(db, active_only=False)
        self.brands = _group_items(db, "STORE_BRAND", active_only=False)
        self._kind = {k.id: k for k in self.kinds}
        self._status = {s.id: s for s in self.statuses}
        self._brand = {b.id: b for b in self.brands}
        store_ids = {a.store_id for a in assets if a.store_id}
        self._store = (
            {
                s.id: s
                for s in db.scalars(select(Store).where(Store.id.in_(store_ids))).all()
            }
            if store_ids
            else {}
        )
        loc_ids = {a.location_id for a in assets if a.location_id}
        self._loc = (
            {
                l.id: l
                for l in db.scalars(
                    select(Location).where(Location.id.in_(loc_ids))
                ).all()
            }
            if loc_ids
            else {}
        )

    def kind_name(self, cid):
        k = self._kind.get(cid) if cid else None
        return k.name if k else None

    def status_item(self, a: Asset) -> CodeItem | None:
        return self._status.get(a.status_item_id) if a.status_item_id else None

    def status_name(self, a: Asset):
        s = self.status_item(a)
        return s.name if s else None

    def store_name(self, sid):
        s = self._store.get(sid) if sid else None
        return s.name if s else None

    def brand_id_of(self, a: Asset):
        s = self._store.get(a.store_id) if a.store_id else None
        return s.brand_id if s else None

    def brand_name_of(self, a: Asset):
        b = self._brand.get(self.brand_id_of(a)) if self.brand_id_of(a) else None
        return b.name if b else None

    def location_name(self, lid):
        l = self._loc.get(lid) if lid else None
        return l.name if l else None


def _group_items(
    db: Session, group_code: str, active_only: bool = True
) -> list[CodeItem]:
    return code_master.items(db, group_code, active_only=active_only)


def build(db: Session) -> InventoryOverview:
    """구 서버 재고 › 현황. 상태×종류, 브랜드×종류(매장 설치), 장소×종류(미설치), 확인 목록(AS·미상), 렌탈 중."""
    assets = list(db.scalars(select(Asset).where(Asset.deleted_at.is_(None))).all())
    ctx = _OverviewContext(db, assets)
    used_kinds = {a.category_id for a in assets}
    kinds = [k for k in ctx.kinds if k.is_active or k.id in used_kinds]
    kind_key = lambda a: str(a.category_id) if a.category_id else "-"

    def rows(
        groups: dict, order: list[tuple[str, str, str | None]]
    ) -> list[OverviewRow]:
        out = []
        for key, label, color in order:
            cnt = groups.get(key)
            if cnt is None:
                continue
            out.append(
                OverviewRow(
                    key=key,
                    label=label,
                    color=color,
                    counts=dict(cnt),
                    total=sum(cnt.values()),
                )
            )
        return out

    by_status: dict[str, Counter] = defaultdict(Counter)
    by_brand: dict[str, Counter] = defaultdict(Counter)
    by_place: dict[str, Counter] = defaultdict(Counter)
    for a in assets:
        s = ctx.status_item(a)
        by_status[str(s.id) if s else a.status.value][kind_key(a)] += 1
        if a.store_id:
            bid = ctx.brand_id_of(a)
            by_brand[str(bid) if bid else "-"][kind_key(a)] += 1
        else:
            by_place[str(a.location_id) if a.location_id else "-"][kind_key(a)] += 1

    status_order = [(str(s.id), s.name, s.color) for s in ctx.statuses] + [
        (e.value, e.value, None) for e in AssetStatus
    ]
    brand_order = [(str(b.id), b.name, b.color) for b in ctx.brands] + [
        ("-", "(브랜드 없음)", None)
    ]
    place_ids = {a.location_id for a in assets if not a.store_id and a.location_id}
    places = sorted(
        (ctx._loc[l] for l in place_ids if l in ctx._loc),
        key=lambda l: (l.sort_order, l.name),
    )
    place_order = [(str(l.id), l.name, None) for l in places] + [
        ("-", "(장소 없음)", None)
    ]

    def brief(a: Asset) -> dict:
        return {
            "id": a.id,
            "asset_no": a.asset_no,
            "name": a.name,
            "category_id": a.category_id,
            "category_name": ctx.kind_name(a.category_id),
            "serial_no": a.serial_no,
            "status_name": ctx.status_name(a),
            "store_id": a.store_id,
            "store_name": ctx.store_name(a.store_id),
            "location_name": ctx.location_name(a.location_id),
            "note": a.note,
        }

    def needs_attention(a: Asset) -> bool:
        s = ctx.status_item(a)
        if s is not None:
            r = asset_rules.rule_of(s)
            return r.kind == "as" or r.enum == AssetStatus.LOST
        return a.status in (AssetStatus.REPAIR, AssetStatus.LOST)

    attention = sorted(
        (a for a in assets if needs_attention(a)),
        key=lambda a: (
            ctx.status_name(a) or "",
            ctx.kind_name(a.category_id) or "",
            a.serial_no or "",
        ),
    )

    # 렌탈 중: 그 S/N 이 적힌 미회수 렌탈 기록(최근 것)의 번호 · 회수 예정일 · D-day
    today = datetime.now(stats.LOCAL_TZ).date()
    loaned = [
        a
        for a in assets
        if (s := ctx.status_item(a)) is not None
        and asset_rules.rule_of(s).enum == AssetStatus.LOANED
        or (ctx.status_item(a) is None and a.status == AssetStatus.LOANED)
    ]
    open_rentals = list(
        db.scalars(
            select(ServiceTicket)
            .where(
                ServiceTicket.deleted_at.is_(None),
                ServiceTicket.is_rental.is_(True),
                ServiceTicket.rental_returned.is_(False),
            )
            .order_by(ServiceTicket.received_at.desc())
        ).all()
    )
    by_serial: dict[str, ServiceTicket] = {}
    for t in open_rentals:
        for sn in split_serials(t.rental_serials):
            by_serial.setdefault(sn.lower(), t)
    rentals = []
    for a in sorted(
        loaned,
        key=lambda a: (
            ctx.brand_name_of(a) or "",
            ctx.store_name(a.store_id) or "",
            ctx.kind_name(a.category_id) or "",
            a.serial_no or "",
        ),
    ):
        t = by_serial.get((a.serial_no or "").lower())
        rentals.append(
            RentalAsset(
                **brief(a),
                ticket_id=t.id if t else None,
                ticket_no=t.ticket_no if t else None,
                rented_at=t.received_at if t else None,
                due_date=t.rental_due_date if t else None,
                dday=(t.rental_due_date - today).days
                if t and t.rental_due_date
                else None,
            )
        )

    return InventoryOverview(
        total=len(assets),
        kinds=[CodeItemBrief.model_validate(k) for k in kinds],
        statuses=[CodeItemBrief.model_validate(s) for s in ctx.statuses if s.is_active],
        by_status=rows(by_status, status_order),
        by_brand=rows(by_brand, brand_order),
        by_place=rows(by_place, place_order),
        attention=[AttentionAsset(**brief(a)) for a in attention],
        rentals=rentals,
    )
