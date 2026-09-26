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
from app.models.enums import AuditAction, ModuleKey
from app.models.quotation import QuotationRevision
from app.models.service import ServiceTicket
from app.models.store import Store
from app.schemas.quotation import QuoteCreate, QuoteDetail, QuoteSummary
from app.services import audit, settings_store
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


def out(row, detail=False):
    result = {
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


@router.get("/defaults")
def defaults(ticket_id: uuid.UUID, db: DbSession, _: CurrentUser):
    t = ticket(db, ticket_id)
    store = db.get(Store, t.store_id) if t.store_id else None
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
            "company": store.name if store else (t.customer_name or ""),
            "contact": t.customer_name or "",
            "phone": t.contact_phone or "",
            "address": t.site_address or "",
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
def revisions(ticket_id: uuid.UUID, db: DbSession, _: CurrentUser):
    ticket(db, ticket_id)
    return [
        out(r)
        for r in db.scalars(
            select(QuotationRevision)
            .where(QuotationRevision.ticket_id == ticket_id)
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
    if payload.base_version != latest:
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
    pdf = render(snapshot, signature=signature)
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
    return out(row, True)


def revision(db, ticket_id, revision_id):
    ticket(db, ticket_id)
    row = db.scalar(
        select(QuotationRevision).where(
            QuotationRevision.ticket_id == ticket_id,
            QuotationRevision.id == revision_id,
        )
    )
    if row is None:
        raise AppError("NOT_FOUND", "견적 버전을 찾을 수 없습니다.", 404)
    return row


@router.get("/{revision_id}", response_model=QuoteDetail)
def detail(ticket_id: uuid.UUID, revision_id: uuid.UUID, db: DbSession, _: CurrentUser):
    return out(revision(db, ticket_id, revision_id), True)


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
