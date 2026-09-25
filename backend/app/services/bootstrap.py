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
        # 증상은 서비스 분류의 하위 선택지라 여기 두지 않고 DEFAULT_SYMPTOMS 로
        # 분류 아래에 심는다(_seed_default_symptoms).
        "SERVICE_SYMPTOM", "증상 분류", ModuleKey.SERVICE, [],
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
        # 구 서버 재고 장비 종류 5종을 앞에, 일반 자산 분류를 뒤에.
        "ASSET_CATEGORY", "자산 분류", ModuleKey.INVENTORY,
        [
            ("ROBOT_ARM", "로봇팔", "#2563EB"),
            ("CONTROL_BOX", "제어박스", "#7C3AED"),
            ("E_GRIPPER", "전동 그리퍼", "#059669"),
            ("NE_GRIPPER", "비전동 그리퍼", "#10B981"),
            ("TOOL_CHANGER", "툴체인저", "#F59E0B"),
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
        # 재고 세부 상태 13종 (구 서버). 규칙(매장 필수 / 매장 유지 / 매장 자동 비움)은
        # 항목 extra 에 들어가며 _seed_status_rules 가 채운다.
        "ASSET_STATUS", "자산 상태", ModuleKey.INVENTORY,
        [
            ("WAREHOUSE", "창고", "#64748B"), ("OFFICE", "사무실", "#94A3B8"),
            ("INSTALLED", "설치", "#2563EB"), ("RENTED", "렌탈 중", "#8B5CF6"),
            ("AS_WAIT", "AS 대기", "#F59E0B"), ("AS_OUT", "AS 반출", "#F97316"),
            ("RECOVER_BAREUN", "바른 회수", "#A16207"), ("RECOVER_JADAM", "자담 회수", "#A16207"),
            ("RECOVER_SAMSUNG", "삼성 회수", "#A16207"), ("RECOVER_OVERSEAS", "해외 회수", "#A16207"),
            ("RECOVER_ETC", "기타 회수", "#A16207"), ("DISPOSED", "폐기", "#6B7280"), ("UNKNOWN", "미상", "#EF4444"),
        ],
    ),
    ("ASSET_MODEL", "자산 모델", ModuleKey.INVENTORY, []),
    ("ASSET_MAKER", "자산 제조사", ModuleKey.INVENTORY, []),
    (
        # 브랜드 - per-company, so no defaults.
        "STORE_BRAND", "매장 브랜드", ModuleKey.STORE, [],
    ),
    (
        # 근무일지 직급 (구 서버 position 목록). 계정에 직급이 없을 때 고르는 칸.
        "WORKLOG_POSITION", "직급", ModuleKey.WORKLOG,
        [("STAFF", "사원", None), ("JUNIOR", "주임", None), ("ASSISTANT_MANAGER", "대리", None),
         ("MANAGER", "과장", None), ("DEPUTY_GM", "차장", None), ("GM", "부장", None),
         ("DIRECTOR", "이사", None), ("VICE_PRESIDENT", "부대표", None), ("PRESIDENT", "대표", None)],
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

# 종류 이름 -> 딸린 항목. (하위 코드군, [(code, name)])  구 서버 ASSET_MODELS / ASSET_MAKERS.
DEFAULT_CHILD_CODES: dict[str, dict[str, list[tuple[str, str]]]] = {
    "로봇팔": {"ASSET_MODEL": [("RB5_850EN", "RB5-850EN")], "ASSET_MAKER": [("RAINBOW", "레인보우로보틱스")]},
    "제어박스": {"ASSET_MODEL": [("CB_04", "CB-04"), ("CB_06", "CB-06")], "ASSET_MAKER": [("RAINBOW", "레인보우로보틱스")]},
    "전동 그리퍼": {"ASSET_MODEL": [("2FG7", "2FG7")], "ASSET_MAKER": [("ONROBOT", "OnRobot")]},
    "툴체인저": {"ASSET_MODEL": [("QC_RSV3", "QC-RSv3")]},
}

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
    # 구 서버(CS_Record) 대응 기록 규칙
    (ModuleKey.SERVICE, "require_category", True, "bool", "서비스구분 1 필수", True),
    (ModuleKey.SERVICE, "max_causes", 10, "int", "한 건에 넣을 수 있는 서비스구분 수", True),
    (ModuleKey.SERVICE, "maker_required_categories", ["로봇팔", "제어박스", "전동 그리퍼"], "list",
     "제조사를 반드시 고르는 서비스구분", True),
    (ModuleKey.SERVICE, "rental_serial_must_exist", True, "bool", "렌탈 시리얼은 재고 S/N 만", True),
    (ModuleKey.SERVICE, "require_responder_on_complete", True, "bool", "종결 시 대응인원 필수", True),

    (ModuleKey.INVENTORY, "asset_no_prefix", "AST", "string", "자산번호 접두어", True),
    (ModuleKey.INVENTORY, "low_stock_alert", True, "bool", "안전재고 미만 경고", True),
    (ModuleKey.INVENTORY, "require_location", True, "bool", "등록 시 위치 필수", True),
    (ModuleKey.INVENTORY, "warranty_alert_days", 30, "int", "보증만료 경고 기준(일)", True),
    (ModuleKey.INVENTORY, "maker_required_categories", ["로봇팔", "제어박스", "전동 그리퍼"], "list",
     "제조사를 반드시 적는 장비 종류", True),
    (ModuleKey.INVENTORY, "nonelectric_serial_prefix", "NG-", "string", "비전동 그리퍼 관리 번호 접두어", True),

    (ModuleKey.BOARD, "attachment_max_mb", 25, "int", "첨부파일 최대 크기(MB)", True),
    (ModuleKey.BOARD, "default_page_size", 20, "int", "기본 목록 개수", True),

    (ModuleKey.CALENDAR, "default_reminder_minutes", 30, "int", "기본 알림 시점(분 전)", True),
    (ModuleKey.CALENDAR, "week_starts_on", "MON", "string", "주 시작 요일", True),
    (ModuleKey.CALENDAR, "business_hours_start", "09:00", "string", "업무 시작", True),
    (ModuleKey.CALENDAR, "business_hours_end", "18:00", "string", "업무 종료", True),
    (ModuleKey.CALENDAR, "allow_personal_calendar", True, "bool", "개인 캘린더 허용", True),
    (ModuleKey.CALENDAR, "extra_holidays", "", "string",
     "추가 휴일 (05-01:노동절, 2028-04-12:선거 처럼 쉼표로)", True),

    (ModuleKey.STORE, "default_gripper_type", "전동", "string", "기본 그리퍼 종류", True),
    (ModuleKey.STORE, "show_closed_stores", False, "bool", "폐점 매장 목록에 표시", True),
    (ModuleKey.STORE, "equipment_requires_known_serial", True, "bool", "매장 장비 설정은 재고에 있는 S/N 만", True),

    (ModuleKey.WORKLOG, "default_work_start", "09:00", "string", "근무 시작 기본값", True),
    (ModuleKey.WORKLOG, "default_work_end", "18:00", "string", "근무 종료 기본값", True),
    (ModuleKey.WORKLOG, "autosave_seconds", 5, "int", "입력 멈춘 뒤 임시 저장까지(초)", True),
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
    _seed_default_symptoms(db)
    _seed_settings(db)
    _seed_boards(db)
    _seed_calendar(db)
    _seed_location(db)
    _seed_child_codes(db)
    _seed_status_rules(db)
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


# 서비스 분류(코드) → 기본 증상. 증상 그룹이 비어 있는 새 저장소에만 심는다.
# 코드는 '<분류코드>_<증상코드>' 로 그룹 안에서 유일하게 만든다.
DEFAULT_SYMPTOMS: dict[str, list[tuple[str, str]]] = {
    "REPAIR": [
        ("POWER", "전원 불량"), ("NOISE", "소음"), ("LEAK", "누수 / 누유"),
        ("MALFUNCTION", "오작동"), ("BROKEN", "파손"), ("ETC", "기타"),
    ],
    "INSTALL": [("NEW", "신규 설치"), ("MOVE", "이전 설치"), ("ETC", "기타")],
    "INSPECT": [("REGULAR", "정기 점검"), ("REQUEST", "요청 점검"), ("ETC", "기타")],
    "REPLACE": [("PART", "부품 교체"), ("UNIT", "본체 교체"), ("ETC", "기타")],
    "CONSULT": [("USAGE", "사용법 문의"), ("ETC", "기타")],
    "ETC": [("ETC", "기타")],
}


def _seed_default_symptoms(db: Session) -> None:
    db.flush()
    group = _group(db, "SERVICE_SYMPTOM")
    cat_group = _group(db, "SERVICE_CATEGORY")
    if group is None or cat_group is None:
        return
    if db.scalar(select(CodeItem.id).where(CodeItem.group_id == group.id)) is not None:
        return  # 이미 쓰는 저장소: 회사 증상 목록을 건드리지 않는다
    order = 0
    for cat_code, items in DEFAULT_SYMPTOMS.items():
        parent = db.scalar(
            select(CodeItem).where(CodeItem.group_id == cat_group.id, CodeItem.code == cat_code)
        )
        if parent is None:
            continue
        for code, name in items:
            order += 1
            db.add(
                CodeItem(
                    group_id=group.id, parent_id=parent.id,
                    code=f"{cat_code}_{code}", name=name, sort_order=order,
                )
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
                    CodeItem.group_id == group.id,
                    (CodeItem.code == code) | (CodeItem.name == name),
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
    hq = db.scalar(select(Location).where(Location.code == "HQ"))
    if hq is None:
        hq = Location(code="HQ", name="본사", type=LocationType.SITE, path="본사", sort_order=1)
        db.add(hq)
        db.flush()
    # 구 서버의 보관 장소. 재고 상태 '창고' · '사무실' 규칙이 이 이름의 위치로 보낸다.
    for order, (code, name, ltype) in enumerate(
        [("WAREHOUSE", "창고", LocationType.ROOM), ("OFFICE", "사무실", LocationType.ROOM)], start=2
    ):
        exists = db.scalar(
            select(Location.id).where(Location.name == name, Location.deleted_at.is_(None))
        )
        if exists is None and db.scalar(select(Location.id).where(Location.code == code)) is None:
            db.add(
                Location(
                    code=code, name=name, type=ltype, parent_id=hq.id,
                    path=f"{hq.name} > {name}", sort_order=order,
                )
            )


def _group(db: Session, code: str) -> CodeGroup | None:
    return db.scalar(select(CodeGroup).where(CodeGroup.code == code))


def _seed_child_codes(db: Session) -> None:
    """종류(ASSET_CATEGORY)에 딸린 기본 품명 · 제조사. 이름이 있으면 건너뛴다."""
    cat_group = _group(db, "ASSET_CATEGORY")
    if cat_group is None:
        return
    for kind_name, groups in DEFAULT_CHILD_CODES.items():
        parent = db.scalar(
            select(CodeItem).where(CodeItem.group_id == cat_group.id, CodeItem.name == kind_name)
        )
        if parent is None:
            continue
        for group_code, items in groups.items():
            group = _group(db, group_code)
            if group is None:
                continue
            for order, (code, name) in enumerate(items, start=1):
                exists = db.scalar(
                    select(CodeItem.id).where(
                        CodeItem.group_id == group.id,
                        CodeItem.parent_id == parent.id,
                        CodeItem.name == name,
                    )
                )
                if exists is None:
                    db.add(
                        CodeItem(
                            group_id=group.id,
                            parent_id=parent.id,
                            code=f"{parent.code}_{code}"[:60],
                            name=name,
                            sort_order=order,
                        )
                    )


def _seed_status_rules(db: Session) -> None:
    """ASSET_STATUS 항목 extra 에 규칙(store / as / clear / free + enum)을 채운다.

    이관된 저장소의 항목은 extra 가 비어 있다. 이름으로 한 번 채워 두면 이후 이름을
    바꿔도 규칙이 따라간다 (app/services/asset_rules.py 참고).
    """
    from app.services import asset_rules

    group = _group(db, asset_rules.STATUS_GROUP)
    if group is None:
        return
    for item in db.scalars(select(CodeItem).where(CodeItem.group_id == group.id)).all():
        extra = item.extra if isinstance(item.extra, dict) else {}
        if extra.get("rule") in ("store", "as", "clear", "free"):
            continue
        rule = asset_rules.rule_by_name(item.name)
        item.extra = {**extra, **rule.as_extra()}
