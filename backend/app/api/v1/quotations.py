"""Append-only quotation versions attached to service tickets."""

import base64
import hashlib
import re
import uuid
from datetime import datetime, timedelta
from decimal import ROUND_HALF_UP, Decimal
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Response
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError, OperationalError

from app.core.deps import Client, CurrentUser, DbSession
from app.core.errors import AppError
from app.core.security import now_utc
from app.models.enums import ROLE_LEVEL, AuditAction, ModuleKey, Role
from app.models.quotation import QuotationRevision
from app.models.service import ServiceTicket
from app.models.store import Store
from app.schemas.quotation import QuoteCreate, QuoteDetail, QuoteSummary
from app.services import audit, quotation_checklist, settings_store
from app.services.quotation_pdf import render

router = APIRouter(
    prefix="/service/tickets/{ticket_id}/quotations", tags=["quotations"]
)


def ticket(db, ticket_id, lock=False):
    stmt = select(ServiceTicket).where(
        ServiceTicket.id == ticket_id, ServiceTicket.deleted_at.is_(None)
    )
    value = db.scalar(stmt.with_for_update() if lock else stmt)
    if value is None:
        raise AppError("NOT_FOUND", "대응 건을 찾을 수 없습니다.", 404)
    return value


def can_delete(row, user):
    return row.created_by_id == user.id or ROLE_LEVEL[user.role] >= ROLE_LEVEL[Role.MANAGER]


def out(row, detail=False, user=None):
    result = {
        "can_delete": can_delete(row, user) if user else False,
        "id": str(row.id),
        "version": row.version,
        "filename": row.filename,
        "sha256": row.sha256,
        "created_at": row.created_at.isoformat(),
        "author_name": row.author_name,
        "total": row.snapshot["total"],
        "revision_note": row.snapshot["revision_note"],
    }
    if detail:
        result["snapshot"] = row.snapshot
    return result


# 접수 저장 전에 견적서를 미리 쓰는 화면용. 대응 건 대신 접수 폼 값으로 기본값을 만든다.
draft_router = APIRouter(prefix="/service/quotations", tags=["quotations"])


@router.get("/defaults")
def defaults(ticket_id: uuid.UUID, db: DbSession, _: CurrentUser):
    t = ticket(db, ticket_id)
    store = db.get(Store, t.store_id) if t.store_id else None
    return _defaults(
        db, store, t.customer_name, t.contact_name, t.contact_phone, t.site_address
    )


@draft_router.get("/defaults")
def draft_defaults(
    db: DbSession,
    _: CurrentUser,
    store_id: uuid.UUID | None = None,
    customer_name: str | None = None,
    contact_name: str | None = None,
    contact_phone: str | None = None,
    site_address: str | None = None,
):
    store = db.get(Store, store_id) if store_id else None
    return _defaults(
        db, store, customer_name, contact_name, contact_phone, site_address
    )


@draft_router.get("/checklist")
def checklist(db: DbSession, _: CurrentUser):
    """견적서 작성 화면의 체크리스트. 관리자가 사용 중지한 항목은 뺀다."""
    return quotation_checklist.active(
        settings_store.get(db, ModuleKey.SERVICE, quotation_checklist.KEY, [])
    )


def _defaults(db, store, customer_name, contact_name, contact_phone, site_address):
    empty = {"company": "", "contact": "", "address": "", "phone": "", "email": ""}
    supplier = settings_store.get(db, ModuleKey.SERVICE, "quotation_supplier", {})
    today = datetime.now(ZoneInfo("Asia/Seoul")).date()
    return {
        "supplier": {
            key: str(supplier.get(key, "") or "") if isinstance(supplier, dict) else ""
            for key in empty
        },
        "recipient": {
            **empty,
            "company": store.name if store else (customer_name or ""),
            "contact": contact_name or (store.contact_name if store else None) or "",
            "phone": contact_phone or (store.contact_phone if store else None) or "",
            "address": site_address or (store.address if store else None) or "",
        },
        "bank_account": settings_store.get(
            db, ModuleKey.SERVICE, "quotation_bank_account", ""
        ),
        "quote_date": today.isoformat(),
        "valid_until": (today + timedelta(days=30)).isoformat(),
        "notes": "",
        "items": [],
    }


@router.get("", response_model=list[QuoteSummary])
def revisions(ticket_id: uuid.UUID, db: DbSession, user: CurrentUser):
    ticket(db, ticket_id)
    return [
        out(r, user=user)
        for r in db.scalars(
            select(QuotationRevision)
            .where(QuotationRevision.ticket_id == ticket_id, QuotationRevision.deleted_at.is_(None))
            .order_by(QuotationRevision.version.desc())
        ).all()
    ]


