"""Shared ticket presentation used by service and store APIs."""

from __future__ import annotations

import uuid

from fastapi import status
from sqlalchemy import func, select
from sqlalchemy.orm import Session, selectinload

from app.core.errors import AppError
from app.models.admin import Attachment, CodeItem
from app.models.service import (
    ServiceLog,
    ServiceTicket,
    ServiceTicketCause,
    ServiceTicketResponder,
)
from app.models.store import Store
from app.models.user import User
from app.schemas.common import CodeItemBrief, UserBrief
from app.schemas.service import (
    CauseOut,
    ServiceTicketDetail,
    ServiceTicketOut,
    StoreRef,
)


def _extras(db: Session, tickets: list[ServiceTicket]) -> dict[uuid.UUID, dict]:
    """목록 한 장에 필요한 곁 정보를 쿼리 몇 번으로. 건마다 따로 물으면 수십 번 나간다."""
    ids = [t.id for t in tickets]
    out: dict[uuid.UUID, dict] = {
        t.id: {
            "causes": [],
            "responders": [],
            "responder_ids": [],
            "store_name": None,
            "brand_name": None,
            "brand_id": None,
            "store_closed": False,
            "fault_name": None,
            "rental_type": None,
            "attachment_count": 0,
            "log_count": 0,
        }
        for t in tickets
    }
    if not ids:
        return out

    code_ids: set[uuid.UUID] = set()
    cause_rows = db.scalars(
        select(ServiceTicketCause)
        .where(ServiceTicketCause.ticket_id.in_(ids))
        .order_by(ServiceTicketCause.seq)
    ).all()
    resp_rows = db.scalars(
        select(ServiceTicketResponder)
        .where(ServiceTicketResponder.ticket_id.in_(ids))
        .order_by(ServiceTicketResponder.seq)
    ).all()
    for c in cause_rows:
        code_ids |= {x for x in (c.category_id, c.symptom_id, c.maker_id) if x}
    for r in resp_rows:
        if r.responder_id:
            code_ids.add(r.responder_id)
    for t in tickets:
        code_ids |= {x for x in (t.fault_id, t.rental_type_id) if x}

    store_ids = {t.store_id for t in tickets if t.store_id}
    stores = (
        {
            s.id: s
            for s in db.scalars(select(Store).where(Store.id.in_(store_ids))).all()
        }
        if store_ids
        else {}
    )
    code_ids |= {s.brand_id for s in stores.values() if s.brand_id}
    codes = (
        {
            c.id: c
            for c in db.scalars(select(CodeItem).where(CodeItem.id.in_(code_ids))).all()
        }
        if code_ids
        else {}
    )

    def name(cid):
        item = codes.get(cid) if cid else None
        return item.name if item else None

    for c in cause_rows:
        out[c.ticket_id]["causes"].append(
            {
                "row": c,
                "category": name(c.category_id) or "",
                "symptom": name(c.symptom_id) or "",
                "maker": name(c.maker_id) or "",
            }
        )
    for r in resp_rows:
        n = name(r.responder_id)
        if n:
            out[r.ticket_id]["responders"].append(n)
            out[r.ticket_id]["responder_ids"].append(r.responder_id)
    for t in tickets:
        e = out[t.id]
        s = stores.get(t.store_id) if t.store_id else None
        if s is not None:
            e["store_name"] = s.name
            e["brand_id"] = s.brand_id
            e["brand_name"] = name(s.brand_id)
            e["store_closed"] = s.is_closed
        e["fault_name"] = name(t.fault_id)
        e["rental_type"] = name(t.rental_type_id)

    for tid, n in db.execute(
        select(Attachment.entity_id, func.count(Attachment.id))
        .where(
            Attachment.entity_type == "service_ticket",
            Attachment.entity_id.in_(ids),
            Attachment.deleted_at.is_(None),
        )
        .group_by(Attachment.entity_id)
    ).all():
        if tid in out:
            out[tid]["attachment_count"] = n
    for tid, n in db.execute(
        select(ServiceLog.ticket_id, func.count(ServiceLog.id))
        .where(ServiceLog.ticket_id.in_(ids))
        .group_by(ServiceLog.ticket_id)
    ).all():
        out[tid]["log_count"] = n
    out["_codes"] = codes
    return out


def _cause_label(c: dict) -> str:
    label = f"{c['category']} > {c['symptom']}" if c["symptom"] else c["category"]
    return f"{label} ({c['maker']})" if c["maker"] else label


def _apply_extras(out: ServiceTicketOut, e: dict) -> ServiceTicketOut:
    out.cause_labels = [_cause_label(c) for c in e["causes"]]
    out.responder_names = list(e["responders"])
    out.store_name = e["store_name"]
    out.brand_name = e["brand_name"]
    out.attachment_count = e["attachment_count"]
    out.log_count = e["log_count"]
    return out


def _enrich(db: Session, tickets: list[ServiceTicket]) -> list[ServiceTicketOut]:
    extras = _extras(db, tickets)
    return [
        _apply_extras(ServiceTicketOut.model_validate(t), extras[t.id]) for t in tickets
    ]


def _detail(db: Session, ticket_id: uuid.UUID) -> ServiceTicketDetail:
    ticket = db.scalar(
        select(ServiceTicket)
        .where(ServiceTicket.id == ticket_id, ServiceTicket.deleted_at.is_(None))
        .options(
            selectinload(ServiceTicket.parts),
            selectinload(ServiceTicket.logs),
            selectinload(ServiceTicket.customer),
        )
    )
    if ticket is None:
        raise AppError(
            "NOT_FOUND", "접수 건을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND
        )

    out = ServiceTicketDetail.model_validate(ticket)
    out.resolution_minutes = ticket.resolution_minutes
    extras = _extras(db, [ticket])
    e = extras[ticket.id]
    codes = extras["_codes"]
    _apply_extras(out, e)

    def brief(cid):
        item = codes.get(cid) if cid else None
        return CodeItemBrief.model_validate(item) if item else None

    out.causes = [
        CauseOut(
            id=c["row"].id,
            seq=c["row"].seq,
            category_id=c["row"].category_id,
            symptom_id=c["row"].symptom_id,
            maker_id=c["row"].maker_id,
            category=brief(c["row"].category_id),
            symptom=brief(c["row"].symptom_id),
            maker=brief(c["row"].maker_id),
        )
        for c in e["causes"]
    ]
    out.responders = [b for b in (brief(rid) for rid in e["responder_ids"]) if b]
    out.fault = brief(ticket.fault_id)
    out.rental_type = brief(ticket.rental_type_id)
    if ticket.store_id:
        s = db.get(Store, ticket.store_id)
        if s is not None:
            out.store = StoreRef(
                id=s.id,
                name=s.name,
                brand_id=s.brand_id,
                brand_name=e["brand_name"],
                is_closed=s.is_closed,
            )
    if ticket.assignee_id:
        assignee = db.get(User, ticket.assignee_id)
        if assignee:
            out.assignee = UserBrief.model_validate(assignee)
    author_ids = {l.author_id for l in ticket.logs if l.author_id}
    authors = (
        {u.id: u for u in db.scalars(select(User).where(User.id.in_(author_ids))).all()}
        if author_ids
        else {}
    )
    for log_out, log in zip(out.logs, ticket.logs):
        u = authors.get(log.author_id) if log.author_id else None
        log_out.author = UserBrief.model_validate(u) if u else None
    return out
