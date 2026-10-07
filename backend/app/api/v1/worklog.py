"""근무일지 module (구 서버 CS_Record 규칙 그대로).

- 작성자·일자마다 한 장. 같은 날 두 장을 쓰려 하면 먼저 쓴 장을 알려 준다(409, details.id).
- 직급은 계정(관리 › 사용자)에 적힌 것을 그대로 쓰고 폼에서 못 바꾼다. 계정에 없으면 목록에서 고른다.
- 금일 업무 요약은 줄마다 "1. 2. 3." 번호를 다시 매긴다.
- 18:00 이후 근무는 자동으로 연장 근무이고 사유가 필요하다. 아니면 사유를 비운다.
- 보기(고정): 본인·등록한 계정, 같은 부서 팀장, 관리자·최고 관리자 (worklog_access).
  고치기·지우기: 본인·등록한 계정·관리자.
- 임시 저장: 계정마다 한 장. 등록하면 지워진다.
- 첨부: 공용 /files (entity_type=worklog).
"""

from __future__ import annotations

import base64
import re
import uuid
from datetime import date
from typing import Annotated, Literal
from urllib.parse import quote
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Query, Response, status
from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from app.core.deps import Client, CurrentUser, DbSession, PageParams
from app.core.errors import AppError
from app.core.security import now_utc
from app.models.admin import Attachment, CodeGroup, CodeItem
from app.models.enums import AuditAction, ModuleKey, WorkLogVisibility
from app.models.user import User
from app.models.worklog import WorkLog, WorkLogDraft
from app.schemas.common import Message, Page, UserBrief
from app.schemas.worklog import (
    OvertimeDay,
    OvertimeSummary,
    WorkLogCreate,
    WorkLogDetail,
    WorkLogDraftIn,
    WorkLogDraftOut,
    WorkLogLookups,
    WorkLogOut,
    WorkLogUpdate,
)
from app.services import audit, excel, settings_store
from app.services import worklog_access as access
from app.services import worklog_pdf as worklog_pdf_service

router = APIRouter(prefix="/worklogs", tags=["worklogs"])

POSITION_GROUP = "WORKLOG_POSITION"
KST = ZoneInfo("Asia/Seoul")
Scope = Literal["mine", "team", "all"]
_NUM_PREFIX = re.compile(r"^\s*(?:\(?\d+[.)]|\d+\s*[-:]|[①②③④⑤⑥⑦⑧⑨⑩]|[-•·*])\s*")
_TIME = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")
# 정규 근무 09:00~18:00. 18:00 이후 근무만 연장으로 본다(09:00 이전 근무는 넣지 않는다).
REGULAR_END = 18 * 60


def overtime_minutes(start: str, end: str) -> int:
    """18:00 이후 근무 분. 종료가 시작보다 이르면 자정을 넘긴 것으로 본다."""
    s = int(start[:2]) * 60 + int(start[3:])
    e = int(end[:2]) * 60 + int(end[3:])
    if e <= s:
        e += 24 * 60
    return max(0, e - max(s, REGULAR_END))


def numbered(text: str) -> str:
    """줄마다 '1. ' '2. ' 번호를 다시 붙인다 (이미 붙은 번호·글머리표는 떼고, 빈 줄은 뺌)."""
    lines = [_NUM_PREFIX.sub("", ln).strip() for ln in (text or "").splitlines()]
    lines = [ln for ln in lines if ln]
    return "\n".join(f"{i}. {ln}" for i, ln in enumerate(lines, 1))


def _load(db: Session, log_id: uuid.UUID) -> WorkLog:
    log = db.scalar(
        select(WorkLog).where(WorkLog.id == log_id, WorkLog.deleted_at.is_(None))
    )
    if log is None:
        raise AppError(
            "NOT_FOUND", "근무일지를 찾을 수 없습니다.", status.HTTP_404_NOT_FOUND
        )
    return log


def _scope_where(stmt, scope: Scope, user: User):
    """mine 은 내 일지. team·all 은 볼 수 있는 일지 전체(부서 팀장은 부서원, 관리자는 전체)."""
    if scope == "mine":
        return stmt.where(access.mine_clause(user))
    return stmt.where(access.visible_clause(user))