@router.post("", status_code=201, response_model=QuoteDetail)
def create(
    ticket_id: uuid.UUID,
    payload: QuoteCreate,
    db: DbSession,
    user: CurrentUser,
    client: Client,
):
    t = ticket(db, ticket_id, lock=True)
    latest = (
        db.scalar(
            select(func.max(QuotationRevision.version)).where(
                QuotationRevision.ticket_id == ticket_id
            )
        )
        or 0
    )
    latest_visible = db.scalar(select(func.max(QuotationRevision.version)).where(
        QuotationRevision.ticket_id == ticket_id,
        QuotationRevision.deleted_at.is_(None),
    )) or 0
    if payload.base_version != latest_visible:
        raise AppError(
            "QUOTE_CONFLICT",
            "다른 견적 버전이 저장되었습니다. 목록을 새로고침한 뒤 최신 버전으로 수정해 주세요.",
            409,
        )
    version = latest + 1
    snapshot = payload.model_dump(mode="json", exclude={"base_version"})
    subtotal = 0
    for item, original in zip(snapshot["items"], payload.items):
        quantity = format(original.quantity, "f")
        item["quantity"] = (
            quantity.rstrip("0").rstrip(".") if "." in quantity else quantity
        )
        item["unit_price"] = str(int(original.unit_price))
        item["amount"] = int(
            (original.quantity * original.unit_price).quantize(
                Decimal(1), rounding=ROUND_HALF_UP
            )
        )
        subtotal += item["amount"]
    snapshot.update(
        subtotal=subtotal,
        vat=int(
            (Decimal(subtotal) * Decimal("0.1")).quantize(
                Decimal(1), rounding=ROUND_HALF_UP
            )
        ),
    )
    snapshot["total"] = snapshot["subtotal"] + snapshot["vat"]
    safe_no = re.sub(r"[^A-Za-z0-9_-]", "_", t.ticket_no)[:70]
    snapshot["document_no"] = f"QT-{safe_no}-v{version:03}"
    snapshot["ticket_no"] = t.ticket_no
    identifier = uuid.uuid4()
    signature = None
    configured = settings_store.get(db, ModuleKey.SERVICE, "quotation_signature", {})
    if (
        isinstance(configured, dict)
        and all(
            configured.get(key) == snapshot["supplier"][key]
            for key in ("company", "contact")
        )
        and configured.get("png_base64")
    ):
        signature = base64.b64decode(configured["png_base64"], validate=True)
    snapshot["signature_sha256"] = (
        hashlib.sha256(signature).hexdigest() if signature else None
    )
    logo = None
    configured_logo = settings_store.get(db, ModuleKey.SERVICE, "quotation_logo", {})
    if (
        isinstance(configured_logo, dict)
        and (
            configured_logo.get("apply_to_all") is True
            or configured_logo.get("company") == snapshot["supplier"]["company"]
        )
        and configured_logo.get("png_base64")
    ):
        logo = base64.b64decode(configured_logo["png_base64"], validate=True)
    snapshot["logo_sha256"] = hashlib.sha256(logo).hexdigest() if logo else None
    pdf = render(snapshot, signature=signature, logo=logo)
    row = QuotationRevision(
        id=identifier,
        ticket_id=ticket_id,
        version=version,
        snapshot=snapshot,
        filename=f"{snapshot['document_no']}_{identifier.hex[:8]}.pdf",
        pdf=pdf,
        sha256=hashlib.sha256(pdf).hexdigest(),
        created_by_id=user.id,
        author_name=user.full_name,
    )
    db.add(row)
    audit.record(
        db,
        action=AuditAction.CREATE,
        actor=user,
        module=ModuleKey.SERVICE,
        entity_type="service_ticket",
        entity_id=ticket_id,
        summary=f"견적서 {snapshot['document_no']} 저장",
        client=client,
    )
    try:
        db.commit()
    except OperationalError as exc:
        db.rollback()
        if db.bind.dialect.name != "sqlite" or (
            getattr(exc.orig, "sqlite_errorcode", 0) & 0xFF
        ) not in {5, 6}:
            raise
        raise AppError(
            "QUOTE_CONFLICT",
            "동시에 저장 중인 견적이 있습니다. 최신 목록을 확인한 후 다시 저장해 주세요.",
            409,
        ) from None
    except IntegrityError:
        db.rollback()
        raise AppError(
            "QUOTE_CONFLICT",
            "다른 견적 버전이 저장되었습니다. 최신 목록을 확인해 주세요.",
            409,
        ) from None
    return out(row, True, user)


def revision(db, ticket_id, revision_id):
    ticket(db, ticket_id)
    row = db.scalar(
        select(QuotationRevision).where(
            QuotationRevision.ticket_id == ticket_id,
            QuotationRevision.id == revision_id,
            QuotationRevision.deleted_at.is_(None),
        )
    )
    if row is None:
        raise AppError("NOT_FOUND", "견적 버전을 찾을 수 없습니다.", 404)
    return row


@router.get("/{revision_id}", response_model=QuoteDetail)
def detail(ticket_id: uuid.UUID, revision_id: uuid.UUID, db: DbSession, user: CurrentUser):
    return out(revision(db, ticket_id, revision_id), True, user)


@router.get("/{revision_id}/pdf")
def download(
    ticket_id: uuid.UUID, revision_id: uuid.UUID, db: DbSession, _: CurrentUser
):
    row = revision(db, ticket_id, revision_id)
    return Response(
        content=row.pdf,
        media_type="application/pdf",
        headers={
            "Content-Disposition": f'attachment; filename="{row.filename}"',
            "Cache-Control": "private, no-store",
            "X-Content-Type-Options": "nosniff",
        },
    )


@router.delete("/{revision_id}")
def delete_revision(ticket_id: uuid.UUID, revision_id: uuid.UUID, db: DbSession,
                    user: CurrentUser, client: Client):
    ticket(db, ticket_id, lock=True)
    row = revision(db, ticket_id, revision_id)
    if not can_delete(row, user):
        raise AppError("FORBIDDEN", "작성자 또는 팀장 이상만 견적서를 삭제할 수 있습니다.", 403)
    row.deleted_at = now_utc()
    audit.record(db, action=AuditAction.DELETE, actor=user, module=ModuleKey.SERVICE,
                 entity_type="service_ticket", entity_id=ticket_id,
                 summary=f"견적서 {row.snapshot['document_no']} 삭제", client=client)
    db.commit()
    return {"message": "견적서가 삭제되었습니다."}
