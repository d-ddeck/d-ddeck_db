"""First-run seeding.

Idempotent: every helper checks before inserting, so this runs safely on every
startup. It only creates the rows the app cannot function without - the super
admin, the classification lists each module's 설정창 edits, and one default
board/calendar/location.
"""
from __future__ import annotations

import logging

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.security import hash_password
from app.models.admin import CodeGroup, CodeItem, ModuleSetting
from app.models.board import Board
from app.models.calendar import Calendar
from app.models.enums import (
    BoardType,
    CalendarType,
    LocationType,
    ModuleKey,
    Role,
    UserStatus,
)
from app.models.inventory import Location
from app.models.user import User

log = logging.getLogger("ddeck.bootstrap")

# (group_code, group_name, module, [(item_code, item_name, color), ...])
DEFAULT_CODES: list[tuple[str, str, ModuleKey, list[tuple[str, str, str | None]]]] = [
    (
        "SERVICE_CATEGORY", "서비스 분류", ModuleKey.SERVICE,
        [
            ("INSTALL", "설치", "#3B82F6"),
            ("REPAIR", "수리", "#EF4444"),
            ("INSPECT", "정기점검", "#10B981"),
            ("REPLACE", "교체", "#F59E0B"),
            ("CONSULT", "상담", "#8B5CF6"),
            ("ETC", "기타", "#94A3B8"),
        ],
    ),
    (
        "SERVICE_SYMPTOM", "증상 분류", ModuleKey.SERVICE,
        [
            ("POWER", "전원 불량", None),
            ("NOISE", "소음", None),
            ("LEAK", "누수 / 누유", None),
            ("MALFUNCTION", "오작동", None),
            ("BROKEN", "파손", None),
            ("ETC", "기타", None),
        ],
    ),
    (
        "SERVICE_CAUSE", "원인 분류", ModuleKey.SERVICE,
        [
            ("WEAR", "부품 노후", None),
            ("USER", "사용자 과실", None),
            ("DEFECT", "제조 불량", None),
            ("INSTALL", "설치 불량", None),
            ("ENV", "환경 요인", None),
            ("UNKNOWN", "원인 미상", None),
        ],
    ),
    (
        "SERVICE_ACTION", "조치 분류", ModuleKey.SERVICE,
        [
            ("PART", "부품 교체", None),
            ("REINSTALL", "재설치", None),
            ("CLEAN", "청소 / 세척", None),
            ("FIRMWARE", "펌웨어 / SW 업데이트", None),
            ("ADJUST", "조정", None),
            ("RETURN", "회수 / 반품", None),
        ],
    ),
    (
        "ASSET_CATEGORY", "자산 분류", ModuleKey.INVENTORY,
        [
            ("IT", "IT 장비", "#3B82F6"),
            ("OFFICE", "사무기기", "#8B5CF6"),
            ("TOOL", "공구 / 계측기", "#F59E0B"),
            ("VEHICLE", "차량", "#10B981"),
            ("FURNITURE", "가구 / 비품", "#94A3B8"),
            ("PART", "AS 부품", "#EF4444"),
        ],
    ),
    (
        # 과실 - who the failure is attributable to. A separate axis from
        # SERVICE_CAUSE: "whose fault" and "what broke" are different answers.
        "SERVICE_FAULT", "과실 구분", ModuleKey.SERVICE,
        [
            ("SELF_COLLISION", "자체 충돌", "#EF4444"),
            ("SELF_MALFUNCTION", "자체 오동작", "#F97316"),
            ("DEFECT", "제품 불량", "#DC2626"),
            ("USER_COLLISION", "사용자 충돌", "#F59E0B"),
            ("USER_MISUSE", "사용자 오조작", "#FBBF24"),
            ("POOR_UPKEEP", "관리 미흡", "#A16207"),
            ("UNKNOWN", "미확인", "#94A3B8"),
            ("ETC", "기타", "#6B7280"),
        ],
    ),
    (
        # 대응인원 - deliberately a code list, not the user table. It holds
        # people who never had an account and entries that are not individuals
        # at all (CS팀, 레인보우CS팀). Where a responder does have an account,
        # the item carries its user id in `extra`. Seeded empty: who responds
        # is per-company.
        "SERVICE_RESPONDER", "대응인원", ModuleKey.SERVICE, [],
    ),
    (
        "SERVICE_RENTAL_TYPE", "렌탈 장비 종류", ModuleKey.SERVICE, [],
    ),
    (
        # 브랜드 - per-company, so no defaults.
        "STORE_BRAND", "매장 브랜드", ModuleKey.STORE, [],
    ),
    (
        "EVENT_CATEGORY", "일정 유형", ModuleKey.CALENDAR,
        [
            ("MEETING", "회의", "#3B82F6"),
            ("TRIP", "출장", "#F59E0B"),
            ("LEAVE", "휴가", "#10B981"),
            ("TRAINING", "교육", "#8B5CF6"),
            ("AS_VISIT", "AS 방문", "#EF4444"),
            ("ETC", "기타", "#94A3B8"),
        ],
    ),
]

