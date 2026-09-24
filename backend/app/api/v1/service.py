"""서비스(AS) module: ticket CRUD, work log, and the automatic statistics."""
from __future__ import annotations

import uuid
from datetime import datetime
from decimal import Decimal
from typing import Annotated, Literal

from fastapi import APIRouter, Query, status
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
from app.models.enums import (
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
)
from app.schemas.common import Message, Page, UserBrief
from app.schemas.service import (
    CustomerCreate,
    CustomerOut,
    CustomerUpdate,
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
)
from app.services import audit, notifications, settings_store, stats

router = APIRouter(prefix="/service", tags=["service"])


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
@router.get("/tickets", response_model=Page[ServiceTicketOut])
def list_tickets(
    db: DbSession,
    _: CurrentUser,
    page: PageParams,
    q: Annotated[str | None, Query(description="ticket no / title / serial / customer")] = None,
    ticket_status: Annotated[ServiceStatus | None, Query(alias="status")] = None,
    priority: ServicePriority | None = None,
    channel: ServiceChannel | None = None,
    assignee_id: uuid.UUID | None = None,
    customer_id: uuid.UUID | None = None,
    category_id: uuid.UUID | None = None,
    department_id: uuid.UUID | None = None,
    is_warranty: bool | None = None,
    only_open: bool = False,
    date_from: datetime | None = None,
    date_to: datetime | None = None,
    sort: Annotated[
        Literal["received_desc", "received_asc", "due_asc", "priority_desc"],
        Query(),
    ] = "received_desc",
) -> Page[ServiceTicketOut]:
    stmt = stats.apply_filters(
        select(ServiceTicket),
        date_from=date_from,
        date_to=date_to,
        assignee_id=assignee_id,
        department_id=department_id,
        category_id=category_id,
        customer_id=customer_id,
        status=ticket_status,
        is_warranty=is_warranty,
    )
    if priority:
        stmt = stmt.where(ServiceTicket.priority == priority)
    if channel:
        stmt = stmt.where(ServiceTicket.channel == channel)
    if only_open:
        stmt = stmt.where(
            ServiceTicket.status.notin_([ServiceStatus.COMPLETED, ServiceStatus.CANCELED])
        )
    if q:
        like = f"%{q.strip()}%"
        stmt = stmt.where(
            or_(
                ServiceTicket.ticket_no.ilike(like),
                ServiceTicket.title.ilike(like),
                ServiceTicket.serial_no.ilike(like),
                ServiceTicket.customer_name.ilike(like),
            )
        )

    order = {
        "received_desc": ServiceTicket.received_at.desc(),
        "received_asc": ServiceTicket.received_at.asc(),
        "due_asc": ServiceTicket.due_at.asc(),
        "priority_desc": ServiceTicket.priority.desc(),
    }[sort]

    total = db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    rows = db.scalars(stmt.order_by(order).offset(page.offset).limit(page.size)).all()
    return Page.build(
        [ServiceTicketOut.model_validate(r) for r in rows], total, page.page, page.size
    )


def _sync_head_cause(db: Session, ticket: ServiceTicket) -> None:
    """티켓의 대표 분류를 service_ticket_causes 의 seq 1 행과 맞춘다.

    통계가 원인 행을 세기 때문에(구 서버와 같은 방식) 원인 행이 하나도 없는
    티켓은 분류별 집계에서 통째로 빠진다. 화면이 아직 다중 분류를 입력받지
    않으므로, 대표 분류를 seq 1 로 비춰 두어 API 로 만든 건도 집계에 잡히게
    한다. 다중 입력이 붙으면 이 함수가 seq 1 만 손본다는 점은 그대로다.
    """
    head = db.scalar(
        select(ServiceTicketCause).where(
            ServiceTicketCause.ticket_id == ticket.id, ServiceTicketCause.seq == 1
        )
    )
    if ticket.category_id is None and ticket.symptom_id is None:
        if head is not None:
            db.delete(head)
        return
    if head is None:
        db.add(
            ServiceTicketCause(
                ticket_id=ticket.id,
                seq=1,
                category_id=ticket.category_id,
                symptom_id=ticket.symptom_id,
            )
        )
    else:
        head.category_id = ticket.category_id
        head.symptom_id = ticket.symptom_id


@router.post("/tickets", response_model=ServiceTicketDetail, status_code=status.HTTP_201_CREATED)
def create_ticket(
    payload: ServiceTicketCreate, db: DbSession, user: CurrentUser, client: Client
) -> ServiceTicketDetail:
    data = payload.model_dump(exclude={"parts"})
    received_at = data.pop("received_at", None) or now_utc()

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
    _insert_with_ticket_no(db, ticket)
    _sync_head_cause(db, ticket)

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
    return _detail(db, ticket.id)


@router.get("/tickets/{ticket_id}", response_model=ServiceTicketDetail)
def get_ticket(ticket_id: uuid.UUID, db: DbSession, _: CurrentUser) -> ServiceTicketDetail:
    return _detail(db, ticket_id)


