"""Automatic statistics for the 서비스 module.

Everything is computed in SQL so the numbers stay correct as the ticket table
grows past what a page of rows could hold. Two small dialect shims keep the same
queries working on both SQLite (dev) and PostgreSQL (prod):

  * resolution_minutes_expr() - datetime subtraction has no portable spelling
  * period_expr()             - date_trunc vs strftime
"""
from __future__ import annotations

import uuid
from datetime import datetime
from decimal import Decimal
from typing import Literal

from sqlalchemy import Float, Select, and_, case, cast, distinct, func, select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.errors import AppError
from app.core.security import now_utc
from app.models.admin import CodeItem
from app.models.enums import (
    OPEN_SERVICE_STATUSES,
    ServicePriority,
    ServiceStatus,
)
from app.models.service import ServiceTicket, ServiceTicketCause
from app.models.store import Store
from app.models.user import User
from app.schemas.service import (
    ServiceGrouped,
    ServiceSummary,
    ServiceTrend,
    StatBucket,
    TrendPoint,
)

Interval = Literal["day", "week", "month"]
GroupBy = Literal[
    "category", "symptom", "maker",
    "cause", "action", "fault",
    "assignee", "status", "priority", "channel", "department",
    "store", "brand",
]

# 한 건에 여러 값이 달리는 축. 이 축들은 service_ticket_causes 를 세므로
# 버킷 합계가 대응 건수보다 커질 수 있다(구 서버와 같은 방식).
MULTI_AXES = ("category", "symptom", "maker")

# Korean labels for the enum-backed axes, so the client does not need its own map.
STATUS_LABELS = {
    ServiceStatus.RECEIVED: "접수",
    ServiceStatus.ASSIGNED: "배정",
    ServiceStatus.IN_PROGRESS: "진행중",
    ServiceStatus.PENDING_PARTS: "부품대기",
    ServiceStatus.COMPLETED: "완료",
    ServiceStatus.CANCELED: "취소",
}
PRIORITY_LABELS = {
    ServicePriority.LOW: "낮음",
    ServicePriority.NORMAL: "보통",
    ServicePriority.HIGH: "높음",
    ServicePriority.URGENT: "긴급",
}
STATUS_COLORS = {
    ServiceStatus.RECEIVED: "#94A3B8",
    ServiceStatus.ASSIGNED: "#60A5FA",
    ServiceStatus.IN_PROGRESS: "#3B82F6",
    ServiceStatus.PENDING_PARTS: "#F59E0B",
    ServiceStatus.COMPLETED: "#10B981",
    ServiceStatus.CANCELED: "#EF4444",
}
PRIORITY_COLORS = {
    ServicePriority.LOW: "#94A3B8",
    ServicePriority.NORMAL: "#3B82F6",
    ServicePriority.HIGH: "#F59E0B",
    ServicePriority.URGENT: "#EF4444",
}


# --------------------------------------------------------------- dialect shims
def resolution_minutes_expr():
    """completed_at - received_at, in minutes, as a float column expression."""
    if settings.is_postgres:
        # extract(epoch from interval) yields seconds.
        return func.extract(
            "epoch", ServiceTicket.completed_at - ServiceTicket.received_at
        ) / 60.0
    # SQLite: julianday returns fractional days.
    return (
        func.julianday(ServiceTicket.completed_at)
        - func.julianday(ServiceTicket.received_at)
    ) * 1440.0


def period_expr(column, interval: Interval):
    """A sortable text bucket label for the given column."""
    if settings.is_postgres:
        fmt = {"day": "YYYY-MM-DD", "week": 'IYYY-"W"IW', "month": "YYYY-MM"}[interval]
        return func.to_char(func.date_trunc(interval, column), fmt)
    # SQLite has no ISO-week format; %W is Monday-based week-of-year, which is
    # close enough for a trend chart but is not strictly ISO 8601.
    fmt = {"day": "%Y-%m-%d", "week": "%Y-W%W", "month": "%Y-%m"}[interval]
    return func.strftime(fmt, column)