def _query(
    db: Session,
    user: User,
    *,
    scope: Scope,
    year: int | None,
    month: int | None,
    author_id: uuid.UUID | None,
    overtime: bool | None,
    q: str | None,
):
    stmt = select(WorkLog).where(WorkLog.deleted_at.is_(None))
    stmt = _scope_where(stmt, scope, user)
    if year:
        lo = date(year, month or 1, 1)
        hi = date(
            year + (1 if not month or month == 12 else 0),
            1 if not month or month == 12 else month + 1,
            1,
        )
        stmt = stmt.where(WorkLog.work_date >= lo, WorkLog.work_date < hi)
    if author_id:
        stmt = stmt.where(WorkLog.author_id == author_id)
    if overtime is not None:
        stmt = stmt.where(WorkLog.overtime.is_(overtime))
    if q:
        like = f"%{q.strip()}%"
        stmt = stmt.where(
            or_(
                WorkLog.summary.ilike(like),
                WorkLog.detail.ilike(like),
                WorkLog.plan.ilike(like),
                WorkLog.needs.ilike(like),
                WorkLog.author_name.ilike(like),
            )
        )
    return stmt


def _attachment_counts(db: Session, ids: list[uuid.UUID]) -> dict[uuid.UUID, int]:
    if not ids:
        return {}
    rows = db.execute(
        select(Attachment.entity_id, func.count(Attachment.id))
        .where(
            Attachment.entity_type == "worklog",
            Attachment.entity_id.in_(ids),
            Attachment.deleted_at.is_(None),
        )
        .group_by(Attachment.entity_id)
    ).all()
    return {i: n for i, n in rows}


def _out(log: WorkLog, user: User, n_files: int, cls=WorkLogOut):
    out = cls.model_validate(log)
    out.attachment_count = n_files
    out.can_edit = access.can_edit(log, user)
    if _TIME.match(log.work_start) and _TIME.match(log.work_end):
        out.overtime_minutes = overtime_minutes(log.work_start, log.work_end)
        out.overtime = out.overtime_minutes > 0
    return out


def _detail(db: Session, log: WorkLog, user: User) -> WorkLogDetail:
    out = _out(
        log, user, _attachment_counts(db, [log.id]).get(log.id, 0), WorkLogDetail
    )
    ids = {i for i in (log.author_id, log.created_by_id, log.updated_by_id) if i}
    users = (
        {u.id: u for u in db.scalars(select(User).where(User.id.in_(ids))).all()}
        if ids
        else {}
    )
    brief = lambda i: UserBrief.model_validate(users[i]) if i in users else None
    out.author, out.created_by, out.updated_by = (
        brief(log.author_id),
        brief(log.created_by_id),
        brief(log.updated_by_id),
    )
    return out


# ------------------------------------------------------------------ 기본값 · 임시 저장
def _positions(db: Session) -> list[str]:
    group = db.scalar(select(CodeGroup).where(CodeGroup.code == POSITION_GROUP))
    if group is None:
        return []
    return [
        i.name
        for i in db.scalars(
            select(CodeItem)
            .where(
                CodeItem.group_id == group.id,
                CodeItem.deleted_at.is_(None),
                CodeItem.is_active.is_(True),
            )
            .order_by(CodeItem.sort_order, CodeItem.name)
        )
    ]


def _draft(db: Session, user: User) -> WorkLogDraftOut | None:
    row = db.scalar(select(WorkLogDraft).where(WorkLogDraft.user_id == user.id))
    if row is None or not isinstance(row.data, dict):
        return None
    return WorkLogDraftOut(data=row.data, saved_at=row.saved_at)