@router.patch("/tickets/{ticket_id}", response_model=ServiceTicketDetail)
def update_ticket(
    ticket_id: uuid.UUID,
    payload: ServiceTicketUpdate,
    db: DbSession,
    user: CurrentUser,
    client: Client,
) -> ServiceTicketDetail:
    ticket = _load(db, ticket_id)
    data = payload.model_dump(exclude_unset=True)
    before = {k: getattr(ticket, k) for k in data}

    previous_assignee = ticket.assignee_id
    for field, value in data.items():
        setattr(ticket, field, value)
    ticket.updated_by_id = user.id
    _recalc_costs(db, ticket)
    if "category_id" in data or "symptom_id" in data:
        _sync_head_cause(db, ticket)

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
    return _detail(db, ticket_id)


@router.post("/tickets/{ticket_id}/status", response_model=ServiceTicketDetail)
def change_status(
    ticket_id: uuid.UUID,
    payload: ServiceStatusChange,
    db: DbSession,
    user: CurrentUser,
    client: Client,
) -> ServiceTicketDetail:
    """The only way status moves. Keeps the timeline fields and log in sync."""
    ticket = _load(db, ticket_id)
    old = ticket.status
    if old == payload.status:
        raise AppError("SAME_STATUS", "이미 해당 상태입니다.")

    if payload.status == ServiceStatus.COMPLETED:
        require_note = settings_store.get(db, ModuleKey.SERVICE, "require_result_note", True)
        note = payload.result_note or ticket.result_note
        if require_note and not note:
            raise AppError("RESULT_NOTE_REQUIRED", "완료 처리하려면 처리 내용이 필요합니다.")
        ticket.result_note = note
        ticket.completed_at = now_utc()
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
    db.add(entry)
    db.commit()
    db.refresh(entry)
    return ServiceLogOut.model_validate(entry)


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
StatFilters = dict


def _stat_filters(
    date_from: datetime | None,
    date_to: datetime | None,
    assignee_id: uuid.UUID | None,
    department_id: uuid.UUID | None,
    category_id: uuid.UUID | None,
    customer_id: uuid.UUID | None,
    is_warranty: bool | None,
) -> StatFilters:
    return {
        "date_from": date_from,
        "date_to": date_to,
        "assignee_id": assignee_id,
        "department_id": department_id,
        "category_id": category_id,
        "customer_id": customer_id,
        "is_warranty": is_warranty,
    }


@router.get("/stats/summary", response_model=ServiceSummary)
def stats_summary(
    db: DbSession,
    _: CurrentUser,
    date_from: datetime | None = None,
    date_to: datetime | None = None,
    assignee_id: uuid.UUID | None = None,
    department_id: uuid.UUID | None = None,
    category_id: uuid.UUID | None = None,
    customer_id: uuid.UUID | None = None,
    is_warranty: bool | None = None,
) -> ServiceSummary:
    """총건수 / 완료율 / 평균 처리시간 / 상태별·우선순위별 분포."""
    return stats.summary(
        db,
        **_stat_filters(
            date_from, date_to, assignee_id, department_id, category_id, customer_id, is_warranty
        ),
    )


@router.get("/stats/grouped", response_model=ServiceGrouped)
def stats_grouped(
    db: DbSession,
    _: CurrentUser,
    group_by: Annotated[
        # stats.GroupBy 와 같은 목록이어야 한다. 두 군데에 적혀 있으니
        # 축을 더할 때 둘 다 고쳐야 한다.
        Literal[
            "category", "symptom", "maker",
            "cause", "action", "fault",
            "assignee", "status", "priority", "channel", "department",
            "store", "brand",
        ],
        Query(description="classification axis"),
    ] = "category",
    date_from: datetime | None = None,
    date_to: datetime | None = None,
    assignee_id: uuid.UUID | None = None,
    department_id: uuid.UUID | None = None,
    category_id: uuid.UUID | None = None,
    customer_id: uuid.UUID | None = None,
    is_warranty: bool | None = None,
) -> ServiceGrouped:
    """분류별 자동 집계. 파이/바 차트가 바로 그릴 수 있는 형태로 반환합니다."""
    return stats.grouped(
        db,
        group_by,
        **_stat_filters(
            date_from, date_to, assignee_id, department_id, category_id, customer_id, is_warranty
        ),
    )


@router.get("/stats/trend", response_model=ServiceTrend)
def stats_trend(
    db: DbSession,
    _: CurrentUser,
    interval: Annotated[Literal["day", "week", "month"], Query()] = "day",
    date_from: datetime | None = None,
    date_to: datetime | None = None,
    assignee_id: uuid.UUID | None = None,
    department_id: uuid.UUID | None = None,
    category_id: uuid.UUID | None = None,
    customer_id: uuid.UUID | None = None,
    is_warranty: bool | None = None,
) -> ServiceTrend:
    """기간별 접수/완료 추이."""
    return stats.trend(
        db,
        interval,
        **_stat_filters(
            date_from, date_to, assignee_id, department_id, category_id, customer_id, is_warranty
        ),
    )


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
    if ticket.assignee_id:
        from app.models.user import User

        assignee = db.get(User, ticket.assignee_id)
        if assignee:
            out.assignee = UserBrief.model_validate(assignee)
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