# (module, key, value, value_type, label, is_public)
DEFAULT_SETTINGS: list[tuple[ModuleKey, str, object, str, str, bool]] = [
    (ModuleKey.SYSTEM, "company_name", "디덱", "string", "회사명", True),
    (ModuleKey.SYSTEM, "timezone", "Asia/Seoul", "string", "기본 시간대", True),
    (ModuleKey.SYSTEM, "maintenance_mode", False, "bool", "점검 모드", True),
    (ModuleKey.SYSTEM, "maintenance_message", "", "string", "점검 안내 문구", True),

    (ModuleKey.AUTH, "require_admin_approval", True, "bool", "가입 시 관리자 승인 필요", True),
    (ModuleKey.AUTH, "allowed_email_domains", [], "list", "허용 이메일 도메인 (비우면 전체 허용)", False),
    (ModuleKey.AUTH, "max_failed_logins", 5, "int", "로그인 실패 잠금 횟수", False),
    (ModuleKey.AUTH, "lockout_minutes", 15, "int", "잠금 유지 시간(분)", False),
    (ModuleKey.AUTH, "default_role", "MEMBER", "string", "승인 시 기본 권한", False),

    (ModuleKey.SERVICE, "ticket_prefix", "AS", "string", "접수번호 접두어", True),
    (ModuleKey.SERVICE, "default_due_days", 3, "int", "기본 처리 기한(일)", True),
    (ModuleKey.SERVICE, "require_result_note", True, "bool", "완료 시 처리내용 필수", True),
    (ModuleKey.SERVICE, "auto_deduct_parts", True, "bool", "부품 사용 시 재고 자동 차감", False),
    (ModuleKey.SERVICE, "notify_on_assign", True, "bool", "담당자 배정 시 알림", False),

    (ModuleKey.INVENTORY, "asset_no_prefix", "AST", "string", "자산번호 접두어", True),
    (ModuleKey.INVENTORY, "low_stock_alert", True, "bool", "안전재고 미만 경고", True),
    (ModuleKey.INVENTORY, "require_location", True, "bool", "등록 시 위치 필수", True),
    (ModuleKey.INVENTORY, "warranty_alert_days", 30, "int", "보증만료 경고 기준(일)", True),

    (ModuleKey.BOARD, "attachment_max_mb", 25, "int", "첨부파일 최대 크기(MB)", True),
    (ModuleKey.BOARD, "default_page_size", 20, "int", "기본 목록 개수", True),

    (ModuleKey.CALENDAR, "default_reminder_minutes", 30, "int", "기본 알림 시점(분 전)", True),
    (ModuleKey.CALENDAR, "week_starts_on", "MON", "string", "주 시작 요일", True),
    (ModuleKey.CALENDAR, "business_hours_start", "09:00", "string", "업무 시작", True),
    (ModuleKey.CALENDAR, "business_hours_end", "18:00", "string", "업무 종료", True),
    (ModuleKey.CALENDAR, "allow_personal_calendar", True, "bool", "개인 캘린더 허용", True),

    (ModuleKey.STORE, "default_gripper_type", "전동", "string", "기본 그리퍼 종류", True),
    (ModuleKey.STORE, "show_closed_stores", False, "bool", "폐점 매장 목록에 표시", True),
]