@router.get("/lookups", response_model=WorkLogLookups)
def lookups(
    db: DbSession, user: CurrentUser, scope: Annotated[Scope, Query()] = "mine"
) -> WorkLogLookups:
    """새 일지를 열 때 필요한 것: 직급 목록·계정 직급·내 이름·지난 일지의 근무시간·임시 저장·작성자·연도."""
    last = db.scalar(
        select(WorkLog)
        .where(WorkLog.author_id == user.id, WorkLog.deleted_at.is_(None))
        .order_by(WorkLog.work_date.desc())
        .limit(1)
    )
    start = (
        last.work_start
        if last
        else str(
            settings_store.get(db, ModuleKey.WORKLOG, "default_work_start", "09:00")
        )
    )
    end = (
        last.work_end
        if last
        else str(settings_store.get(db, ModuleKey.WORKLOG, "default_work_end", "18:00"))
    )

    visible = _scope_where(
        select(WorkLog.author_id).where(
            WorkLog.deleted_at.is_(None), WorkLog.author_id.isnot(None)
        ),
        scope,
        user,
    ).distinct()
    author_ids = [i for (i,) in db.execute(visible).all()]
    authors = (
        [
            UserBrief.model_validate(u)
            for u in db.scalars(
                select(User).where(User.id.in_(author_ids)).order_by(User.full_name)
            ).all()
        ]
        if author_ids
        else []
    )
    years_stmt = _scope_where(
        select(WorkLog.work_date).where(WorkLog.deleted_at.is_(None)), scope, user
    )
    years = sorted({d.year for (d,) in db.execute(years_stmt).all()}, reverse=True)
    return WorkLogLookups(
        positions=_positions(db),
        fixed_position=user.position or None,
        author_name=user.full_name,
        default_work_start=start,
        default_work_end=end,
        authors=authors,
        years=years,
        draft=_draft(db, user),
    )


@router.get("/draft", response_model=WorkLogDraftOut | None)
def get_draft(db: DbSession, user: CurrentUser):
    return _draft(db, user)


@router.put("/draft", response_model=WorkLogDraftOut)
def save_draft(
    payload: WorkLogDraftIn, db: DbSession, user: CurrentUser
) -> WorkLogDraftOut:
    """[임시 저장] 버튼과 입력 중 자동 저장이 같이 쓴다. 검사하지 않고 그대로 보관한다."""
    row = db.scalar(select(WorkLogDraft).where(WorkLogDraft.user_id == user.id))
    if row is None:
        row = WorkLogDraft(user_id=user.id)
        db.add(row)
    row.data = payload.data
    row.saved_at = now_utc()
    db.commit()
    return WorkLogDraftOut(data=row.data, saved_at=row.saved_at)


@router.delete("/draft", response_model=Message)
def discard_draft(db: DbSession, user: CurrentUser) -> Message:
    row = db.scalar(select(WorkLogDraft).where(WorkLogDraft.user_id == user.id))
    if row is not None:
        db.delete(row)
        db.commit()
    return Message(message="임시 저장한 내용을 버렸습니다.")


# ------------------------------------------------------------------ 목록 · 엑셀
@router.get("", response_model=Page[WorkLogOut])
def list_worklogs(
    db: DbSession,
    user: CurrentUser,
    page: PageParams,
    scope: Annotated[
        Scope,
        Query(description="mine: 내 일지 / team: 내 일지+팀 공개 / all: 관리자 전체"),
    ] = "mine",
    year: Annotated[int | None, Query(ge=2000, le=2100)] = None,
    month: Annotated[int | None, Query(ge=1, le=12)] = None,
    author_id: uuid.UUID | None = None,
    overtime: bool | None = None,
    q: Annotated[str | None, Query(description="요약·상세·예정·요청·작성자")] = None,
) -> Page[WorkLogOut]:
    stmt = _query(
        db,
        user,
        scope=scope,
        year=year,
        month=month,
        author_id=author_id,
        overtime=overtime,
        q=q,
    )
    total = db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    rows = list(
        db.scalars(
            stmt.order_by(WorkLog.work_date.desc(), WorkLog.author_name)
            .offset(page.offset)
            .limit(page.size)
        ).all()
    )
    counts = _attachment_counts(db, [r.id for r in rows])
    return Page.build(
        [_out(r, user, counts.get(r.id, 0)) for r in rows], total, page.page, page.size
    )


