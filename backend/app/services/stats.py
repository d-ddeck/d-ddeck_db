"""Automatic statistics for the 서비스 module.

Everything is computed in SQL so the numbers stay correct as the ticket table
grows past what a page of rows could hold. Two small dialect shims keep the same
queries working on both SQLite (dev) and PostgreSQL (prod):

  * resolution_minutes_expr() - datetime subtraction has no portable spelling
  * period_expr()             - date_trunc vs strftime

구 서버(CS_Record)의 통계 방식을 그대로 따른다:
  * 분류 축은 대응 건이 아니라 **원인 행**(service_ticket_causes)을 센다. 한 건에
    서비스구분이 셋이면 세 칸에 각각 1 씩 들어가고, 옆에 중복을 뺀 대응 건수를
    같이 보여 준다. 비율의 분모는 원인 총수다.
  * 서비스구분 탭(category_id 필터)은 **그 구분의 원인 행만** 본다. 다른 구분과
    함께 달린 건의 다른 원인은 그 탭에 들어가지 않는다.
  * 연도는 한국 시각 기준이다 (received_at 은 UTC 로 저장된다).
"""

from __future__ import annotations

import uuid
from collections import Counter, defaultdict
from datetime import date, datetime, timezone
from decimal import Decimal
from typing import Literal
from zoneinfo import ZoneInfo

from sqlalchemy import Float, Select, and_, case, cast, distinct, func, or_, select
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
from app.models.inventory import Asset
from app.models.service import (
    ServiceTicket,
    ServiceTicketCause,
    ServiceTicketResponder,
)
from app.models.store import Store
from app.models.user import User
from app.schemas.service import (
    AxisKey,
    BrandYearRow,
    Crosstab,
    CrosstabRow,
    ServiceGrouped,
    ServiceSummary,
    ServiceTrend,
    StatBucket,
    StoreYearRow,
    StoreYears,
    TrendPoint,
)
from app.services import code_master

Interval = Literal["day", "week", "month", "year"]
GroupBy = Literal[
    "category",
    "symptom",
    "maker",
    "cause",
    "action",
    "fault",
    "assignee",
    "status",
    "priority",
    "channel",
    "department",
    "store",
    "brand",
    "responder",
]
CrossAxis = Literal["year", "brand", "store", "category", "symptom", "maker"]

# 한 건에 여러 값이 달리는 축. 이 축들은 service_ticket_causes 를 세므로
# 버킷 합계가 대응 건수보다 커질 수 있다(구 서버와 같은 방식).
MULTI_AXES = ("category", "symptom", "maker")

# 통계 화면의 빈 칸 이름. 구 서버와 같은 글자를 쓴다.
NO_SYMPTOM = "(세부분류 없음)"
NO_MAKER = "(제조사 미상)"
NO_CATEGORY = "미분류"
NO_STORE = "미지정"
NO_BRAND = "미지정"

# 서울 기준 하루 · 한 해. 설정(SYSTEM.timezone)과 맞춘다; 한국은 DST 가 없어
# 고정 오프셋으로 SQL 에서도 같은 값을 만들 수 있다.
LOCAL_TZ = ZoneInfo("Asia/Seoul")

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
        return (
            func.extract(
                "epoch", ServiceTicket.completed_at - ServiceTicket.received_at
            )
            / 60.0
        )
    # SQLite: julianday returns fractional days.
    return (
        func.julianday(ServiceTicket.completed_at)
        - func.julianday(ServiceTicket.received_at)
    ) * 1440.0