DEFAULT_BOARDS: list[tuple[str, str, BoardType, Role, int]] = [
    ("NOTICE", "공지사항", BoardType.NOTICE, Role.ADMIN, 1),
    ("FREE", "자유게시판", BoardType.FREE, Role.MEMBER, 2),
    ("QNA", "질문답변", BoardType.QNA, Role.MEMBER, 3),
    ("ARCHIVE", "자료실", BoardType.ARCHIVE, Role.MANAGER, 4),
]


def run(db: Session) -> None:
    _seed_superadmin(db)
    _seed_codes(db)
    _seed_settings(db)
    _seed_boards(db)
    _seed_calendar(db)
    _seed_location(db)
    db.commit()


def _seed_superadmin(db: Session) -> None:
    existing = db.scalar(
        select(func.count(User.id)).where(User.role == Role.SUPERADMIN)
    )
    if existing:
        return
    db.add(
        User(
            email=settings.FIRST_SUPERADMIN_EMAIL.lower(),
            password_hash=hash_password(settings.FIRST_SUPERADMIN_PASSWORD),
            full_name=settings.FIRST_SUPERADMIN_NAME,
            role=Role.SUPERADMIN,
            status=UserStatus.APPROVED,
            # Forces a password change on first login so the .env default cannot
            # survive into production unnoticed.
            must_change_password=True,
        )
    )
    log.warning(
        "Bootstrapped super admin %s - change this password immediately.",
        settings.FIRST_SUPERADMIN_EMAIL,
    )


def _seed_codes(db: Session) -> None:
    for group_code, group_name, module, items in DEFAULT_CODES:
        group = db.scalar(select(CodeGroup).where(CodeGroup.code == group_code))
        if group is None:
            group = CodeGroup(
                code=group_code, name=group_name, module=module, is_system=True
            )
            db.add(group)
            db.flush()
        for order, (code, name, color) in enumerate(items, start=1):
            exists = db.scalar(
                select(CodeItem.id).where(
                    CodeItem.group_id == group.id, CodeItem.code == code
                )
            )
            if exists is None:
                db.add(
                    CodeItem(
                        group_id=group.id,
                        code=code,
                        name=name,
                        color=color,
                        sort_order=order,
                    )
                )


def _seed_settings(db: Session) -> None:
    for module, key, value, vtype, label, is_public in DEFAULT_SETTINGS:
        exists = db.scalar(
            select(ModuleSetting.id).where(
                ModuleSetting.module == module, ModuleSetting.key == key
            )
        )
        if exists is None:
            db.add(
                ModuleSetting(
                    module=module,
                    key=key,
                    value=value,
                    value_type=vtype,
                    label=label,
                    is_public=is_public,
                )
            )


def _seed_boards(db: Session) -> None:
    for code, name, btype, write_role, order in DEFAULT_BOARDS:
        if db.scalar(select(Board.id).where(Board.code == code)) is None:
            db.add(
                Board(
                    code=code,
                    name=name,
                    type=btype,
                    write_role=write_role,
                    sort_order=order,
                    allow_secret=(btype == BoardType.QNA),
                    notify_on_post=(btype == BoardType.NOTICE),
                )
            )


def _seed_calendar(db: Session) -> None:
    exists = db.scalar(select(Calendar.id).where(Calendar.type == CalendarType.COMPANY))
    if exists is None:
        db.add(
            Calendar(
                name="전사 캘린더",
                type=CalendarType.COMPANY,
                color="#3B82F6",
                is_shared=True,
                description="회사 전체가 공유하는 기본 캘린더",
            )
        )


def _seed_location(db: Session) -> None:
    if db.scalar(select(Location.id).where(Location.code == "HQ")) is None:
        db.add(
            Location(
                code="HQ", name="본사", type=LocationType.SITE, path="본사", sort_order=1
            )
        )