def _overtime_summary(
    db: Session, user: User, year: int, month: int
) -> OvertimeSummary:
    """내 일지의 한 달 연장 근무: 18:00 이후 근무가 있는 날과 사유, 총 시간."""
    first = date(year, month, 1)
    last = date(year + month // 12, month % 12 + 1, 1)
    rows = db.scalars(
        select(WorkLog)
        .where(
            WorkLog.author_id == user.id,
            WorkLog.deleted_at.is_(None),
            WorkLog.work_date >= first,
            WorkLog.work_date < last,
        )
        .order_by(WorkLog.work_date)
    ).all()
    items = [
        OvertimeDay(
            id=w.id,
            work_date=w.work_date,
            work_start=w.work_start,
            work_end=w.work_end,
            minutes=minutes,
            reason=w.overtime_note,
        )
        for w in rows
        if _TIME.match(w.work_start)
        and _TIME.match(w.work_end)
        and (minutes := overtime_minutes(w.work_start, w.work_end)) > 0
    ]
    return OvertimeSummary(
        year=year,
        month=month,
        items=items,
        total_minutes=sum(i.minutes for i in items),
    )


@router.get("/overtime-summary", response_model=OvertimeSummary)
def overtime_summary(
    db: DbSession,
    user: CurrentUser,
    year: Annotated[int, Query(ge=2000, le=2100)],
    month: Annotated[int, Query(ge=1, le=12)],
) -> OvertimeSummary:
    return _overtime_summary(db, user, year, month)


@router.get("/overtime-summary.pdf")
def overtime_summary_pdf(
    db: DbSession,
    user: CurrentUser,
    year: Annotated[int, Query(ge=2000, le=2100)],
    month: Annotated[int, Query(ge=1, le=12)],
) -> Response:
    summary = _overtime_summary(db, user, year, month)
    pdf = worklog_pdf_service.render_overtime(
        {
            "year": year,
            "month": month,
            "author_name": user.full_name,
            "position": user.position,
            "total_minutes": summary.total_minutes,
            "items": [
                {
                    "work_date": i.work_date.isoformat(),
                    "work_start": i.work_start,
                    "work_end": i.work_end,
                    "minutes": i.minutes,
                    "reason": i.reason,
                }
                for i in summary.items
            ],
        },
        now_utc().astimezone(KST).strftime("%Y-%m-%d %H:%M"),
        logo=_company_logo(db),
    )
    return _pdf_response(
        pdf,
        f"overtime_{year}-{month:02d}.pdf",
        f"연장근무_{year}-{month:02d}_{user.full_name}.pdf",
    )


@router.get("/export.xlsx")
def export_worklogs(
    db: DbSession,
    user: CurrentUser,
    scope: Annotated[Scope, Query()] = "mine",
    year: Annotated[int | None, Query(ge=2000, le=2100)] = None,
    month: Annotated[int | None, Query(ge=1, le=12)] = None,
    author_id: uuid.UUID | None = None,
    overtime: bool | None = None,
    q: str | None = None,
):
    stmt = _query(
        db,
        user,
        scope=scope,
        year=year,
        month=month,
        author_id=author_id,
        overtime=overtime,
        q=q,
    )
    rows = list(db.scalars(stmt.order_by(WorkLog.work_date, WorkLog.author_name)).all())
    counts = _attachment_counts(db, [r.id for r in rows])
    head = [
        "일자",
        "작성자",
        "직급",
        "근무 시작",
        "근무 종료",
        "금일 업무 내용 요약",
        "금일 근무 내용 상세",
        "연장 근무",
        "연장 시간",
        "연장 근무 사유",
        "예정 업무",
        "필요/요청사항",
        "첨부 수",
    ]
    lines = [
        [
            w.work_date,
            w.author_name,
            w.position or "",
            w.work_start,
            w.work_end,
            w.summary,
            w.detail,
            "O" if (minutes := overtime_minutes(w.work_start, w.work_end)) else "X",
            f"{minutes // 60}:{minutes % 60:02d}" if minutes else "",
            w.overtime_note or "",
            w.plan or "",
            w.needs or "",
            counts.get(w.id, 0),
        ]
        for w in rows
    ]
    wb = excel.workbook()
    excel.fill_sheet(
        wb.create_sheet("근무일지"),
        head,
        lines,
        [11, 10, 8, 9, 9, 36, 50, 8, 8, 24, 36, 30, 7],
        wrap_cols=(5, 6, 9, 10, 11),
    )
    tag = (rows[0].author_name if author_id and rows else "전체") + (
        f"_{year}" + (f"-{month:02d}" if month else "") if year else ""
    )
    return excel.to_response(wb, f"근무일지_{tag}.xlsx")


# ------------------------------------------------------------------ 등록 · 보기 · 수정 · 삭제
def _validate(db: Session, user: User, data: dict, *, existing: WorkLog | None) -> None:
    times = {}
    for k in ("work_start", "work_end"):
        v = data.get(k) if k in data else getattr(existing, k, None)
        if not v or not _TIME.match(v):
            raise AppError("BAD_TIME", "근무시간(시작·종료)을 HH:MM 으로 입력하세요.")
        times[k] = v
    if "summary" in data:
        data["summary"] = numbered(data["summary"])
        if not data["summary"]:
            raise AppError("SUMMARY_REQUIRED", "금일 업무 내용 요약을 입력하세요.")
    if "detail" in data and not (data["detail"] or "").strip():
        raise AppError("DETAIL_REQUIRED", "금일 근무 내용 상세를 입력하세요.")
    # 공개 범위는 고르지 않는다. 열람은 worklog_access 규칙으로 고정.
    data["visibility"] = WorkLogVisibility.PRIVATE
    # 연장 여부는 근무시간으로 정한다. 보내온 값은 쓰지 않는다.
    overtime = overtime_minutes(times["work_start"], times["work_end"]) > 0
    data["overtime"] = overtime
    if not overtime:
        data["overtime_note"] = None
    else:
        note = data.get("overtime_note", existing.overtime_note if existing else None)
        if not (note or "").strip():
            raise AppError(
                "OVERTIME_REASON_REQUIRED",
                "18:00 이후 근무는 연장 근무입니다. 연장 근무 사유를 입력하세요.",
            )
    # 직급: 계정에 있으면 그대로, 없으면 목록에서 골라야 한다
    if user.position and (existing is None or existing.author_id == user.id):
        data["position"] = user.position
    elif existing is None or "position" in data:
        pos = (
            data.get("position") or (existing.position if existing else "") or ""
        ).strip()
        if not pos:
            raise AppError(
                "POSITION_REQUIRED",
                "직급을 고르세요. (관리 › 계정에 직급을 지정하면 자동으로 채워집니다)",
            )
        data["position"] = pos


def _duplicate(
    db: Session, author_id: uuid.UUID, work_date: date, exclude: uuid.UUID | None = None
) -> WorkLog | None:
    stmt = select(WorkLog).where(
        WorkLog.author_id == author_id,
        WorkLog.work_date == work_date,
        WorkLog.deleted_at.is_(None),
    )
    if exclude is not None:
        stmt = stmt.where(WorkLog.id != exclude)
    return db.scalar(stmt.limit(1))


@router.post("", response_model=WorkLogDetail, status_code=status.HTTP_201_CREATED)
def create_worklog(
    payload: WorkLogCreate, db: DbSession, user: CurrentUser, client: Client
) -> WorkLogDetail:
    data = payload.model_dump()
    _validate(db, user, data, existing=None)
    dup = _duplicate(db, user.id, data["work_date"])
    if dup is not None:
        raise AppError(
            "WORKLOG_EXISTS",
            f"{data['work_date'].isoformat()} 근무일지가 이미 있습니다. 그 일지를 열어 내용을 고쳐서 저장하세요.",
            status.HTTP_409_CONFLICT,
            {"id": str(dup.id)},
        )
    log = WorkLog(
        **data,
        author_id=user.id,
        author_name=user.full_name,
        created_by_id=user.id,
        updated_by_id=user.id,
    )
    db.add(log)
    db.flush()
    draft = db.scalar(select(WorkLogDraft).where(WorkLogDraft.user_id == user.id))
    if draft is not None:
        db.delete(draft)  # 등록됐으니 임시 저장은 지운다
    audit.record(
        db,
        action=AuditAction.CREATE,
        actor=user,
        module=ModuleKey.WORKLOG,
        entity_type="worklog",
        entity_id=log.id,
        summary=f"근무일지 등록 {log.work_date} {log.author_name}",
        client=client,
    )
    db.commit()
    return _detail(db, log, user)


@router.get("/{log_id}", response_model=WorkLogDetail)
def get_worklog(log_id: uuid.UUID, db: DbSession, user: CurrentUser) -> WorkLogDetail:
    log = _load(db, log_id)
    if not access.can_view(db, log, user):
        raise AppError(
            "FORBIDDEN",
            "근무일지는 작성자, 같은 부서 팀장, 관리자만 볼 수 있습니다.",
            status.HTTP_403_FORBIDDEN,
        )
    return _detail(db, log, user)


def _company_logo(db: Session) -> bytes | None:
    """견적서에 등록한 회사 로고를 근무일지 PDF 에도 쓴다."""
    configured = settings_store.get(db, ModuleKey.SERVICE, "quotation_logo", {})
    if isinstance(configured, dict) and configured.get("png_base64"):
        try:
            return base64.b64decode(configured["png_base64"], validate=True)
        except ValueError:
            return None
    return None


@router.get("/{log_id}/pdf")
def worklog_pdf(log_id: uuid.UUID, db: DbSession, user: CurrentUser) -> Response:
    log = _load(db, log_id)
    if not access.can_view(db, log, user):
        raise AppError(
            "FORBIDDEN",
            "근무일지는 작성자, 같은 부서 팀장, 관리자만 볼 수 있습니다.",
            status.HTTP_403_FORBIDDEN,
        )
    names = db.scalars(
        select(Attachment.original_name)
        .where(
            Attachment.entity_type == "worklog",
            Attachment.entity_id == log.id,
            Attachment.deleted_at.is_(None),
        )
        .order_by(Attachment.created_at)
    ).all()
    pdf = worklog_pdf_service.render(
        {
            "work_date": log.work_date.isoformat(),
            "work_start": log.work_start,
            "work_end": log.work_end,
            "author_name": log.author_name,
            "position": log.position,
            "overtime_minutes": overtime_minutes(log.work_start, log.work_end),
            "overtime_note": log.overtime_note,
            "summary": log.summary,
            "detail": log.detail,
            "plan": log.plan,
            "needs": log.needs,
        },
        list(names),
        now_utc().astimezone(KST).strftime("%Y-%m-%d %H:%M"),
        logo=_company_logo(db),
    )
    return _pdf_response(
        pdf,
        f"worklog_{log.work_date.isoformat()}.pdf",
        f"근무일지_{log.work_date.isoformat()}_{log.author_name}.pdf",
    )


def _pdf_response(pdf: bytes, ascii_name: str, filename: str) -> Response:
    return Response(
        content=pdf,
        media_type="application/pdf",
        headers={
            "Content-Disposition": f"attachment; filename=\"{ascii_name}\"; filename*=UTF-8''{quote(filename)}"
        },
    )


@router.patch("/{log_id}", response_model=WorkLogDetail)
def update_worklog(
    log_id: uuid.UUID,
    payload: WorkLogUpdate,
    db: DbSession,
    user: CurrentUser,
    client: Client,
) -> WorkLogDetail:
    log = _load(db, log_id)
    if not access.can_edit(log, user):
        raise AppError(
            "FORBIDDEN",
            "근무일지는 본인과 관리자만 고칠 수 있습니다.",
            status.HTTP_403_FORBIDDEN,
        )
    data = payload.model_dump(exclude_unset=True)
    _validate(db, user, data, existing=log)
    new_date = data.get("work_date", log.work_date)
    if (
        log.author_id is not None
        and new_date != log.work_date
        and _duplicate(db, log.author_id, new_date, exclude=log.id) is not None
    ):
        raise AppError(
            "WORKLOG_EXISTS",
            f"{new_date.isoformat()} 근무일지가 따로 있습니다. 일자를 확인하세요.",
            status.HTTP_409_CONFLICT,
        )
    before = {k: getattr(log, k) for k in data}
    for k, v in data.items():
        setattr(log, k, v)
    log.updated_by_id = user.id
    audit.record(
        db,
        action=AuditAction.UPDATE,
        actor=user,
        module=ModuleKey.WORKLOG,
        entity_type="worklog",
        entity_id=log.id,
        summary=f"근무일지 수정 {log.work_date} {log.author_name}",
        changes=audit.diff(before, data),
        client=client,
    )
    db.commit()
    return _detail(db, log, user)


@router.delete("/{log_id}", response_model=Message)
def delete_worklog(
    log_id: uuid.UUID, db: DbSession, user: CurrentUser, client: Client
) -> Message:
    log = _load(db, log_id)
    if not access.can_edit(log, user):
        raise AppError(
            "FORBIDDEN",
            "근무일지는 본인과 관리자만 지울 수 있습니다.",
            status.HTTP_403_FORBIDDEN,
        )
    log.deleted_at = now_utc()
    for a in db.scalars(
        select(Attachment).where(
            Attachment.entity_type == "worklog",
            Attachment.entity_id == log.id,
            Attachment.deleted_at.is_(None),
        )
    ).all():
        a.deleted_at = now_utc()
    audit.record(
        db,
        action=AuditAction.DELETE,
        actor=user,
        module=ModuleKey.WORKLOG,
        entity_type="worklog",
        entity_id=log.id,
        summary=f"근무일지 삭제 {log.work_date} {log.author_name}",
        client=client,
    )
    db.commit()
    return Message(message="근무일지를 삭제했습니다.")
