"""All persisted enums.

Stored as VARCHAR (native_enum=False at the column) rather than PostgreSQL ENUM
types: adding a value stays a code change instead of a migration + type ALTER.
"""
from __future__ import annotations

from enum import StrEnum


class Role(StrEnum):
    MEMBER = "MEMBER"        # 일반 사원
    MANAGER = "MANAGER"      # 팀장 - 소속 부서 데이터 관리
    ADMIN = "ADMIN"          # 관리자 - 승인/설정
    SUPERADMIN = "SUPERADMIN"  # 최고 관리자 - 시스템


ROLE_LEVEL: dict[str, int] = {
    Role.MEMBER: 1,
    Role.MANAGER: 2,
    Role.ADMIN: 3,
    Role.SUPERADMIN: 4,
}


class UserStatus(StrEnum):
    PENDING = "PENDING"      # 가입 신청 - 관리자 승인 대기
    APPROVED = "APPROVED"    # 승인됨 - 로그인 가능
    REJECTED = "REJECTED"    # 반려
    SUSPENDED = "SUSPENDED"  # 정지
    RESIGNED = "RESIGNED"    # 퇴사


class ModuleKey(StrEnum):
    SYSTEM = "SYSTEM"
    AUTH = "AUTH"
    SERVICE = "SERVICE"
    INVENTORY = "INVENTORY"
    BOARD = "BOARD"
    CALENDAR = "CALENDAR"
    STORE = "STORE"          # 매장 - 브랜드/폐점/납품 장비 세트
    WORKLOG = "WORKLOG"      # 근무일지 - 작성자·일자마다 한 장


# ---------------- Service (AS) ----------------
class ServiceStatus(StrEnum):
    RECEIVED = "RECEIVED"            # 접수
    ASSIGNED = "ASSIGNED"            # 배정
    IN_PROGRESS = "IN_PROGRESS"      # 진행중
    PENDING_PARTS = "PENDING_PARTS"  # 부품대기
    COMPLETED = "COMPLETED"          # 완료
    CANCELED = "CANCELED"            # 취소


OPEN_SERVICE_STATUSES = (
    ServiceStatus.RECEIVED,
    ServiceStatus.ASSIGNED,
    ServiceStatus.IN_PROGRESS,
    ServiceStatus.PENDING_PARTS,
)


class ServicePriority(StrEnum):
    LOW = "LOW"
    NORMAL = "NORMAL"
    HIGH = "HIGH"
    URGENT = "URGENT"


class ServiceChannel(StrEnum):
    PHONE = "PHONE"
    EMAIL = "EMAIL"
    VISIT = "VISIT"
    WEB = "WEB"
    INTERNAL = "INTERNAL"


# ---------------- Inventory ----------------
class AssetStatus(StrEnum):
    IN_STOCK = "IN_STOCK"    # 재고
    IN_USE = "IN_USE"        # 사용중
    REPAIR = "REPAIR"        # 수리중
    LOANED = "LOANED"        # 대여중
    DISPOSED = "DISPOSED"    # 폐기
    LOST = "LOST"            # 분실


class LocationType(StrEnum):
    SITE = "SITE"            # 사업장
    BUILDING = "BUILDING"    # 건물
    FLOOR = "FLOOR"          # 층
    ROOM = "ROOM"            # 실
    RACK = "RACK"            # 랙/선반
    VEHICLE = "VEHICLE"      # 차량
    ETC = "ETC"


class MovementType(StrEnum):
    INBOUND = "INBOUND"      # 입고
    MOVE = "MOVE"            # 위치 이동
    ASSIGN = "ASSIGN"        # 사용자 불출
    RETURN = "RETURN"        # 반납
    REPAIR = "REPAIR"        # 수리 반출
    DISPOSE = "DISPOSE"      # 폐기
    STOCKTAKE = "STOCKTAKE"  # 실사 조정


# ---------------- Board ----------------
class BoardType(StrEnum):
    NOTICE = "NOTICE"        # 공지
    FREE = "FREE"            # 자유
    QNA = "QNA"              # 질문
    ARCHIVE = "ARCHIVE"      # 자료실


class PostStatus(StrEnum):
    DRAFT = "DRAFT"
    PUBLISHED = "PUBLISHED"
    HIDDEN = "HIDDEN"


# ---------------- Calendar ----------------
class CalendarType(StrEnum):
    PERSONAL = "PERSONAL"
    DEPARTMENT = "DEPARTMENT"
    COMPANY = "COMPANY"


class EventStatus(StrEnum):
    SCHEDULED = "SCHEDULED"
    CANCELED = "CANCELED"
    DONE = "DONE"


class ParticipantResponse(StrEnum):
    PENDING = "PENDING"
    ACCEPTED = "ACCEPTED"
    DECLINED = "DECLINED"
    TENTATIVE = "TENTATIVE"


class ReminderMethod(StrEnum):
    INAPP = "INAPP"
    PUSH = "PUSH"
    EMAIL = "EMAIL"


# ---------------- Notification / Audit ----------------
class NotificationType(StrEnum):
    EVENT_REMINDER = "EVENT_REMINDER"
    EVENT_INVITED = "EVENT_INVITED"
    EVENT_UPDATED = "EVENT_UPDATED"
    EVENT_CANCELED = "EVENT_CANCELED"
    SERVICE_ASSIGNED = "SERVICE_ASSIGNED"
    BOARD_COMMENT = "BOARD_COMMENT"
    ACCOUNT_APPROVED = "ACCOUNT_APPROVED"
    ACCOUNT_REJECTED = "ACCOUNT_REJECTED"
    SYSTEM = "SYSTEM"


class AuditAction(StrEnum):
    CREATE = "CREATE"
    UPDATE = "UPDATE"
    DELETE = "DELETE"
    LOGIN = "LOGIN"
    LOGIN_FAILED = "LOGIN_FAILED"
    LOGOUT = "LOGOUT"
    APPROVE = "APPROVE"
    REJECT = "REJECT"
    SETTING_CHANGE = "SETTING_CHANGE"


class DevicePlatform(StrEnum):
    ANDROID = "ANDROID"
    WINDOWS = "WINDOWS"
    LINUX = "LINUX"
    WEB = "WEB"
    IOS = "IOS"


# ---------------- 근무일지 ----------------
class WorkLogVisibility(StrEnum):
    PRIVATE = "PRIVATE"      # 나와 관리자만
    TEAM = "TEAM"            # 로그인한 모두 (보기만)
