"""서비스(AS) module: ticket CRUD, work log, and the automatic statistics.

구 서버(CS_Record)의 대응 기록 규칙이 여기 붙어 있다: 매장(브랜드→매장), 과실,
서비스구분·증상·제조사 여러 쌍, 대응인원, 렌탈(재고 연동), 종결 규칙, 검색 조건,
엑셀 내려받기, 통계 표(크로스탭), 첫 화면(대시보드).
"""
from __future__ import annotations

import uuid
from datetime import datetime
from decimal import Decimal
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy import func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, selectinload

from app.core.deps import (
    Client,
    CurrentUser,
    DbSession,
    ManagerUser,
    PageParams,
)
from app.core.errors import AppError
from app.core.security import now_utc
from app.models.admin import Attachment, CodeItem
from app.models.enums import (
    OPEN_SERVICE_STATUSES,
    AuditAction,
    ModuleKey,
    NotificationType,
    ServiceChannel,
    ServicePriority,
    ServiceStatus,
)
from app.models.service import (
    Customer,
    ServiceLog,
    ServicePart,
    ServiceTicket,
    ServiceTicketCause,
    ServiceTicketResponder,
)
from app.models.store import Store
from app.models.user import User
from app.schemas.common import CodeItemBrief, Message, Page, UserBrief
from app.schemas.service import (
    CauseOut,
    Crosstab,
    CustomerCreate,
    CustomerOut,
    CustomerUpdate,
    RentalRow,
    ServiceDashboard,
    ServiceGrouped,
    ServiceLogIn,
    ServiceLogOut,
    ServicePartIn,
    ServicePartOut,
    ServiceStatusChange,
    ServiceSummary,
    ServiceTicketCreate,
    ServiceTicketDetail,
    ServiceTicketOut,
    ServiceTicketUpdate,
    ServiceTrend,
    StoreRef,
    StoreYears,
    TicketBrief,
    YearCount,
)
from app.services import audit, excel, notifications, settings_store, stats, ticket_rules

router = APIRouter(prefix="/service", tags=["service"])

SortKey = Literal[
    "received_desc", "received_asc", "due_asc", "priority_desc",
    "created_desc", "updated_desc",
]


# ================================================================== 공통 검색 조건
def ticket_filters(
    date_from: datetime | None = None,
    date_to: datetime | None = None,
    year: Annotated[int | None, Query(ge=2000, le=2100, description="발생 연도(한국 시각)")] = None,
    month: Annotated[int | None, Query(ge=1, le=12, description="발생 월. year 와 함께")] = None,
    assignee_id: uuid.UUID | None = None,
    department_id: uuid.UUID | None = None,
    category_id: Annotated[uuid.UUID | None, Query(description="서비스구분 - 원인 중 하나라도")] = None,
    symptom_id: uuid.UUID | None = None,
    maker_id: uuid.UUID | None = None,
    fault_id: uuid.UUID | None = None,
    responder_id: uuid.UUID | None = None,
    customer_id: uuid.UUID | None = None,
    store_id: uuid.UUID | None = None,
    brand_id: uuid.UUID | None = None,
    ticket_status: Annotated[ServiceStatus | None, Query(alias="status")] = None,
    only_open: bool = False,
    is_warranty: bool | None = None,
    is_rental: bool | None = None,
    rental_unreturned: Annotated[bool, Query(description="렌탈 O · 미회수만")] = False,
) -> dict:
    """목록 · 통계 · 엑셀이 같은 조건을 쓴다. 조건이 같으면 숫자도 같아야 한다."""
    return {
        "date_from": date_from,
        "date_to": date_to,
        "year": year,
        "month": month if year else None,
        "assignee_id": assignee_id,
        "department_id": department_id,
        "category_id": category_id,
        "symptom_id": symptom_id,
        "maker_id": maker_id,
        "fault_id": fault_id,
        "responder_id": responder_id,
        "customer_id": customer_id,
        "store_id": store_id,
        "brand_id": brand_id,
        "status": ticket_status,
        "only_open": only_open or None,
        "is_warranty": is_warranty,
        "is_rental": is_rental,
        "rental_unreturned": rental_unreturned or None,
    }


Filters = Annotated[dict, Depends(ticket_filters)]


# ================================================================== customers
@router.get("/customers", response_model=Page[CustomerOut])
def list_customers(
    db: DbSession, _: CurrentUser, page: PageParams, q: str | None = None
) -> Page[CustomerOut]:
    stmt = select(Customer).where(Customer.deleted_at.is_(None))
    if q:
        like = f"%{q.strip()}%"
        stmt = stmt.where(
            or_(Customer.name.ilike(like), Customer.phone.ilike(like), Customer.code.ilike(like))
        )
    total = db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    rows = db.scalars(
        stmt.order_by(Customer.name).offset(page.offset).limit(page.size)
    ).all()
    return Page.build(
        [CustomerOut.model_validate(r) for r in rows], total, page.page, page.size
    )