# --------------------------------------------------------------- filtering
def apply_filters(
    stmt: Select,
    *,
    date_from: datetime | None = None,
    date_to: datetime | None = None,
    assignee_id: uuid.UUID | None = None,
    department_id: uuid.UUID | None = None,
    category_id: uuid.UUID | None = None,
    customer_id: uuid.UUID | None = None,
    status: ServiceStatus | None = None,
    is_warranty: bool | None = None,
) -> Select:
    """The one filter definition shared by the list endpoint and every stat."""
    stmt = stmt.where(ServiceTicket.deleted_at.is_(None))
    if date_from is not None:
        stmt = stmt.where(ServiceTicket.received_at >= date_from)
    if date_to is not None:
        stmt = stmt.where(ServiceTicket.received_at < date_to)
    if assignee_id is not None:
        stmt = stmt.where(ServiceTicket.assignee_id == assignee_id)
    if department_id is not None:
        stmt = stmt.where(ServiceTicket.department_id == department_id)
    if category_id is not None:
        stmt = stmt.where(ServiceTicket.category_id == category_id)
    if customer_id is not None:
        stmt = stmt.where(ServiceTicket.customer_id == customer_id)
    if status is not None:
        stmt = stmt.where(ServiceTicket.status == status)
    if is_warranty is not None:
        stmt = stmt.where(ServiceTicket.is_warranty.is_(is_warranty))
    return stmt


def _buckets(
    rows: list[tuple],
    total: int,
    labels: dict | None = None,
    colors: dict | None = None,
) -> list[StatBucket]:
    """rows 는 (key, count, avg_min, cost) 또는 (key, count, avg_min, cost, tickets).

    다섯 번째 값이 있으면 그 버킷의 대응 건수(중복 제거)다.
    """
    out: list[StatBucket] = []
    for row in rows:
        key, count, avg_min, cost = row[:4]
        tickets = row[4] if len(row) > 4 else None
        k = str(key) if key is not None else "UNASSIGNED"
        out.append(
            StatBucket(
                key=k,
                label=(labels or {}).get(key, k) if labels else k,
                color=(colors or {}).get(key) if colors else None,
                count=count,
                ticket_count=tickets,
                ratio=round(count / total, 4) if total else 0.0,
                avg_resolution_minutes=round(avg_min, 1) if avg_min is not None else None,
                total_cost=Decimal(str(cost)) if cost is not None else None,
            )
        )
    return out


# --------------------------------------------------------------- summary
def summary(db: Session, **filters) -> ServiceSummary:
    res_min = resolution_minutes_expr()

    base = apply_filters(
        select(
            func.count(ServiceTicket.id),
            func.sum(
                case((ServiceTicket.status.in_(OPEN_SERVICE_STATUSES), 1), else_=0)
            ),
            func.sum(case((ServiceTicket.status == ServiceStatus.COMPLETED, 1), else_=0)),
            func.sum(case((ServiceTicket.status == ServiceStatus.CANCELED, 1), else_=0)),
            func.avg(case((ServiceTicket.completed_at.isnot(None), res_min))),
            func.avg(cast(ServiceTicket.satisfaction, Float)),
            func.sum(ServiceTicket.total_cost),
        ),
        **filters,
    )
    total, open_c, done_c, cancel_c, avg_res, avg_sat, cost = db.execute(base).one()
    total = total or 0

    overdue = db.scalar(
        apply_filters(
            select(func.count(ServiceTicket.id)).where(
                and_(
                    ServiceTicket.due_at.isnot(None),
                    ServiceTicket.due_at < now_utc(),
                    ServiceTicket.status.in_(OPEN_SERVICE_STATUSES),
                )
            ),
            **filters,
        )
    ) or 0

    by_status = grouped(db, "status", **filters).buckets
    by_priority = grouped(db, "priority", **filters).buckets

    return ServiceSummary(
        date_from=filters.get("date_from"),
        date_to=filters.get("date_to"),
        total=total,
        open_count=int(open_c or 0),
        completed_count=int(done_c or 0),
        canceled_count=int(cancel_c or 0),
        overdue_count=overdue,
        completion_rate=round((done_c or 0) / total, 4) if total else 0.0,
        avg_resolution_minutes=round(float(avg_res), 1) if avg_res is not None else None,
        avg_satisfaction=round(float(avg_sat), 2) if avg_sat is not None else None,
        total_cost=Decimal(str(cost)) if cost is not None else None,
        by_status=by_status,
        by_priority=by_priority,
    )


# --------------------------------------------------------------- grouped

# 한 건에 값이 하나뿐인 축. 티켓 행을 그대로 센다.
_CODE_AXES = {
    "cause": ServiceTicket.cause_id,
    "action": ServiceTicket.action_id,
    "fault": ServiceTicket.fault_id,
}