def local_expr(column):
    """UTC 컬럼을 한국 시각으로. 연·월 경계가 자정(KST)에 맞게."""
    if settings.is_postgres:
        return func.timezone(LOCAL_TZ.key, column)
    hours = int(LOCAL_TZ.utcoffset(datetime.now(LOCAL_TZ)).total_seconds() // 3600)
    return func.datetime(column, f"{hours:+d} hours")


def period_expr(column, interval: Interval):
    """A sortable text bucket label for the given column."""
    local = local_expr(column)
    if settings.is_postgres:
        fmt = {
            "day": "YYYY-MM-DD",
            "week": 'IYYY-"W"IW',
            "month": "YYYY-MM",
            "year": "YYYY",
        }[interval]
        return func.to_char(func.date_trunc(interval, local), fmt)
    # SQLite has no ISO-week format; %W is Monday-based week-of-year, which is
    # close enough for a trend chart but is not strictly ISO 8601.
    fmt = {"day": "%Y-%m-%d", "week": "%Y-W%W", "month": "%Y-%m", "year": "%Y"}[
        interval
    ]
    return func.strftime(fmt, local)


def to_local(dt: datetime | None) -> datetime | None:
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(LOCAL_TZ)


def local_year(dt: datetime | None) -> str | None:
    loc = to_local(dt)
    return str(loc.year) if loc else None


def local_range(year: int, month: int | None = None) -> tuple[datetime, datetime]:
    """(시작, 끝) UTC. 끝은 배타적."""
    start = datetime(year, month or 1, 1, tzinfo=LOCAL_TZ)
    if month:
        end = datetime(year + (month // 12), (month % 12) + 1, 1, tzinfo=LOCAL_TZ)
    else:
        end = datetime(year + 1, 1, 1, tzinfo=LOCAL_TZ)
    return start.astimezone(timezone.utc), end.astimezone(timezone.utc)


# --------------------------------------------------------------- filtering
def apply_filters(
    stmt: Select,
    *,
    date_from: datetime | None = None,
    date_to: datetime | None = None,
    year: int | None = None,
    month: int | None = None,
    assignee_id: uuid.UUID | None = None,
    department_id: uuid.UUID | None = None,
    category_id: uuid.UUID | None = None,
    symptom_id: uuid.UUID | None = None,
    maker_id: uuid.UUID | None = None,
    fault_id: uuid.UUID | None = None,
    responder_id: uuid.UUID | None = None,
    customer_id: uuid.UUID | None = None,
    store_id: uuid.UUID | None = None,
    brand_id: uuid.UUID | None = None,
    status: ServiceStatus | None = None,
    only_open: bool | None = None,
    is_warranty: bool | None = None,
    is_rental: bool | None = None,
    rental_unreturned: bool | None = None,
    missing: str | None = None,
) -> Select:
    """The one filter definition shared by the list endpoint and every stat.

    분류 · 증상 · 제조사 · 대응인원은 원인/대응인원 행에 하나라도 걸리면 그 건을
    포함한다(구 서버의 EXISTS 와 같다). 대표 분류만 보면 두 번째 원인이 빠진다.
    """
    stmt = stmt.where(ServiceTicket.deleted_at.is_(None))
    for axis in (missing or "").split(","):
        if axis in {"category", "symptom", "maker"}:
            column = getattr(ServiceTicketCause, axis + "_id")
            stmt = stmt.where(
                ServiceTicket.id.in_(
                    select(ServiceTicket.id)
                    .outerjoin(
                        ServiceTicketCause,
                        ServiceTicketCause.ticket_id == ServiceTicket.id,
                    )
                    .where(column.is_(None))
                )
            )
        elif axis in {"store", "fault", "assignee", "department", "customer"}:
            stmt = stmt.where(getattr(ServiceTicket, axis + "_id").is_(None))
        elif axis == "brand":
            stmt = stmt.where(
                or_(
                    ServiceTicket.store_id.is_(None),
                    ServiceTicket.store_id.in_(
                        select(Store.id).where(Store.brand_id.is_(None))
                    ),
                )
            )
        elif axis == "responder":
            stmt = stmt.where(
                ~ServiceTicket.id.in_(
                    select(ServiceTicketResponder.ticket_id).where(
                        ServiceTicketResponder.responder_id.is_not(None)
                    )
                )
            )

    if year is not None:
        lo, hi = local_range(year, month)
        stmt = stmt.where(
            ServiceTicket.received_at >= lo, ServiceTicket.received_at < hi
        )
    if date_from is not None:
        stmt = stmt.where(ServiceTicket.received_at >= date_from)
    if date_to is not None:
        stmt = stmt.where(ServiceTicket.received_at < date_to)
    if assignee_id is not None:
        stmt = stmt.where(ServiceTicket.assignee_id == assignee_id)
    if department_id is not None:
        stmt = stmt.where(ServiceTicket.department_id == department_id)
    if category_id is not None:
        stmt = stmt.where(
            or_(
                ServiceTicket.category_id == category_id,
                ServiceTicket.id.in_(
                    select(ServiceTicketCause.ticket_id).where(
                        ServiceTicketCause.category_id == category_id
                    )
                ),
            )
        )
    if symptom_id is not None:
        stmt = stmt.where(
            or_(
                ServiceTicket.symptom_id == symptom_id,
                ServiceTicket.id.in_(
                    select(ServiceTicketCause.ticket_id).where(
                        ServiceTicketCause.symptom_id == symptom_id
                    )
                ),
            )
        )
    if maker_id is not None:
        stmt = stmt.where(
            ServiceTicket.id.in_(
                select(ServiceTicketCause.ticket_id).where(
                    ServiceTicketCause.maker_id == maker_id
                )
            )
        )
    if fault_id is not None:
        stmt = stmt.where(ServiceTicket.fault_id == fault_id)
    if responder_id is not None:
        stmt = stmt.where(
            ServiceTicket.id.in_(
                select(ServiceTicketResponder.ticket_id).where(
                    ServiceTicketResponder.responder_id == responder_id
                )
            )
        )
    if customer_id is not None:
        stmt = stmt.where(ServiceTicket.customer_id == customer_id)
    if store_id is not None:
        stmt = stmt.where(ServiceTicket.store_id == store_id)
    if brand_id is not None:
        stmt = stmt.where(
            ServiceTicket.store_id.in_(
                select(Store.id).where(
                    Store.brand_id == brand_id, Store.deleted_at.is_(None)
                )
            )
        )
    if status is not None:
        stmt = stmt.where(ServiceTicket.status == status)
    if only_open:
        stmt = stmt.where(ServiceTicket.status.in_(OPEN_SERVICE_STATUSES))
    if is_warranty is not None:
        stmt = stmt.where(ServiceTicket.is_warranty.is_(is_warranty))
    if rental_unreturned:
        stmt = stmt.where(
            ServiceTicket.is_rental.is_(True), ServiceTicket.rental_returned.is_(False)
        )
    elif is_rental is not None:
        stmt = stmt.where(ServiceTicket.is_rental.is_(is_rental))
    return stmt


def _cause_scope(stmt: Select, filters: dict) -> Select:
    """서비스구분 탭: 원인 행도 그 구분으로 좁힌다 (구 서버 stats_tab 과 같다)."""
    category_id = filters.get("category_id")
    if category_id is not None:
        stmt = stmt.where(ServiceTicketCause.category_id == category_id)
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
                avg_resolution_minutes=round(avg_min, 1)
                if avg_min is not None
                else None,
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
            func.sum(
                case((ServiceTicket.status == ServiceStatus.COMPLETED, 1), else_=0)
            ),
            func.sum(
                case((ServiceTicket.status == ServiceStatus.CANCELED, 1), else_=0)
            ),
            func.avg(case((ServiceTicket.completed_at.isnot(None), res_min))),
            func.avg(cast(ServiceTicket.satisfaction, Float)),
            func.sum(ServiceTicket.total_cost),
        ),
        **filters,
    )
    total, open_c, done_c, cancel_c, avg_res, avg_sat, cost = db.execute(base).one()
    total = total or 0

    overdue = (
        db.scalar(
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
        )
        or 0
    )

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
        avg_resolution_minutes=round(float(avg_res), 1)
        if avg_res is not None
        else None,
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
    stmt = (
        apply_filters(
            select(
                Store.id,
                func.count(ServiceTicket.id),
                func.avg(case((ServiceTicket.completed_at.isnot(None), res_min))),
                func.sum(ServiceTicket.total_cost),
            )
            .select_from(ServiceTicket)
            .outerjoin(Store, Store.id == ServiceTicket.store_id),
            **filters,
        )
        .group_by(Store.id, Store.name)
        .order_by(func.count(ServiceTicket.id).desc())
    )
    return ServiceGrouped(
        group_by="store",
        total=total,
        buckets=_buckets(
            list(db.execute(stmt).all()),
            total,
            labels={
                **dict(db.execute(select(Store.id, Store.name)).all()),
                None: NO_STORE,
            },
        ),
    )


def _brand_grouped(db: Session, total: int, **filters) -> ServiceGrouped:
    """브랜드별. 매장에 달린 브랜드 코드를 한 번 더 타고 올라간다."""
    res_min = resolution_minutes_expr()
    stmt = (
        apply_filters(
            select(
                CodeItem.id,
                func.count(ServiceTicket.id),
                func.avg(case((ServiceTicket.completed_at.isnot(None), res_min))),
                func.sum(ServiceTicket.total_cost),
            )
            .select_from(ServiceTicket)
            .outerjoin(Store, Store.id == ServiceTicket.store_id)
            .outerjoin(CodeItem, CodeItem.id == Store.brand_id),
            **filters,
        )
        .group_by(CodeItem.id, CodeItem.name)
        .order_by(func.count(ServiceTicket.id).desc())
    )
    return ServiceGrouped(
        group_by="brand",
        total=total,
        buckets=_buckets(
            list(db.execute(stmt).all()),
            total,
            labels={
                **dict(db.execute(select(CodeItem.id, CodeItem.name)).all()),
                None: "미분류",
            },
        ),
    )


def _responder_grouped(db: Session, total: int, **filters) -> ServiceGrouped:
    """대응인원별. 한 건에 여러 명이 나가므로 사람 행을 센다."""
    stmt = (
        apply_filters(
            select(
                CodeItem.id,
                func.count(ServiceTicketResponder.id),
                None,
                None,
                func.count(distinct(ServiceTicket.id)),
            )
            .select_from(ServiceTicket)
            .join(
                ServiceTicketResponder,
                ServiceTicketResponder.ticket_id == ServiceTicket.id,
            )
            .outerjoin(CodeItem, CodeItem.id == ServiceTicketResponder.responder_id),
            **filters,
        )
        .group_by(CodeItem.id, CodeItem.name)
        .order_by(func.count(ServiceTicketResponder.id).desc())
    )
    rows = list(db.execute(stmt).all())
    denom = sum(r[1] for r in rows)
    return ServiceGrouped(
        group_by="responder",
        total=total,
        total_causes=denom,
        buckets=_buckets(
            rows,
            denom,
            labels={
                **dict(db.execute(select(CodeItem.id, CodeItem.name)).all()),
                None: "미분류",
            },
        ),
    )


def _cause_grouped(
    db: Session, group_by: GroupBy, total: int, **filters
) -> ServiceGrouped:
    """분류 / 증상 / 제조사 - 원인 행을 세는 축."""
    col = _CAUSE_AXES[group_by]
    empty_label = {"category": NO_CATEGORY, "symptom": NO_SYMPTOM, "maker": NO_MAKER}[
        group_by
    ]
    total_causes = (
        db.scalar(
            _cause_scope(
                apply_filters(
                    select(func.count(ServiceTicketCause.id))
                    .select_from(ServiceTicket)
                    .join(
                        ServiceTicketCause,
                        ServiceTicketCause.ticket_id == ServiceTicket.id,
                    ),
                    **filters,
                ),
                filters,
            )
        )
        or 0
    )

    stmt = (
        _cause_scope(
            apply_filters(
                select(
                    CodeItem.id,
                    func.count(ServiceTicketCause.id),
                    None,
                    None,
                    func.count(distinct(ServiceTicket.id)),
                )
                .select_from(ServiceTicket)
                .join(
                    ServiceTicketCause, ServiceTicketCause.ticket_id == ServiceTicket.id
                )
                .outerjoin(CodeItem, CodeItem.id == col),
                **filters,
            ),
            filters,
        )
        .group_by(CodeItem.id, CodeItem.name)
        .order_by(func.count(ServiceTicketCause.id).desc())
    )

    color_stmt = _cause_scope(
        apply_filters(
            select(CodeItem.id, CodeItem.color)
            .select_from(ServiceTicket)
            .join(ServiceTicketCause, ServiceTicketCause.ticket_id == ServiceTicket.id)
            .outerjoin(CodeItem, CodeItem.id == col),
            **filters,
        ),
        filters,
    ).group_by(CodeItem.id, CodeItem.name, CodeItem.color)
    colors = {
        str(key) if key else "UNASSIGNED": c for key, c in db.execute(color_stmt).all()
    }

    # 비율의 분모는 원인 총수다. 대응 건수로 나누면 합이 1 을 넘는다.
    buckets = _buckets(
        list(db.execute(stmt).all()),
        total_causes,
        labels={
            **dict(db.execute(select(CodeItem.id, CodeItem.name)).all()),
            None: empty_label,
        },
    )
    for b in buckets:
        b.color = colors.get(b.key)
    return ServiceGrouped(
        group_by=group_by,
        total=total,
        total_causes=total_causes,
        buckets=buckets,
        tickets_without_cause=_tickets_without_cause(db, **filters),
    )


def grouped(db: Session, group_by: GroupBy, **filters) -> ServiceGrouped:
    """Counts + average resolution + cost, bucketed by one classification axis."""
    res_min = resolution_minutes_expr()
    avg_res = func.avg(case((ServiceTicket.completed_at.isnot(None), res_min)))
    cost_sum = func.sum(ServiceTicket.total_cost)

    total = (
        db.scalar(apply_filters(select(func.count(ServiceTicket.id)), **filters)) or 0
    )

    if group_by in _CAUSE_AXES:
        return _cause_grouped(db, group_by, total, **filters)

    if group_by == "store":
        return _store_grouped(db, total, **filters)

    if group_by == "brand":
        return _brand_grouped(db, total, **filters)

    if group_by == "responder":
        return _responder_grouped(db, total, **filters)

    if group_by in _CODE_AXES:
        col = _CODE_AXES[group_by]
        stmt = (
            apply_filters(
                select(
                    CodeItem.id,
                    func.count(ServiceTicket.id),
                    avg_res,
                    cost_sum,
                )
                .select_from(ServiceTicket)
                .outerjoin(CodeItem, CodeItem.id == col),
                **filters,
            )
            .group_by(CodeItem.id, CodeItem.name)
            .order_by(func.count(ServiceTicket.id).desc())
        )
        # Colour comes from the code master so chart and chips agree.
        color_stmt = apply_filters(
            select(CodeItem.id, CodeItem.color)
            .select_from(ServiceTicket)
            .outerjoin(CodeItem, CodeItem.id == col),
            **filters,
        ).group_by(CodeItem.id, CodeItem.name, CodeItem.color)
        colors = {
            str(key) if key else "UNASSIGNED": c
            for key, c in db.execute(color_stmt).all()
        }
        rows = db.execute(stmt).all()
        buckets = _buckets(
            list(rows),
            total,
            labels={
                **dict(db.execute(select(CodeItem.id, CodeItem.name)).all()),
                None: NO_CATEGORY,
            },
        )
        for b in buckets:
            b.color = colors.get(b.key)
        return ServiceGrouped(group_by=group_by, total=total, buckets=buckets)

    if group_by == "assignee":
        stmt = (
            apply_filters(
                select(
                    User.id,
                    func.count(ServiceTicket.id),
                    avg_res,
                    cost_sum,
                )
                .select_from(ServiceTicket)
                .outerjoin(User, User.id == ServiceTicket.assignee_id),
                **filters,
            )
            .group_by(User.id, User.full_name)
            .order_by(func.count(ServiceTicket.id).desc())
        )
        return ServiceGrouped(
            group_by=group_by,
            total=total,
            buckets=_buckets(
                list(db.execute(stmt).all()),
                total,
                labels={
                    **dict(db.execute(select(User.id, User.full_name)).all()),
                    None: "미배정",
                },
            ),
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
    stmt = (
        apply_filters(
            select(col, func.count(ServiceTicket.id), avg_res, cost_sum), **filters
        )
        .group_by(col)
        .order_by(func.count(ServiceTicket.id).desc())
    )
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


# --------------------------------------------------------------- crosstab (구 서버 통계 표)
class _CauseRow:
    """원인 한 줄 = (건, 연도, 브랜드, 매장, 서비스구분, 증상, 제조사).

    구 서버 stats_base() 의 한 줄과 같다. 표는 이 줄들을 파이썬에서 센다 - 자료가
    연 수백 건 규모라 SQL 크로스탭보다 이쪽이 읽기 쉽고 방언도 안 탄다.
    """

    __slots__ = ("brand", "category", "maker", "store", "symptom", "ticket_id", "year")

    def __init__(self, ticket_id, year, brand, store, category, symptom, maker):
        self.ticket_id = ticket_id
        self.year = year
        self.brand = brand
        self.store = store
        self.category = category
        self.symptom = symptom
        self.maker = maker


def _cause_rows(db: Session, **filters) -> list[_CauseRow]:
    stmt = _cause_scope(
        apply_filters(
            select(
                ServiceTicket.id,
                ServiceTicket.received_at,
                Store.brand_id,
                Store.id,
                ServiceTicketCause.category_id,
                ServiceTicketCause.symptom_id,
                ServiceTicketCause.maker_id,
            )
            .select_from(ServiceTicket)
            .join(ServiceTicketCause, ServiceTicketCause.ticket_id == ServiceTicket.id)
            .outerjoin(Store, Store.id == ServiceTicket.store_id),
            **filters,
        ),
        filters,
    )
    return [
        _CauseRow(tid, local_year(received), brand, store, cat, sym, mk)
        for tid, received, brand, store, cat, sym, mk in db.execute(stmt).all()
    ]


def _code_items_of(
    db: Session, group_code: str, parent_id: uuid.UUID | None = None
) -> list[CodeItem]:
    return code_master.items(db, group_code, parent_id=parent_id)


def _axis_keys(
    db: Session, axis: CrossAxis, rows: list[_CauseRow], filters: dict
) -> tuple[list[AxisKey], dict]:
    """축의 (표시 순서가 정해진 키 목록, 행 -> 키 함수).

    목록형 축(브랜드 · 서비스구분 · 증상)은 건이 없어도 목록 항목을 모두 보여 준다
    (구 서버: 새로 추가한 항목이 바로 표에 나타난다). 매장 · 제조사 · 연도는 쓰인
    값만.
    """
    if axis == "year":
        used = sorted({r.year for r in rows if r.year})
        return [AxisKey(key=y, label=y) for y in used], (lambda r: r.year)

    if axis == "brand":
        items = _code_items_of(db, "STORE_BRAND")
        keys = [AxisKey(key=str(i.id), label=i.name, color=i.color) for i in items]
        known = {k.key for k in keys}
        used = {str(r.brand) for r in rows if r.brand} - known
        names = (
            {
                str(i.id): i.name
                for i in db.scalars(
                    select(CodeItem).where(
                        CodeItem.id.in_([uuid.UUID(u) for u in used])
                    )
                )
            }
            if used
            else {}
        )
        keys += [AxisKey(key=u, label=names.get(u, u)) for u in sorted(used)]
        if any(r.brand is None for r in rows):
            keys.append(AxisKey(key="-", label=NO_BRAND))
        return keys, (lambda r: str(r.brand) if r.brand else "-")

    if axis == "store":
        totals = Counter(str(r.store) if r.store else "-" for r in rows)
        ids = [uuid.UUID(k) for k in totals if k != "-"]
        stores = (
            {str(s.id): s for s in db.scalars(select(Store).where(Store.id.in_(ids)))}
            if ids
            else {}
        )
        ordered = sorted(
            totals, key=lambda k: (-totals[k], stores[k].name if k in stores else "~")
        )
        keys = [
            AxisKey(key=k, label=(stores[k].name if k in stores else NO_STORE))
            for k in ordered
        ]
        return keys, (lambda r: str(r.store) if r.store else "-")

    if axis == "category":
        items = _code_items_of(db, "SERVICE_CATEGORY")
        keys = [AxisKey(key=str(i.id), label=i.name, color=i.color) for i in items]
        known = {k.key for k in keys}
        used = {str(r.category) for r in rows if r.category} - known
        names = (
            {
                str(i.id): i.name
                for i in db.scalars(
                    select(CodeItem).where(
                        CodeItem.id.in_([uuid.UUID(u) for u in used])
                    )
                )
            }
            if used
            else {}
        )
        keys += [AxisKey(key=u, label=names.get(u, u)) for u in sorted(used)]
        if any(r.category is None for r in rows):
            keys.append(AxisKey(key="-", label=NO_CATEGORY))
        return keys, (lambda r: str(r.category) if r.category else "-")

    if axis == "symptom":
        # 서비스구분 탭이면 그 구분의 증상만 열로. 아니면 쓰인 것만.
        parent = filters.get("category_id")
        items = _code_items_of(db, "SERVICE_SYMPTOM", parent) if parent else []
        keys = [AxisKey(key=str(i.id), label=i.name, color=i.color) for i in items]
        known = {k.key for k in keys}
        used = {str(r.symptom) for r in rows if r.symptom} - known
        if used:
            extra = {
                str(i.id): i
                for i in db.scalars(
                    select(CodeItem).where(
                        CodeItem.id.in_([uuid.UUID(u) for u in used])
                    )
                )
            }
            keys += [
                AxisKey(key=u, label=extra[u].name if u in extra else u)
                for u in sorted(
                    used, key=lambda u: extra[u].sort_order if u in extra else 999
                )
            ]
        if any(r.symptom is None for r in rows):
            keys.append(AxisKey(key="-", label=NO_SYMPTOM))
        return keys, (lambda r: str(r.symptom) if r.symptom else "-")

    if axis == "maker":
        totals = Counter(str(r.maker) if r.maker else "-" for r in rows)
        ids = [uuid.UUID(k) for k in totals if k != "-"]
        makers = (
            {
                str(i.id): i
                for i in db.scalars(select(CodeItem).where(CodeItem.id.in_(ids)))
            }
            if ids
            else {}
        )
        ordered = sorted(
            totals,
            key=lambda k: (k == "-", -totals[k], makers[k].name if k in makers else ""),
        )
        keys = [
            AxisKey(
                key=k,
                label=(makers[k].name if k in makers else NO_MAKER),
                color=(makers[k].color if k in makers else None),
            )
            for k in ordered
        ]
        return keys, (lambda r: str(r.maker) if r.maker else "-")

    raise AppError("BAD_AXIS", f"지원하지 않는 축입니다: {axis}")


def crosstab(
    db: Session, rows_axis: CrossAxis, cols_axis: CrossAxis, **filters
) -> Crosstab:
    """행 축 × 열 축 표. 칸은 원인 수, 줄 끝에 합계 · 대응 건수 · 비율."""
    if rows_axis == cols_axis:
        raise AppError("BAD_AXIS", "행과 열에 같은 축을 쓸 수 없습니다.")
    rows = _cause_rows(db, **filters)
    row_keys, row_of = _axis_keys(db, rows_axis, rows, filters)
    col_keys, col_of = _axis_keys(db, cols_axis, rows, filters)

    cells: dict[str, Counter] = defaultdict(Counter)
    tickets: dict[str, set] = defaultdict(set)
    col_totals: Counter = Counter()
    for r in rows:
        rk, ck = row_of(r), col_of(r)
        cells[rk][ck] += 1
        tickets[rk].add(r.ticket_id)
        col_totals[ck] += 1

    total = len(rows)
    out_rows: list[CrosstabRow] = []
    for k in row_keys:
        line = cells.get(k.key, Counter())
        n = sum(line.values())
        out_rows.append(
            CrosstabRow(
                key=k.key,
                label=k.label,
                color=k.color,
                cells={c.key: line.get(c.key, 0) for c in col_keys},
                total=n,
                ticket_count=len(tickets.get(k.key, ())),
                ratio=round(n / total, 4) if total else 0.0,
            )
        )
    return Crosstab(
        rows_axis=rows_axis,
        cols_axis=cols_axis,
        cols=col_keys,
        rows=out_rows,
        col_totals={c.key: col_totals.get(c.key, 0) for c in col_keys},
        total_causes=total,
        total_tickets=len({r.ticket_id for r in rows})
        + _tickets_without_cause(db, **filters),
        tickets_without_cause=_tickets_without_cause(db, **filters),
    )


# --------------------------------------------------------------- 연도별 운영 매장 (메인 탭)
def store_years(db: Session) -> StoreYears:
    """매장별 운영 기간을 추정해 연도별 운영 매장 수를 낸다 (구 서버 store_years).

    개점 연도 = 개점일이 있으면 그것, 없으면 첫 대응 기록일 · 첫 장비 설치일 중 이른 날.
    폐점 연도 = 폐점에 체크된 매장만: 폐점일이 있으면 그것, 없으면 마지막 기록 연도(없으면 개점 연도).
    """
    first: dict[uuid.UUID, datetime] = {}
    last: dict[uuid.UUID, datetime] = {}
    per_year_tickets: Counter = Counter()
    active_by_year: dict[str, set] = defaultdict(set)
    for sid, received in db.execute(
        select(ServiceTicket.store_id, ServiceTicket.received_at).where(
            ServiceTicket.deleted_at.is_(None)
        )
    ).all():
        y = local_year(received)
        if y:
            per_year_tickets[y] += 1
            if sid:
                active_by_year[y].add(sid)
        if sid is None or received is None:
            continue
        if sid not in first or received < first[sid]:
            first[sid] = received
        if sid not in last or received > last[sid]:
            last[sid] = received

    installed: dict[uuid.UUID, date] = {}
    for sid, d in db.execute(
        select(Asset.store_id, func.min(Asset.purchase_date))
        .where(
            Asset.deleted_at.is_(None),
            Asset.store_id.isnot(None),
            Asset.purchase_date.isnot(None),
        )
        .group_by(Asset.store_id)
    ).all():
        if d:
            installed[sid] = (
                d if isinstance(d, date) else date.fromisoformat(str(d)[:10])
            )

    brands = {i.id: i for i in _code_items_of(db, "STORE_BRAND")}
    order_b = {bid: n for n, bid in enumerate(brands)}
    stores = list(
        db.scalars(select(Store).where(Store.deleted_at.is_(None)).order_by(Store.name))
    )

    info = []
    for s in stores:
        seen = []
        if s.id in first:
            seen.append(to_local(first[s.id]).date())
        if s.id in installed:
            seen.append(installed[s.id])
        opened = s.open_date or (min(seen) if seen else None)
        open_y = str(opened.year) if opened else None
        closed_y = None
        if s.is_closed:
            if s.closed_date:
                closed_y = str(s.closed_date.year)
            elif s.id in last:
                closed_y = local_year(last[s.id])
            else:
                closed_y = open_y
        info.append((s, open_y, closed_y))

    cur = str(datetime.now(LOCAL_TZ).year)
    years_seen = [y for y in per_year_tickets if y.isdigit() and y >= "2000"] + [cur]
    years = [str(y) for y in range(int(min(years_seen)), int(cur) + 1)]

    rows: list[StoreYearRow] = []
    op: dict[str, list] = {}
    for y in years:
        op[y] = [t for t in info if t[1] and t[1] <= y and (t[2] is None or t[2] >= y)]
        n = len(op[y])
        rec = per_year_tickets.get(y, 0)
        rows.append(
            StoreYearRow(
                year=y,
                operating=n,
                opened=sum(1 for t in info if t[1] == y),
                closed=sum(1 for t in info if t[2] == y),
                year_end=sum(1 for t in op[y] if t[2] != y),
                active=len(active_by_year.get(y, ())),
                tickets=rec,
                per_store=round(rec / n, 1) if n else None,
            )
        )

    by_brand: list[BrandYearRow] = []
    brand_ids = sorted(
        {t[0].brand_id for t in info if t[1]},
        key=lambda b: (order_b.get(b, 99), str(b)),
    )
    for bid in brand_ids:
        label = brands[bid].name if bid in brands else NO_BRAND
        by_brand.append(
            BrandYearRow(
                brand=label,
                counts={
                    y: sum(1 for t in op[y] if t[0].brand_id == bid) for y in years
                },
            )
        )
    by_brand.append(BrandYearRow(brand="전체", counts={y: len(op[y]) for y in years}))

    return StoreYears(
        years=years,
        rows=rows,
        by_brand=by_brand,
        total_stores=len(info),
        closed_stores=sum(1 for t in info if t[0].is_closed),
        unknown_open=[t[0].name for t in info if not t[1]],
    )


def _tickets_without_cause(db: Session, **filters) -> int:
    return (
        db.scalar(
            apply_filters(
                select(func.count(ServiceTicket.id)).where(
                    ~select(ServiceTicketCause.id)
                    .where(ServiceTicketCause.ticket_id == ServiceTicket.id)
                    .exists()
                ),
                **filters,
            )
        )
        or 0
    )