@router.post("/customers", response_model=CustomerOut, status_code=status.HTTP_201_CREATED)
def create_customer(
    payload: CustomerCreate, db: DbSession, user: CurrentUser
) -> CustomerOut:
    customer = Customer(**payload.model_dump(), created_by_id=user.id)
    db.add(customer)
    db.commit()
    db.refresh(customer)
    return CustomerOut.model_validate(customer)


@router.patch("/customers/{customer_id}", response_model=CustomerOut)
def update_customer(
    customer_id: uuid.UUID, payload: CustomerUpdate, db: DbSession, user: CurrentUser
) -> CustomerOut:
    customer = db.scalar(
        select(Customer).where(Customer.id == customer_id, Customer.deleted_at.is_(None))
    )
    if customer is None:
        raise AppError("NOT_FOUND", "거래처를 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(customer, field, value)
    customer.updated_by_id = user.id
    db.commit()
    db.refresh(customer)
    return CustomerOut.model_validate(customer)


# ================================================================== tickets
def _ticket_query(
    db: Session,
    filters: dict,
    *,
    q: str | None = None,
    priority: ServicePriority | None = None,
    channel: ServiceChannel | None = None,
):
    stmt = stats.apply_filters(select(ServiceTicket), **filters)
    if priority:
        stmt = stmt.where(ServiceTicket.priority == priority)
    if channel:
        stmt = stmt.where(ServiceTicket.channel == channel)
    if q:
        # 구 서버 검색 범위: 내용 · 대응 내용 · 시리얼 · 매장 · 브랜드 · 과실 · 대응인원 ·
        # 렌탈 종류 · 원인(구분 · 세부 · 제조사) · 댓글 · 번호
        text = q.strip()
        like = f"%{text}%"
        code_ids = select(CodeItem.id).where(CodeItem.name.ilike(like))
        stmt = stmt.where(
            or_(
                ServiceTicket.ticket_no == text,
                ServiceTicket.ticket_no.ilike(like),
                ServiceTicket.title.ilike(like),
                ServiceTicket.description.ilike(like),
                ServiceTicket.result_note.ilike(like),
                ServiceTicket.serial_no.ilike(like),
                ServiceTicket.rental_serials.ilike(like),
                ServiceTicket.customer_name.ilike(like),
                ServiceTicket.store_id.in_(select(Store.id).where(Store.name.ilike(like))),
                ServiceTicket.fault_id.in_(code_ids),
                ServiceTicket.rental_type_id.in_(code_ids),
                ServiceTicket.id.in_(
                    select(ServiceTicketCause.ticket_id).where(
                        or_(
                            ServiceTicketCause.category_id.in_(code_ids),
                            ServiceTicketCause.symptom_id.in_(code_ids),
                            ServiceTicketCause.maker_id.in_(code_ids),
                        )
                    )
                ),
                ServiceTicket.id.in_(
                    select(ServiceTicketResponder.ticket_id).where(
                        ServiceTicketResponder.responder_id.in_(code_ids)
                    )
                ),
                ServiceTicket.id.in_(
                    select(ServiceLog.ticket_id).where(ServiceLog.content.ilike(like))
                ),
            )
        )
    return stmt


_ORDER = {
    "received_desc": lambda: (ServiceTicket.received_at.desc(), ServiceTicket.created_at.desc()),
    "received_asc": lambda: (ServiceTicket.received_at.asc(), ServiceTicket.created_at.asc()),
    "due_asc": lambda: (ServiceTicket.due_at.asc(),),
    "priority_desc": lambda: (ServiceTicket.priority.desc(), ServiceTicket.received_at.desc()),
    "created_desc": lambda: (ServiceTicket.created_at.desc(),),
    "updated_desc": lambda: (ServiceTicket.updated_at.desc(), ServiceTicket.created_at.desc()),
}


@router.get("/tickets", response_model=Page[ServiceTicketOut])
def list_tickets(
    db: DbSession,
    _: CurrentUser,
    page: PageParams,
    filters: Filters,
    q: Annotated[str | None, Query(description="번호 · 제목 · 내용 · 시리얼 · 매장 · 분류 · 대응인원 · 댓글")] = None,
    priority: ServicePriority | None = None,
    channel: ServiceChannel | None = None,
    sort: Annotated[SortKey, Query()] = "received_desc",
) -> Page[ServiceTicketOut]:
    stmt = _ticket_query(db, filters, q=q, priority=priority, channel=channel)
    total = db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    rows = db.scalars(stmt.order_by(*_ORDER[sort]()).offset(page.offset).limit(page.size)).all()
    return Page.build(_enrich(db, list(rows)), total, page.page, page.size)


@router.get("/tickets/export.xlsx")
def export_tickets(
    db: DbSession,
    _: CurrentUser,
    filters: Filters,
    q: str | None = None,
    priority: ServicePriority | None = None,
    channel: ServiceChannel | None = None,
):
    """검색 조건 그대로 엑셀. 열 구성은 구 서버 '대응기록_날짜.xlsx' 와 같다."""
    stmt = _ticket_query(db, filters, q=q, priority=priority, channel=channel)
    tickets = list(db.scalars(stmt.order_by(ServiceTicket.received_at, ServiceTicket.created_at)).all())
    extras = _extras(db, tickets)
    n_cause = max([3] + [len(extras[t.id]["causes"]) for t in tickets])

    head = ["번호", "브랜드", "매장명"]
    for i in range(1, n_cause + 1):
        head += [f"서비스구분 {i}", f"세부분류 {i}", f"제조사 {i}"]
    head += ["과실", "발생일", "발생 내용", "대응일", "대응 내용", "종결 여부", "상태", "대응인원",
             "렌탈 여부", "렌탈 장비 종류", "렌탈 장비 시리얼", "회수 예정일", "실제 회수일", "회수 여부",
             "첨부 수", "처리 이력 수"]

    def rows():
        for t in tickets:
            e = extras[t.id]
            line = [t.legacy_no or t.ticket_no, e["brand_name"], e["store_name"]]
            for i in range(n_cause):
                if i < len(e["causes"]):
                    c = e["causes"][i]
                    line += [c["category"], c["symptom"], c["maker"]]
                else:
                    line += ["", "", ""]
            received = stats.to_local(t.received_at)
            completed = stats.to_local(t.completed_at)
            line += [
                e["fault_name"],
                received.date().isoformat() if received else "",
                t.description or t.title,
                completed.date().isoformat() if completed else "",
                t.result_note or "",
                "종결" if t.status == ServiceStatus.COMPLETED else "미종결",
                stats.STATUS_LABELS.get(t.status, t.status.value),
                ", ".join(e["responders"]),
                "O" if t.is_rental else "X",
                e["rental_type"] or "",
                t.rental_serials or "",
                t.rental_due_date.isoformat() if t.rental_due_date else "",
                t.rental_return_date.isoformat() if t.rental_return_date else "",
                ("O" if t.rental_returned else "X") if t.is_rental else "",
                e["attachment_count"],
                e["log_count"],
            ]
            yield line

    wb = excel.workbook()
    ws = wb.create_sheet("대응 기록")
    widths = [8, 10, 18] + [14, 22, 13] * n_cause + [12, 11, 46, 11, 46, 10, 8, 14, 9, 16, 18, 11, 11, 9, 7, 9]
    wrap = [head.index("발생 내용"), head.index("대응 내용")]
    excel.fill_sheet(ws, head, rows(), widths, wrap_cols=wrap)
    return excel.to_response(wb, f"대응기록_{datetime.now(stats.LOCAL_TZ).date().isoformat()}.xlsx")


# ------------------------------------------------------------------ 대시보드 (구 서버 첫 화면)
@router.get("/dashboard", response_model=ServiceDashboard)
def dashboard(
    db: DbSession,
    _: CurrentUser,
    limit: Annotated[int, Query(ge=1, le=100)] = 10,
) -> ServiceDashboard:
    """미종결(오래된 것부터) · 렌탈 미회수 D-day · 최근 기록 · 연도별 건수."""
    live = ServiceTicket.deleted_at.is_(None)
    today_local = datetime.now(stats.LOCAL_TZ).date()
    this_year = today_local.year

    total = db.scalar(select(func.count(ServiceTicket.id)).where(live)) or 0
    lo, hi = stats.local_range(this_year)
    this_year_n = db.scalar(
        select(func.count(ServiceTicket.id)).where(
            live, ServiceTicket.received_at >= lo, ServiceTicket.received_at < hi
        )
    ) or 0
    open_count = db.scalar(
        select(func.count(ServiceTicket.id)).where(live, ServiceTicket.status.in_(OPEN_SERVICE_STATUSES))
    ) or 0

    open_rows = list(
        db.scalars(
            select(ServiceTicket)
            .where(live, ServiceTicket.status.in_(OPEN_SERVICE_STATUSES))
            .order_by(ServiceTicket.received_at.asc())
            .limit(limit)
        ).all()
    )
    open_ex = _extras(db, open_rows)
    open_tickets = [
        TicketBrief(
            id=t.id, ticket_no=t.ticket_no, title=t.title,
            store_name=open_ex[t.id]["store_name"], brand_name=open_ex[t.id]["brand_name"],
            status=t.status, received_at=t.received_at,
            days_open=(today_local - stats.to_local(t.received_at).date()).days,
        )
        for t in open_rows
    ]

    rent_rows = list(
        db.scalars(
            select(ServiceTicket)
            .where(live, ServiceTicket.is_rental.is_(True), ServiceTicket.rental_returned.is_(False))
            .order_by(ServiceTicket.rental_due_date.asc().nulls_last())
        ).all()
    )
    rent_ex = _extras(db, rent_rows)
    rentals = [
        RentalRow(
            ticket_id=t.id, ticket_no=t.ticket_no, store_name=rent_ex[t.id]["store_name"],
            rental_type=rent_ex[t.id]["rental_type"], serials=t.rental_serials,
            due_date=t.rental_due_date,
            dday=(t.rental_due_date - today_local).days if t.rental_due_date else None,
        )
        for t in rent_rows
    ]

    recent = list(
        db.scalars(
            select(ServiceTicket).where(live)
            .order_by(ServiceTicket.updated_at.desc(), ServiceTicket.created_at.desc())
            .limit(limit)
        ).all()
    )
    year_expr = stats.period_expr(ServiceTicket.received_at, "year")
    by_year = [
        YearCount(year=str(y), count=n)
        for y, n in db.execute(
            select(year_expr.label("y"), func.count(ServiceTicket.id)).where(live).group_by("y").order_by("y")
        ).all()
        if y is not None
    ]
    return ServiceDashboard(
        total=total, this_year=this_year_n, open_count=open_count,
        open_tickets=open_tickets, unreturned_rentals=rentals,
        recent=_enrich(db, recent), by_year=by_year,
    )


# ------------------------------------------------------------------ 등록 · 수정
@router.post("/tickets", response_model=ServiceTicketDetail, status_code=status.HTTP_201_CREATED)
def create_ticket(
    payload: ServiceTicketCreate, db: DbSession, user: CurrentUser, client: Client
) -> ServiceTicketDetail:
    data = payload.model_dump(exclude={"parts", "causes", "responder_ids"})
    received_at = data.pop("received_at", None) or now_utc()
    for k in ("rental_returned",):
        if data.get(k) is None:
            data[k] = False

    store = ticket_rules.resolve_store(db, data.get("store_id"))
    if store is not None and not data.get("customer_name"):
        data["customer_name"] = store.name
    ticket_rules.check_code(db, data.get("fault_id"), "SERVICE_FAULT", "과실")

    if data.get("due_at") is None:
        due_days = settings_store.get(db, ModuleKey.SERVICE, "default_due_days", 3)
        if due_days:
            from datetime import timedelta

            data["due_at"] = received_at + timedelta(days=int(due_days))

    ticket = ServiceTicket(
        **data,
        received_at=received_at,
        status=ServiceStatus.ASSIGNED if data.get("assignee_id") else ServiceStatus.RECEIVED,
        created_by_id=user.id,
    )

    # 규칙 검사는 전부 행을 넣기 전에. 어긋나면 번호를 채번하지도, 무엇을 남기지도 않는다.
    causes = None
    if payload.causes is not None:
        causes = ticket_rules.validate_causes(db, payload.causes)
    else:
        if ticket.category_id is None and settings_store.get(db, ModuleKey.SERVICE, "require_category", True):
            raise AppError("CATEGORY_REQUIRED", "서비스구분 1을 고르세요.")
        ticket_rules.check_code(db, ticket.category_id, "SERVICE_CATEGORY", "서비스구분")
    responders = (
        ticket_rules.validate_responder_ids(db, payload.responder_ids)
        if payload.responder_ids is not None else None
    )
    ticket_rules.validate_rental(db, ticket)

    _insert_with_ticket_no(db, ticket)
    if causes is not None:
        ticket_rules.set_causes(db, ticket, causes, is_new=True)
    else:
        ticket_rules.sync_head_cause(db, ticket)
    if responders is not None:
        ticket_rules.set_responders(db, ticket, responders, is_new=True)

    for part in payload.parts:
        db.add(ServicePart(ticket_id=ticket.id, **part.model_dump()))
    _recalc_costs(db, ticket)

    db.add(
        ServiceLog(
            ticket_id=ticket.id,
            author_id=user.id,
            to_status=ticket.status,
            content="접수 등록",
        )
    )
    notices = ticket_rules.sync_rental_assets(db, ticket, user)
    _notify_assignee(db, ticket, user.id)
    audit.record(
        db,
        action=AuditAction.CREATE,
        actor=user,
        module=ModuleKey.SERVICE,
        entity_type="service_ticket",
        entity_id=ticket.id,
        summary=f"AS 접수 {ticket.ticket_no}: {ticket.title}",
        client=client,
    )
    db.commit()
    out = _detail(db, ticket.id)
    out.notices = notices
    return out


@router.get("/tickets/{ticket_id}", response_model=ServiceTicketDetail)
def get_ticket(ticket_id: uuid.UUID, db: DbSession, _: CurrentUser) -> ServiceTicketDetail:
    return _detail(db, ticket_id)


RENTAL_KEYS = {
    "is_rental", "rental_type_id", "rental_serials", "rental_due_date",
    "rental_returned", "rental_return_date",
}


@router.patch("/tickets/{ticket_id}", response_model=ServiceTicketDetail)
def update_ticket(
    ticket_id: uuid.UUID,
    payload: ServiceTicketUpdate,
    db: DbSession,
    user: CurrentUser,
    client: Client,
) -> ServiceTicketDetail:
    ticket = _load(db, ticket_id)
    data = payload.model_dump(exclude_unset=True, exclude={"causes", "responder_ids"})
    before = {k: getattr(ticket, k) for k in data}

    if "store_id" in data:
        store = ticket_rules.resolve_store(db, data["store_id"])
        # 매장이 바뀌면 표시용 거래처 이름도 따라간다 - 손으로 다른 이름을 적어 둔 건은 그대로.
        prev_store = db.get(Store, before["store_id"]) if before["store_id"] else None
        follows_store = not ticket.customer_name or (prev_store is not None and ticket.customer_name == prev_store.name)
        if store is not None and "customer_name" not in data and follows_store:
            data["customer_name"] = store.name
    if "fault_id" in data:
        ticket_rules.check_code(db, data["fault_id"], "SERVICE_FAULT", "과실")
    if "rental_returned" in data and data["rental_returned"] is None:
        data["rental_returned"] = False
    if "is_rental" in data and data["is_rental"] is None:
        data["is_rental"] = False

    previous_assignee = ticket.assignee_id
    for field, value in data.items():
        setattr(ticket, field, value)
    ticket.updated_by_id = user.id
    _recalc_costs(db, ticket)

    if payload.causes is not None:
        ticket_rules.apply_causes(db, ticket, payload.causes, is_new=False)
    elif "category_id" in data or "symptom_id" in data:
        ticket_rules.check_code(db, ticket.category_id, "SERVICE_CATEGORY", "서비스구분")
        ticket_rules.sync_head_cause(db, ticket)
    if payload.responder_ids is not None:
        ticket_rules.apply_responders(db, ticket, payload.responder_ids, is_new=False)

    notices: list[str] = []
    if RENTAL_KEYS & set(data) or ("store_id" in data and ticket.is_rental):
        ticket_rules.validate_rental(db, ticket)
        notices = ticket_rules.sync_rental_assets(db, ticket, user)

    if "assignee_id" in data and data["assignee_id"] != previous_assignee:
        if ticket.status == ServiceStatus.RECEIVED and ticket.assignee_id:
            ticket.status = ServiceStatus.ASSIGNED
        _notify_assignee(db, ticket, user.id)

    audit.record(
        db,
        action=AuditAction.UPDATE,
        actor=user,
        module=ModuleKey.SERVICE,
        entity_type="service_ticket",
        entity_id=ticket.id,
        summary=f"AS 수정 {ticket.ticket_no}",
        changes=audit.diff(before, data),
        client=client,
    )
    db.commit()
    out = _detail(db, ticket_id)
    out.notices = notices
    return out


@router.post("/tickets/{ticket_id}/status", response_model=ServiceTicketDetail)
def change_status(
    ticket_id: uuid.UUID,
    payload: ServiceStatusChange,
    db: DbSession,
    user: CurrentUser,
    client: Client,
) -> ServiceTicketDetail:
    """The only way status moves. Keeps the timeline fields and log in sync.

    종결(COMPLETED)은 구 서버 규칙대로 대응 내용과 대응인원이 있어야 한다.
    """
    ticket = _load(db, ticket_id)
    old = ticket.status
    if old == payload.status:
        raise AppError("SAME_STATUS", "이미 해당 상태입니다.")

    if payload.responder_ids is not None:
        ticket_rules.apply_responders(db, ticket, payload.responder_ids, is_new=False)

    if payload.status == ServiceStatus.COMPLETED:
        require_note = settings_store.get(db, ModuleKey.SERVICE, "require_result_note", True)
        note = payload.result_note or ticket.result_note
        if require_note and not note:
            raise AppError("RESULT_NOTE_REQUIRED", "종결하려면 대응 내용을 입력하세요.")
        ticket_rules.require_responders_on_complete(db, ticket)
        ticket.result_note = note
        ticket.completed_at = payload.completed_at or now_utc()
    elif old == ServiceStatus.COMPLETED:
        # Reopening: clear the completion stamp so duration stats stay honest.
        ticket.completed_at = None

    if payload.status == ServiceStatus.IN_PROGRESS and ticket.started_at is None:
        ticket.started_at = now_utc()

    ticket.status = payload.status
    ticket.updated_by_id = user.id
    if payload.work_minutes is not None:
        ticket.work_minutes = (ticket.work_minutes or 0) + payload.work_minutes

    db.add(
        ServiceLog(
            ticket_id=ticket.id,
            author_id=user.id,
            from_status=old,
            to_status=payload.status,
            content=payload.note or f"{old.value} -> {payload.status.value}",
            work_minutes=payload.work_minutes,
        )
    )
    audit.record(
        db,
        action=AuditAction.UPDATE,
        actor=user,
        module=ModuleKey.SERVICE,
        entity_type="service_ticket",
        entity_id=ticket.id,
        summary=f"AS 상태 변경 {ticket.ticket_no}: {old.value} -> {payload.status.value}",
        client=client,
    )
    db.commit()
    return _detail(db, ticket_id)


@router.post("/tickets/{ticket_id}/logs", response_model=ServiceLogOut)
def add_log(
    ticket_id: uuid.UUID, payload: ServiceLogIn, db: DbSession, user: CurrentUser
) -> ServiceLogOut:
    ticket = _load(db, ticket_id)
    entry = ServiceLog(
        ticket_id=ticket.id,
        author_id=user.id,
        content=payload.content,
        work_minutes=payload.work_minutes,
        from_status=ticket.status,
        to_status=payload.to_status,
    )
    if payload.work_minutes:
        ticket.work_minutes = (ticket.work_minutes or 0) + payload.work_minutes
    if payload.to_status:
        ticket.status = payload.to_status
    # 댓글이 달리면 마지막 수정 시각도 올려 대시보드 '최근 기록'에 나오게 (구 서버 touch_record)
    ticket.updated_at = now_utc()
    ticket.updated_by_id = user.id
    db.add(entry)
    db.commit()
    db.refresh(entry)
    out = ServiceLogOut.model_validate(entry)
    out.author = UserBrief.model_validate(user)
    return out


@router.post("/tickets/{ticket_id}/parts", response_model=ServicePartOut)
def add_part(
    ticket_id: uuid.UUID, payload: ServicePartIn, db: DbSession, user: CurrentUser
) -> ServicePartOut:
    ticket = _load(db, ticket_id)
    part = ServicePart(ticket_id=ticket.id, **payload.model_dump())
    db.add(part)
    db.flush()
    _recalc_costs(db, ticket)
    ticket.updated_by_id = user.id
    db.commit()
    db.refresh(part)
    return ServicePartOut.model_validate(part)


@router.delete("/tickets/{ticket_id}/parts/{part_id}", response_model=Message)
def remove_part(
    ticket_id: uuid.UUID, part_id: uuid.UUID, db: DbSession, _: CurrentUser
) -> Message:
    ticket = _load(db, ticket_id)
    part = db.scalar(
        select(ServicePart).where(ServicePart.id == part_id, ServicePart.ticket_id == ticket.id)
    )
    if part is None:
        raise AppError("NOT_FOUND", "부품 내역을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)
    db.delete(part)
    db.flush()
    _recalc_costs(db, ticket)
    db.commit()
    return Message(message="삭제되었습니다.")


@router.delete("/tickets/{ticket_id}", response_model=Message)
def delete_ticket(
    ticket_id: uuid.UUID, db: DbSession, manager: ManagerUser, client: Client
) -> Message:
    ticket = _load(db, ticket_id)
    ticket.deleted_at = now_utc()
    audit.record(
        db,
        action=AuditAction.DELETE,
        actor=manager,
        module=ModuleKey.SERVICE,
        entity_type="service_ticket",
        entity_id=ticket.id,
        summary=f"AS 삭제 {ticket.ticket_no}",
        client=client,
    )
    db.commit()
    return Message(message="삭제되었습니다.")


# ================================================================== statistics
@router.get("/stats/summary", response_model=ServiceSummary)
def stats_summary(db: DbSession, _: CurrentUser, filters: Filters) -> ServiceSummary:
    """총건수 / 완료율 / 평균 처리시간 / 상태별·우선순위별 분포. 목록과 같은 조건."""
    return stats.summary(db, **filters)


GroupByParam = Annotated[
    # stats.GroupBy 와 같은 목록이어야 한다. 두 군데에 적혀 있으니 축을 더할 때 둘 다 고쳐야 한다.
    Literal[
        "category", "symptom", "maker",
        "cause", "action", "fault",
        "assignee", "status", "priority", "channel", "department",
        "store", "brand", "responder",
    ],
    Query(description="classification axis"),
]


@router.get("/stats/grouped", response_model=ServiceGrouped)
def stats_grouped(
    db: DbSession, _: CurrentUser, filters: Filters, group_by: GroupByParam = "category"
) -> ServiceGrouped:
    """분류별 자동 집계. 파이/바 차트가 바로 그릴 수 있는 형태로 반환합니다.

    분류 · 증상 · 제조사 · 대응인원 축은 원인(사람) 행을 세므로 `total_causes` 가
    분모다. category_id 를 주면 그 서비스구분 탭이 된다(그 구분의 원인만).
    """
    return stats.grouped(db, group_by, **filters)


@router.get("/stats/trend", response_model=ServiceTrend)
def stats_trend(
    db: DbSession,
    _: CurrentUser,
    filters: Filters,
    interval: Annotated[Literal["day", "week", "month", "year"], Query()] = "day",
) -> ServiceTrend:
    """기간별 접수/완료 추이 (한국 시각 기준)."""
    return stats.trend(db, interval, **filters)


CrossAxisParam = Annotated[
    Literal["year", "brand", "store", "category", "symptom", "maker"], Query()
]


@router.get("/stats/crosstab", response_model=Crosstab)
def stats_crosstab(
    db: DbSession,
    _: CurrentUser,
    filters: Filters,
    rows: CrossAxisParam = "year",
    cols: CrossAxisParam = "category",
) -> Crosstab:
    """구 서버 통계 표: 연도×브랜드, 연도×매장, 브랜드×세부구분, 매장×세부구분, 제조사×연도 …

    칸은 원인 수다. category_id 를 주면 그 서비스구분 탭이 되고 cols=symptom 이
    그 구분의 증상(세부분류) 열이 된다.
    """
    return stats.crosstab(db, rows, cols, **filters)


@router.get("/stats/crosstab.xlsx")
def stats_crosstab_xlsx(
    db: DbSession,
    _: CurrentUser,
    filters: Filters,
    rows: CrossAxisParam = "year",
    cols: CrossAxisParam = "category",
    title: Annotated[str | None, Query(max_length=60)] = None,
):
    ct = stats.crosstab(db, rows, cols, **filters)
    head = [_AXIS_LABEL[rows]] + [c.label for c in ct.cols] + ["합계", "대응 건수", "비율(%)"]
    lines = [
        [r.label] + [r.cells.get(c.key, 0) or None for c in ct.cols] + [r.total, r.ticket_count, round(r.ratio * 100, 1)]
        for r in ct.rows
    ]
    lines.append(["전체"] + [ct.col_totals.get(c.key, 0) for c in ct.cols] + [ct.total_causes, ct.total_tickets, 100.0])
    wb = excel.workbook()
    ws = wb.create_sheet(excel.sheet_title(title or f"{_AXIS_LABEL[rows]}별 {_AXIS_LABEL[cols]}별"))
    excel.fill_sheet(ws, head, lines, [22] + [12] * len(ct.cols) + [8, 10, 9], freeze="B2")
    return excel.to_response(wb, f"통계_{_AXIS_LABEL[rows]}x{_AXIS_LABEL[cols]}_{datetime.now(stats.LOCAL_TZ).date().isoformat()}.xlsx")


_AXIS_LABEL = {
    "year": "연도", "brand": "브랜드", "store": "매장",
    "category": "서비스구분", "symptom": "세부분류", "maker": "제조사",
}


@router.get("/stats/store-years", response_model=StoreYears)
def stats_store_years(db: DbSession, _: CurrentUser) -> StoreYears:
    """연도별 운영 매장 · 브랜드별 운영 매장 (구 서버 통계 메인 탭)."""
    return stats.store_years(db)


# ================================================================== helpers
def _load(db: Session, ticket_id: uuid.UUID) -> ServiceTicket:
    ticket = db.scalar(
        select(ServiceTicket).where(
            ServiceTicket.id == ticket_id, ServiceTicket.deleted_at.is_(None)
        )
    )
    if ticket is None:
        raise AppError("NOT_FOUND", "접수 건을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)
    return ticket


def _extras(db: Session, tickets: list[ServiceTicket]) -> dict[uuid.UUID, dict]:
    """목록 한 장에 필요한 곁 정보를 쿼리 몇 번으로. 건마다 따로 물으면 수십 번 나간다."""
    ids = [t.id for t in tickets]
    out: dict[uuid.UUID, dict] = {
        t.id: {
            "causes": [], "responders": [], "responder_ids": [], "store_name": None, "brand_name": None,
            "brand_id": None, "store_closed": False, "fault_name": None, "rental_type": None,
            "attachment_count": 0, "log_count": 0,
        }
        for t in tickets
    }
    if not ids:
        return out

    code_ids: set[uuid.UUID] = set()
    cause_rows = db.scalars(
        select(ServiceTicketCause).where(ServiceTicketCause.ticket_id.in_(ids)).order_by(ServiceTicketCause.seq)
    ).all()
    resp_rows = db.scalars(
        select(ServiceTicketResponder).where(ServiceTicketResponder.ticket_id.in_(ids)).order_by(ServiceTicketResponder.seq)
    ).all()
    for c in cause_rows:
        code_ids |= {x for x in (c.category_id, c.symptom_id, c.maker_id) if x}
    for r in resp_rows:
        if r.responder_id:
            code_ids.add(r.responder_id)
    for t in tickets:
        code_ids |= {x for x in (t.fault_id, t.rental_type_id) if x}

    store_ids = {t.store_id for t in tickets if t.store_id}
    stores = {s.id: s for s in db.scalars(select(Store).where(Store.id.in_(store_ids))).all()} if store_ids else {}
    code_ids |= {s.brand_id for s in stores.values() if s.brand_id}
    codes = {c.id: c for c in db.scalars(select(CodeItem).where(CodeItem.id.in_(code_ids))).all()} if code_ids else {}

    def name(cid):
        item = codes.get(cid) if cid else None
        return item.name if item else None

    for c in cause_rows:
        out[c.ticket_id]["causes"].append(
            {"row": c, "category": name(c.category_id) or "", "symptom": name(c.symptom_id) or "", "maker": name(c.maker_id) or ""}
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
        .where(Attachment.entity_type == "service_ticket", Attachment.entity_id.in_(ids), Attachment.deleted_at.is_(None))
        .group_by(Attachment.entity_id)
    ).all():
        if tid in out:
            out[tid]["attachment_count"] = n
    for tid, n in db.execute(
        select(ServiceLog.ticket_id, func.count(ServiceLog.id)).where(ServiceLog.ticket_id.in_(ids)).group_by(ServiceLog.ticket_id)
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
    return [_apply_extras(ServiceTicketOut.model_validate(t), extras[t.id]) for t in tickets]


def _detail(db: Session, ticket_id: uuid.UUID) -> ServiceTicketDetail:
    ticket = db.scalar(
        select(ServiceTicket)
        .where(ServiceTicket.id == ticket_id)
        .options(
            selectinload(ServiceTicket.parts),
            selectinload(ServiceTicket.logs),
            selectinload(ServiceTicket.customer),
        )
    )
    if ticket is None:
        raise AppError("NOT_FOUND", "접수 건을 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND)

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
            id=c["row"].id, seq=c["row"].seq,
            category_id=c["row"].category_id, symptom_id=c["row"].symptom_id, maker_id=c["row"].maker_id,
            category=brief(c["row"].category_id), symptom=brief(c["row"].symptom_id), maker=brief(c["row"].maker_id),
        )
        for c in e["causes"]
    ]
    out.responders = [b for b in (brief(rid) for rid in e["responder_ids"]) if b]
    out.fault = brief(ticket.fault_id)
    out.rental_type = brief(ticket.rental_type_id)
    if ticket.store_id:
        s = db.get(Store, ticket.store_id)
        if s is not None:
            out.store = StoreRef(id=s.id, name=s.name, brand_id=s.brand_id, brand_name=e["brand_name"], is_closed=s.is_closed)
    if ticket.assignee_id:
        assignee = db.get(User, ticket.assignee_id)
        if assignee:
            out.assignee = UserBrief.model_validate(assignee)
    author_ids = {l.author_id for l in ticket.logs if l.author_id}
    authors = {u.id: u for u in db.scalars(select(User).where(User.id.in_(author_ids))).all()} if author_ids else {}
    for log_out, log in zip(out.logs, ticket.logs):
        u = authors.get(log.author_id) if log.author_id else None
        log_out.author = UserBrief.model_validate(u) if u else None
    return out


def _next_ticket_no(db: Session, attempt: int = 0) -> str:
    """AS-YYYYMM-0001, restarting the sequence each month."""
    prefix = settings_store.get(db, ModuleKey.SERVICE, "ticket_prefix", "AS") or "AS"
    stamp = now_utc().strftime("%Y%m")
    like = f"{prefix}-{stamp}-%"
    count = db.scalar(
        select(func.count(ServiceTicket.id)).where(ServiceTicket.ticket_no.like(like))
    ) or 0
    return f"{prefix}-{stamp}-{count + 1 + attempt:04d}"


def _insert_with_ticket_no(db: Session, ticket: ServiceTicket, retries: int = 5) -> None:
    """Counting rows races under concurrent inserts, so the unique index on
    ticket_no is the real guard and we retry with the next number on collision.

    The savepoint is what makes the retry possible: without it the failed INSERT
    would poison the whole transaction.
    """
    for attempt in range(retries):
        ticket.ticket_no = _next_ticket_no(db, attempt)
        try:
            with db.begin_nested():
                db.add(ticket)  # add() is a no-op when it is already pending
                db.flush()
            return
        except IntegrityError:
            continue
    raise AppError(
        "TICKET_NO_CONFLICT",
        "접수번호 채번에 실패했습니다. 잠시 후 다시 시도해 주세요.",
        status.HTTP_409_CONFLICT,
    )


def _recalc_costs(db: Session, ticket: ServiceTicket) -> None:
    # The session runs with autoflush off, so pending part rows would be
    # invisible to this aggregate unless we flush them first.
    db.flush()
    parts_total = db.scalar(
        select(func.sum(ServicePart.quantity * func.coalesce(ServicePart.unit_price, 0))).where(
            ServicePart.ticket_id == ticket.id
        )
    )
    ticket.parts_cost = Decimal(str(parts_total)) if parts_total is not None else None
    labor = ticket.labor_cost or Decimal(0)
    parts = ticket.parts_cost or Decimal(0)
    ticket.total_cost = labor + parts if (labor or parts) else None


def _notify_assignee(db: Session, ticket: ServiceTicket, actor_id: uuid.UUID) -> None:
    if not ticket.assignee_id or ticket.assignee_id == actor_id:
        return
    if not settings_store.get(db, ModuleKey.SERVICE, "notify_on_assign", True):
        return
    notifications.notify(
        db,
        user_ids=[ticket.assignee_id],
        type=NotificationType.SERVICE_ASSIGNED,
        title=f"[AS 배정] {ticket.ticket_no}",
        body=ticket.title,
        payload={"route": "/service/ticket", "ticket_id": str(ticket.id)},
        entity_type="service_ticket",
        entity_id=ticket.id,
    )