# 한 건에 여러 값이 달리는 축. service_ticket_causes 행을 센다.
#
# 구 서버가 이렇게 셌다: 서비스구분이 세 개 달린 건은 세 버킷에 각각 1씩
# 들어가고, 화면은 그 옆에 중복을 뺀 '대응 건수'를 같이 보여 줬다. 두 숫자가
# 다른 것이 정상이라, 어느 쪽을 말하는지 화면이 밝혀야 한다.
_CAUSE_AXES = {
    "category": ServiceTicketCause.category_id,
    "symptom": ServiceTicketCause.symptom_id,
    "maker": ServiceTicketCause.maker_id,
}


def _store_grouped(db: Session, total: int, **filters) -> ServiceGrouped:
    """매장별. 구 서버 통계의 1차 축 중 하나였다."""
    res_min = resolution_minutes_expr()
    stmt = apply_filters(
        select(
            func.coalesce(Store.name, "미지정"),
            func.count(ServiceTicket.id),
            func.avg(case((ServiceTicket.completed_at.isnot(None), res_min))),
            func.sum(ServiceTicket.total_cost),
        )
        .select_from(ServiceTicket)
        .outerjoin(Store, Store.id == ServiceTicket.store_id),
        **filters,
    ).group_by(Store.id, Store.name).order_by(func.count(ServiceTicket.id).desc())
    return ServiceGrouped(
        group_by="store", total=total, buckets=_buckets(list(db.execute(stmt).all()), total)
    )


def _brand_grouped(db: Session, total: int, **filters) -> ServiceGrouped:
    """브랜드별. 매장에 달린 브랜드 코드를 한 번 더 타고 올라간다."""
    res_min = resolution_minutes_expr()
    stmt = apply_filters(
        select(
            func.coalesce(CodeItem.name, "미지정"),
            func.count(ServiceTicket.id),
            func.avg(case((ServiceTicket.completed_at.isnot(None), res_min))),
            func.sum(ServiceTicket.total_cost),
        )
        .select_from(ServiceTicket)
        .outerjoin(Store, Store.id == ServiceTicket.store_id)
        .outerjoin(CodeItem, CodeItem.id == Store.brand_id),
        **filters,
    ).group_by(CodeItem.id, CodeItem.name).order_by(func.count(ServiceTicket.id).desc())
    return ServiceGrouped(
        group_by="brand", total=total, buckets=_buckets(list(db.execute(stmt).all()), total)
    )


def _cause_grouped(db: Session, group_by: GroupBy, total: int, **filters) -> ServiceGrouped:
    """분류 / 증상 / 제조사 - 원인 행을 세는 축."""
    col = _CAUSE_AXES[group_by]
    total_causes = db.scalar(
        apply_filters(
            select(func.count(ServiceTicketCause.id))
            .select_from(ServiceTicket)
            .join(ServiceTicketCause, ServiceTicketCause.ticket_id == ServiceTicket.id),
            **filters,
        )
    ) or 0

    stmt = apply_filters(
        select(
            func.coalesce(CodeItem.name, "미분류"),
            func.count(ServiceTicketCause.id),
            None,
            None,
            func.count(distinct(ServiceTicket.id)),
        )
        .select_from(ServiceTicket)
        .join(ServiceTicketCause, ServiceTicketCause.ticket_id == ServiceTicket.id)
        .outerjoin(CodeItem, CodeItem.id == col),
        **filters,
    ).group_by(CodeItem.id, CodeItem.name).order_by(func.count(ServiceTicketCause.id).desc())

    color_stmt = apply_filters(
        select(func.coalesce(CodeItem.name, "미분류"), CodeItem.color)
        .select_from(ServiceTicket)
        .join(ServiceTicketCause, ServiceTicketCause.ticket_id == ServiceTicket.id)
        .outerjoin(CodeItem, CodeItem.id == col),
        **filters,
    ).group_by(CodeItem.id, CodeItem.name, CodeItem.color)
    colors = {name: c for name, c in db.execute(color_stmt).all()}

    # 비율의 분모는 원인 총수다. 대응 건수로 나누면 합이 1 을 넘는다.
    buckets = _buckets(list(db.execute(stmt).all()), total_causes)
    for b in buckets:
        b.color = colors.get(b.key)
    return ServiceGrouped(
        group_by=group_by, total=total, total_causes=total_causes, buckets=buckets
    )


def grouped(db: Session, group_by: GroupBy, **filters) -> ServiceGrouped:
    """Counts + average resolution + cost, bucketed by one classification axis."""
    res_min = resolution_minutes_expr()
    avg_res = func.avg(case((ServiceTicket.completed_at.isnot(None), res_min)))
    cost_sum = func.sum(ServiceTicket.total_cost)

    total = db.scalar(
        apply_filters(select(func.count(ServiceTicket.id)), **filters)
    ) or 0

    if group_by in _CAUSE_AXES:
        return _cause_grouped(db, group_by, total, **filters)

    if group_by == "store":
        return _store_grouped(db, total, **filters)

    if group_by == "brand":
        return _brand_grouped(db, total, **filters)

    if group_by in _CODE_AXES:
        col = _CODE_AXES[group_by]
        stmt = apply_filters(
            select(
                func.coalesce(CodeItem.name, "미분류"),
                func.count(ServiceTicket.id),
                avg_res,
                cost_sum,
            )
            .select_from(ServiceTicket)
            .outerjoin(CodeItem, CodeItem.id == col),
            **filters,
        ).group_by(CodeItem.id, CodeItem.name).order_by(func.count(ServiceTicket.id).desc())
        # Colour comes from the code master so chart and chips agree.
        color_stmt = apply_filters(
            select(func.coalesce(CodeItem.name, "미분류"), CodeItem.color)
            .select_from(ServiceTicket)
            .outerjoin(CodeItem, CodeItem.id == col),
            **filters,
        ).group_by(CodeItem.id, CodeItem.name, CodeItem.color)
        colors = {name: c for name, c in db.execute(color_stmt).all()}
        rows = db.execute(stmt).all()
        buckets = _buckets(list(rows), total)
        for b in buckets:
            b.color = colors.get(b.key)
        return ServiceGrouped(group_by=group_by, total=total, buckets=buckets)

    if group_by == "assignee":
        stmt = apply_filters(
            select(
                func.coalesce(User.full_name, "미배정"),
                func.count(ServiceTicket.id),
                avg_res,
                cost_sum,
            )
            .select_from(ServiceTicket)
            .outerjoin(User, User.id == ServiceTicket.assignee_id),
            **filters,
        ).group_by(User.id, User.full_name).order_by(func.count(ServiceTicket.id).desc())
        return ServiceGrouped(
            group_by=group_by, total=total, buckets=_buckets(list(db.execute(stmt).all()), total)
        )

    simple = {
        "status": (ServiceTicket.status, STATUS_LABELS, STATUS_COLORS),
        "priority": (ServiceTicket.priority, PRIORITY_LABELS, PRIORITY_COLORS),
        "channel": (ServiceTicket.channel, None, None),
        "department": (ServiceTicket.department_id, None, None),
    }
    if group_by not in simple:
        raise AppError("BAD_GROUP_BY", f"지원하지 않는 그룹 기준입니다: {group_by}")

    col, labels, colors = simple[group_by]
    stmt = apply_filters(
        select(col, func.count(ServiceTicket.id), avg_res, cost_sum), **filters
    ).group_by(col).order_by(func.count(ServiceTicket.id).desc())
    return ServiceGrouped(
        group_by=group_by,
        total=total,
        buckets=_buckets(list(db.execute(stmt).all()), total, labels, colors),
    )


# --------------------------------------------------------------- trend
def trend(db: Session, interval: Interval = "day", **filters) -> ServiceTrend:
    """Received vs completed per period, with empty periods omitted."""
    recv_period = period_expr(ServiceTicket.received_at, interval)
    recv_stmt = apply_filters(
        select(recv_period.label("p"), func.count(ServiceTicket.id)), **filters
    ).group_by("p")
    received = {p: c for p, c in db.execute(recv_stmt).all() if p is not None}

    # Completions are bucketed by completed_at, but still filtered on the same
    # received_at window so both series describe the same cohort of tickets.
    comp_period = period_expr(ServiceTicket.completed_at, interval)
    comp_stmt = apply_filters(
        select(comp_period.label("p"), func.count(ServiceTicket.id)).where(
            ServiceTicket.completed_at.isnot(None)
        ),
        **filters,
    ).group_by("p")
    completed = {p: c for p, c in db.execute(comp_stmt).all() if p is not None}

    periods = sorted(set(received) | set(completed))
    return ServiceTrend(
        interval=interval,
        points=[
            TrendPoint(
                period=p, received=received.get(p, 0), completed=completed.get(p, 0)
            )
            for p in periods
        ],
    )
