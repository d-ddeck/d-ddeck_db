"""구 서버(CS_Record v1.58.1)의 자료를 이 서버로 옮긴다.

    python scripts/migrate_from_legacy.py --source ../beforeserver --dry-run
    python scripts/migrate_from_legacy.py --source ../beforeserver

--source 는 구 서버의 백업 폴더다(안에 cs.db 와 uploads/ docs/ 가 있는 형태).

멱등하다. 같은 폴더로 두 번 돌려도 행이 두 벌 생기지 않는다. 각 종류마다
자연키로 먼저 찾아보고 없을 때만 만든다:

    사용자       이메일            매장     매장명(구 시스템에서 UNIQUE)
    분류 코드    (코드군, 코드)     자산     (분류, S/N) - 구 UNIQUE(kind, serial)
    대응 기록    legacy_no         게시글   (게시판, 제목)

옮기지 않는 것 (1차 범위 밖):
  * equipment 83행 - 구 시스템에서도 읽는 곳이 한 줄뿐인 죽은 표.

비밀번호는 넘어오지 않는다. 구 서버는 werkzeug scrypt, 이쪽은 bcrypt 라 해시를
재사용할 수 없다. 새로 만든 계정은 --password 값(기본 ddeck1234)으로 열리고
must_change_password=True 가 붙는다.
"""

from __future__ import annotations

import argparse
import hashlib
import mimetypes
import shutil
import sqlite3
import sys
import uuid
from contextlib import closing
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.database import SessionLocal, engine
from app.core.security import hash_password
from app.models import Base
from app.models.admin import Attachment, CodeGroup, CodeItem
from app.models.board import Board, Post
from app.models.calendar import Calendar, Event, EventParticipant
from app.models.enums import (
    AssetStatus,
    BoardType,
    CalendarType,
    EventStatus,
    LocationType,
    ParticipantResponse,
    Role,
    ServiceChannel,
    ServicePriority,
    ServiceStatus,
    UserStatus,
    WorkLogVisibility,
)
from app.models.inventory import Asset, Location
from app.models.service import (
    ServiceTicket,
    ServiceTicketCause,
    ServiceTicketResponder,
)
from app.models.store import Store, StoreSet
from app.models.user import User
from app.models.worklog import WorkLog
from app.services import bootstrap

# 구 서버는 우분투 데스크톱의 로컬 시각(KST)을 그대로 문자열로 넣었다.
# 이 서버는 전부 UTC aware 라 옮기면서 9시간을 뺀다.
KST = timezone(timedelta(hours=9))

# 날짜만 있는 칸(발생일 등)에는 시각이 없다. 업무 시작 시각으로 고정해
# 날짜가 시간대 변환 때문에 하루 밀리는 일을 막는다.
ASSUMED_HOUR = 9

# 구 상태 13종 -> 이쪽 enum 6종. 원본은 Asset.status_item_id 에 그대로 남으므로
# 여기서 잃는 것은 없고, 재고 화면이 쓰는 굵은 구분만 정한다.
ASSET_STATUS_MAP = {
    "창고": AssetStatus.IN_STOCK,
    "사무실": AssetStatus.IN_STOCK,
    "설치": AssetStatus.IN_USE,
    "렌탈 중": AssetStatus.LOANED,
    "AS 대기": AssetStatus.REPAIR,
    "AS 반출": AssetStatus.REPAIR,
    "바른 회수": AssetStatus.IN_STOCK,
    "자담 회수": AssetStatus.IN_STOCK,
    "삼성 회수": AssetStatus.IN_STOCK,
    "해외 회수": AssetStatus.IN_STOCK,
    "기타 회수": AssetStatus.IN_STOCK,
    "폐기": AssetStatus.DISPOSED,
    # 소재가 확인되지 않은 28대. 재고로 세면 보유 수량이 부풀고, 폐기로 두면
    # 되돌릴 수 없다. LOST 가 "확인 필요"에 가장 가깝다.
    "미상": AssetStatus.LOST,
}

# 구 lists.kind -> 이 서버의 코드군
LIST_GROUPS = {
    "brand": "STORE_BRAND",
    "category": "SERVICE_CATEGORY",
    "fault": "SERVICE_FAULT",
    "responder": "SERVICE_RESPONDER",
    "rental_type": "SERVICE_RENTAL_TYPE",
    "asset_kind": "ASSET_CATEGORY",
    "asset_model": "ASSET_MODEL",
    "asset_maker": "ASSET_MAKER",
    "asset_status": "ASSET_STATUS",
}

# 위 표에 없는 kind 를 왜 안 옮기는지:
#   detail       -> SERVICE_SYMPTOM(증상). 구분과 세부를 한 표에 담던 것을
#                   이 서버의 두 축으로 나눈다(아래 migrate_codes)
#   asset_place  -> 코드가 아니라 실제 위치다. Location 행으로 만든다.
#   position     -> User.position 이 자유 문자열이라 마스터가 필요 없다.
#   doc_category -> 게시판 탭이었다. Board 행으로 만든다.

GROUP_META = {
    "ASSET_MODEL": ("자산 모델", "INVENTORY"),
    "ASSET_MAKER": ("자산 제조사", "INVENTORY"),
    "ASSET_STATUS": ("자산 상태(구 서버)", "INVENTORY"),
}


class Stats:
    def __init__(self) -> None:
        self.rows: list[tuple[str, int, int]] = []

    def add(self, label: str, created: int, reused: int) -> None:
        self.rows.append((label, created, reused))

    def report(self) -> None:
        print()
        print("=" * 58)
        print(f"  {'항목':<22}{'새로 만듦':>10}{'이미 있음':>10}")
        print("-" * 58)
        for label, created, reused in self.rows:
            print(f"  {label:<22}{created:>10}{reused:>10}")
        print("=" * 58)


# --------------------------------------------------------------- 값 변환


def to_utc(text: str | None) -> datetime | None:
    """'2026-09-18 13:56:03' (KST) -> UTC aware datetime."""
    if not text:
        return None
    text = text.strip()
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            naive = datetime.strptime(text, fmt)  # noqa: DTZ007 - legacy values are interpreted as KST below
        except ValueError:
            continue
        if fmt == "%Y-%m-%d":
            naive = naive.replace(hour=ASSUMED_HOUR)
        return naive.replace(tzinfo=KST).astimezone(timezone.utc)
    return None


def to_date(text: str | None) -> date | None:
    if not text:
        return None
    try:
        return datetime.strptime(text.strip(), "%Y-%m-%d").date()  # noqa: DTZ007 - legacy values are interpreted as KST below
    except ValueError:
        return None


def code_for(value: str) -> str:
    """구 마스터에는 코드가 없고 한글 이름뿐이다. 이름에서 안정적인 코드를 만든다.

    실행할 때마다 같은 값이 나와야 재실행이 멱등해진다.
    """
    return "L" + hashlib.sha1(value.encode("utf-8")).hexdigest()[:10].upper()


def first_line(text: str | None, limit: int = 250) -> str:
    """접수 내용 첫 줄을 제목으로 쓴다. 구 시스템에는 제목 칸이 없었다."""
    if not text:
        return ""
    for raw in text.replace("\r", "\n").split("\n"):
        line = raw.strip()
        if line:
            return line[:limit]
    return ""


def split_multi(text: str | None) -> list[str]:
    """'원정훈, 임경호, 이재우' -> 세 개. 구 시스템의 쉼표 다중 저장 규칙."""
    if not text:
        return []
    return [p.strip() for p in text.split(",") if p.strip()]


# --------------------------------------------------------------- 각 단계


def migrate_users(
    db: Session, src: sqlite3.Connection, st: Stats, password: str
) -> dict[str, User]:
    """구 계정 5명. 로그인 아이디가 한글이라 <아이디>@ddeck.local 로 만든다."""
    created = reused = 0
    by_name: dict[str, User] = {}
    for row in src.execute("SELECT login, name, role, position, active FROM users"):
        login, name, role, position, active = row
        # 구 'admin' 은 이 서버의 부트스트랩 최고관리자와 같은 자리다.
        email = "admin@ddeck.local" if login == "admin" else f"{login}@ddeck.local"
        # 그래서 SUPERADMIN 으로 옮긴다. ADMIN 으로 두면 부트스트랩이
        # "최고관리자가 하나도 없다"고 보고 같은 이메일을 다시 만들려다
        # users.email UNIQUE 에 걸려 서버가 뜨지 않는다.
        if login == "admin":
            new_role = Role.SUPERADMIN
        elif role == "admin":
            new_role = Role.ADMIN
        else:
            new_role = Role.MEMBER
        user = db.scalar(select(User).where(User.email == email))
        if user is None:
            user = User(
                email=email,
                password_hash=hash_password(password),
                full_name=name,
                position=position or None,
                role=new_role,
                status=UserStatus.APPROVED if active else UserStatus.SUSPENDED,
                must_change_password=True,
            )
            db.add(user)
            db.flush()
            created += 1
        else:
            reused += 1
        by_name[name] = user
        by_name[login] = user
    st.add("사용자", created, reused)
    return by_name


def _group(db: Session, code: str) -> CodeGroup | None:
    return db.scalar(select(CodeGroup).where(CodeGroup.code == code))


def _ensure_group(db: Session, code: str) -> CodeGroup:
    group = _group(db, code)
    if group is not None:
        return group
    name, module = GROUP_META.get(code, (code, "SYSTEM"))
    group = CodeGroup(code=code, name=name, module=module, is_system=True)
    db.add(group)
    db.flush()
    return group


def _ensure_item(
    db: Session,
    group: CodeGroup,
    value: str,
    *,
    parent: CodeItem | None = None,
    sort: int = 0,
    active: bool = True,
) -> tuple[CodeItem, bool]:
    """같은 상위 아래 이름이 같은 항목이 이미 있으면 그것을 쓴다(부트스트랩 기본값과 겹칠 때).

    상위까지 봐야 한다: '로봇팔 > 엔코더'와 '전동 그리퍼 > 엔코더'는 다른 항목이다.
    (2026-09-25 이전에는 이름만 봐서 합쳐졌고, scripts/fix_legacy_symptoms.py 로 되돌렸다.)
    """
    existing = db.scalar(
        select(CodeItem).where(
            CodeItem.group_id == group.id,
            CodeItem.name == value,
            CodeItem.parent_id == (parent.id if parent else None),
        )
    )
    if existing is not None:
        return existing, False
    item = CodeItem(
        group_id=group.id,
        parent_id=parent.id if parent else None,
        code=code_for(value if parent is None else f"{parent.name}>{value}"),
        name=value,
        sort_order=sort,
        is_active=active,
    )
    db.add(item)
    db.flush()
    return item, True


def migrate_codes(
    db: Session, src: sqlite3.Connection, st: Stats, users: dict[str, User]
) -> dict[tuple[str, str], CodeItem]:
    """구 lists 178행 -> 코드군/항목. 반환값은 (kind, 값) -> CodeItem."""
    created = reused = 0
    index: dict[tuple[str, str], CodeItem] = {}

    rows = list(
        src.execute(
            "SELECT kind, value, parent, sort, active FROM lists ORDER BY kind, sort, rowid"
        )
    )

    # 1) 부모가 없는 평범한 마스터
    for kind, value, parent, sort, active in rows:
        group_code = LIST_GROUPS.get(kind)
        if group_code is None or kind == "detail":
            continue
        group = _ensure_group(db, group_code)
        parent_item = None
        if kind in ("asset_model", "asset_maker") and parent:
            parent_item = index.get(("asset_kind", parent))
        item, is_new = _ensure_item(
            db, group, value, parent=parent_item, sort=sort, active=bool(active)
        )
        index[(kind, value)] = item
        created += is_new
        reused += not is_new

    # 2) 세부분류 -> 증상(SERVICE_SYMPTOM).
    #    구 시스템은 서비스구분과 세부분류를 lists 한 표에 같이 담고
    #    '제어박스 > 파워 케이블' 한 문자열로 저장했다. 이 서버는 두 축이
    #    따로 있으므로 구분은 SERVICE_CATEGORY, 세부는 SERVICE_SYMPTOM 으로
    #    나눠 넣는다. 둘의 관계는 parent_id 로 남겨 '어느 구분의 증상인지'를
    #    잃지 않는다.
    detail_group = _ensure_group(db, "SERVICE_SYMPTOM")
    for kind, value, parent, sort, active in rows:
        if kind != "detail":
            continue
        leaf = value.split(" > ", 1)[-1].strip()
        parent_item = index.get(("category", parent))
        item, is_new = _ensure_item(
            db, detail_group, leaf, parent=parent_item, sort=sort, active=bool(active)
        )
        # 원래 문자열 그대로도 찾을 수 있게 둘 다 등록해 둔다.
        index[("detail", value)] = item
        created += is_new
        reused += not is_new

    # 3) 계정이 있는 대응인원은 코드 항목에 user_id 를 달아 둔다.
    #    나중에 "담당자별" 화면을 붙일 때 연결 고리가 된다.
    for (kind, value), item in index.items():
        if kind == "responder" and value in users and not item.extra:
            item.extra = {"user_id": str(users[value].id)}

    st.add("분류 코드", created, reused)
    return index


def migrate_stores(
    db: Session,
    src: sqlite3.Connection,
    st: Stats,
    codes: dict[tuple[str, str], CodeItem],
) -> dict[str, Store]:
    created = reused = 0
    by_name: dict[str, Store] = {}
    for row in src.execute(
        "SELECT name, brand, open_date, closed, closed_date, note, gripper_type FROM stores"
    ):
        name, brand, open_date, closed, closed_date, note, gripper = row
        store = db.scalar(select(Store).where(Store.name == name))
        if store is None:
            brand_item = codes.get(("brand", brand))
            store = Store(
                name=name,
                brand_id=brand_item.id if brand_item else None,
                open_date=to_date(open_date),
                is_closed=bool(closed),
                closed_date=to_date(closed_date),
                gripper_type=gripper or None,
                note=note or None,
            )
            db.add(store)
            db.flush()
            created += 1
        else:
            reused += 1
        by_name[name] = store
    st.add("매장", created, reused)

    sets_created = sets_reused = 0
    for store_name, set_no, set_name in src.execute(
        "SELECT store, set_no, name FROM store_sets ORDER BY store, set_no"
    ):
        store = by_name.get(store_name)
        if store is None:
            continue
        existing = db.scalar(
            select(StoreSet).where(
                StoreSet.store_id == store.id, StoreSet.set_no == set_no
            )
        )
        if existing is None:
            db.add(StoreSet(store_id=store.id, set_no=set_no, name=set_name or None))
            sets_created += 1
        else:
            sets_reused += 1
    st.add("장비 세트", sets_created, sets_reused)
    return by_name


def migrate_places(
    db: Session, src: sqlite3.Connection, st: Stats
) -> dict[str, Location]:
    """구 asset_place('창고','사무실') -> 자사 위치 행.

    매장과 달리 이것들은 우리 건물 안이라 Location 트리가 맞는 자리다.
    """
    created = reused = 0
    by_name: dict[str, Location] = {}
    values = [
        r[0]
        for r in src.execute(
            "SELECT value FROM lists WHERE kind='asset_place' ORDER BY sort"
        )
    ]
    # 자산 쪽에 목록에 없는 위치 문자열이 있을 수 있어 같이 긁는다.
    for (extra,) in src.execute("SELECT DISTINCT place FROM assets WHERE place<>''"):
        if extra not in values:
            values.append(extra)
    for idx, value in enumerate(values, 1):
        loc = db.scalar(
            select(Location).where(
                Location.name == value, Location.deleted_at.is_(None)
            )
        )
        if loc is None:
            loc = Location(
                code=code_for(f"place:{value}"),
                name=value,
                type=LocationType.ETC,
                path=value,
                sort_order=idx,
            )
            db.add(loc)
            db.flush()
            created += 1
        else:
            reused += 1
        by_name[value] = loc
    st.add("위치", created, reused)
    return by_name


def migrate_assets(
    db: Session,
    src: sqlite3.Connection,
    st: Stats,
    codes: dict[tuple[str, str], CodeItem],
    stores: dict[str, Store],
    places: dict[str, Location],
) -> dict[tuple[str, str], Asset]:
    created = reused = 0
    index: dict[tuple[str, str], Asset] = {}
    for row in src.execute(
        "SELECT id, kind, model, serial, status, place, store, brand, install_date,"
        " note, set_no, maker FROM assets ORDER BY id"
    ):
        (
            legacy_id,
            kind,
            model,
            serial,
            status,
            place,
            store_name,
            _brand,
            install_date,
            note,
            set_no,
            maker,
        ) = row
        category = codes.get(("asset_kind", kind))
        key = (kind, serial)

        asset = db.scalar(
            select(Asset).where(
                Asset.serial_no == serial,
                Asset.category_id == (category.id if category else None),
                Asset.deleted_at.is_(None),
            )
        )
        if asset is None:
            # 구 시스템은 store 칸에 '창고' 같은 위치를 넣어 둔 행이 있다.
            # 매장 목록에 없으면 매장이 아니라 위치로 본다.
            store = stores.get(store_name or "")
            location = places.get(place or "") or (
                None if store else places.get(store_name or "")
            )
            asset = Asset(
                asset_no=f"AST-L-{legacy_id:05d}",
                name=f"{kind} {model}".strip() or kind,
                category_id=category.id if category else None,
                model_name=model or None,
                manufacturer=maker or None,
                serial_no=serial,
                status=ASSET_STATUS_MAP.get(status, AssetStatus.IN_STOCK),
                status_item_id=(
                    codes.get(("asset_status", status)).id
                    if codes.get(("asset_status", status))
                    else None
                ),
                location_id=location.id if location else None,
                store_id=store.id if store else None,
                set_no=set_no or 0,
                purchase_date=to_date(install_date),
                note=note or None,
            )
            db.add(asset)
            db.flush()
            created += 1
        else:
            reused += 1
        index[key] = asset
    st.add("자산", created, reused)
    return index


def deactivate_unused_categories(db: Session, st: Stats) -> None:
    """자산이 하나도 없는 기본 자산 분류를 '사용 안 함'으로 내린다.

    부트스트랩은 어느 회사나 쓸 만한 분류(IT 장비 / 사무기기 / 차량 ...)를
    깔아 두는데, 이 회사의 재고는 로봇팔·제어박스·그리퍼·툴체인저다. 섞어
    두면 등록 화면의 분류 목록이 쓰지 않는 항목 반이다. 지우지 않고 내리기만
    하므로 관리 화면에서 언제든 되돌릴 수 있다.
    """
    group = _group(db, "ASSET_CATEGORY")
    if group is None:
        return
    turned_off = 0
    for item in db.scalars(
        select(CodeItem).where(
            CodeItem.group_id == group.id, CodeItem.is_active.is_(True)
        )
    ):
        used = db.scalar(
            select(func.count(Asset.id)).where(
                Asset.category_id == item.id, Asset.deleted_at.is_(None)
            )
        )
        if not used:
            item.is_active = False
            turned_off += 1
    st.add("  미사용 분류 내림", turned_off, 0)


def migrate_tickets(
    db: Session,
    src: sqlite3.Connection,
    st: Stats,
    codes: dict[tuple[str, str], CodeItem],
    stores: dict[str, Store],
    users: dict[str, User],
) -> dict[int, ServiceTicket]:
    created = reused = 0
    cause_rows = responder_rows = 0
    index: dict[int, ServiceTicket] = {}

    causes_by_no: dict[int, list[tuple]] = {}
    for rec_no, seq, category, detail, maker in src.execute(
        "SELECT record_no, seq, category, detail, maker FROM record_causes ORDER BY record_no, seq"
    ):
        causes_by_no.setdefault(rec_no, []).append((seq, category, detail, maker))

    for row in src.execute(
        "SELECT no, brand, store, fault, occur_date, occur_content, response_date,"
        " response_content, responders, rental, rental_type, serial, due_date,"
        " return_date, returned, created_at, updated_at, created_by, closed"
        " FROM records ORDER BY no"
    ):
        (
            no,
            _brand,
            store_name,
            fault,
            occur_date,
            occur_content,
            response_date,
            response_content,
            responders,
            rental,
            rental_type,
            serial,
            due_date,
            return_date,
            returned,
            created_at,
            updated_at,
            created_by,
            closed,
        ) = row

        ticket = db.scalar(select(ServiceTicket).where(ServiceTicket.legacy_no == no))
        if ticket is not None:
            index[no] = ticket
            reused += 1
            continue

        store = stores.get(store_name or "")
        received = (
            to_utc(occur_date) or to_utc(created_at) or datetime.now(timezone.utc)
        )
        completed = to_utc(response_date) if closed == "O" else None
        my_causes = causes_by_no.get(no, [])
        head = my_causes[0] if my_causes else None

        ticket = ServiceTicket(
            ticket_no=str(no),  # 팀이 부르던 번호를 그대로 둔다
            legacy_no=no,
            title=first_line(occur_content) or (store_name or f"대응 {no}"),
            store_id=store.id if store else None,
            customer_name=store_name or None,
            serial_no=(split_multi(serial) or [None])[0],
            category_id=(
                codes.get(("category", head[1])).id
                if head and codes.get(("category", head[1]))
                else None
            ),
            symptom_id=(
                codes.get(("detail", head[2])).id
                if head and head[2] and codes.get(("detail", head[2]))
                else None
            ),
            fault_id=(
                codes.get(("fault", fault)).id if codes.get(("fault", fault)) else None
            ),
            status=ServiceStatus.COMPLETED if closed == "O" else ServiceStatus.RECEIVED,
            priority=ServicePriority.NORMAL,
            channel=ServiceChannel.INTERNAL,
            assignee_id=(
                users[split_multi(responders)[0]].id
                if split_multi(responders) and split_multi(responders)[0] in users
                else None
            ),
            received_at=received,
            completed_at=completed,
            is_rental=(rental == "O"),
            rental_type_id=(
                codes.get(("rental_type", rental_type)).id
                if codes.get(("rental_type", rental_type))
                else None
            ),
            rental_serials=serial or None,
            rental_due_date=to_date(due_date),
            rental_returned=(returned == "O"),
            rental_return_date=to_date(return_date),
            description=occur_content or None,
            result_note=response_content or None,
        )
        db.add(ticket)
        db.flush()

        # 구 시스템의 updated_at/created_at 을 그대로 얹는다. TimestampMixin 의
        # 기본값이 "오늘"이라 두면 전 건이 이관일에 몰려 추이 차트가 망가진다.
        ticket.created_at = to_utc(created_at) or received
        ticket.updated_at = to_utc(updated_at) or ticket.created_at
        if created_by in users:
            ticket.created_by_id = users[created_by].id

        for seq, category, detail, maker in my_causes:
            db.add(
                ServiceTicketCause(
                    ticket_id=ticket.id,
                    seq=seq,
                    category_id=(
                        codes.get(("category", category)).id
                        if codes.get(("category", category))
                        else None
                    ),
                    symptom_id=(
                        codes.get(("detail", detail)).id
                        if detail and codes.get(("detail", detail))
                        else None
                    ),
                    maker_id=(
                        codes.get(("asset_maker", maker)).id
                        if maker and codes.get(("asset_maker", maker))
                        else None
                    ),
                )
            )
            cause_rows += 1

        for seq, name in enumerate(split_multi(responders), 1):
            item = codes.get(("responder", name))
            db.add(
                ServiceTicketResponder(
                    ticket_id=ticket.id,
                    seq=seq,
                    responder_id=item.id if item else None,
                )
            )
            responder_rows += 1

        index[no] = ticket
        created += 1

    st.add("대응 기록", created, reused)
    st.add("  분류(다중)", cause_rows, 0)
    st.add("  대응인원", responder_rows, 0)
    return index


def migrate_board(
    db: Session, src: sqlite3.Connection, st: Stats, users: dict[str, User]
) -> dict[int, Post]:
    """구 게시판(docs). 분류 탭은 이 서버에서 게시판 하나에 대응한다."""
    created = reused = 0
    boards: dict[str, Board] = {}
    index: dict[int, Post] = {}

    for row in src.execute(
        "SELECT id, title, category, note, created_at, created_by FROM docs ORDER BY id"
    ):
        doc_id, title, category, note, created_at, created_by = row
        category = category or "기타"
        board = boards.get(category)
        if board is None:
            code = (
                "NOTICE" if category == "공지사항" else f"LEGACY_{code_for(category)}"
            )
            board = db.scalar(select(Board).where(Board.code == code))
            if board is None:
                board = Board(
                    code=code,
                    name=category,
                    type=BoardType.NOTICE
                    if category == "공지사항"
                    else BoardType.ARCHIVE,
                    description="구 서버 자료실에서 옮겨온 분류",
                    sort_order=50,
                )
                db.add(board)
                db.flush()
            boards[category] = board

        post = db.scalar(
            select(Post).where(Post.board_id == board.id, Post.title == title)
        )
        if post is None:
            post = Post(
                board_id=board.id,
                title=title,
                content=note or "",
                author_id=users[created_by].id if created_by in users else None,
            )
            db.add(post)
            db.flush()
            post.created_at = to_utc(created_at) or post.created_at
            created += 1
        else:
            reused += 1
        index[doc_id] = post
    st.add("게시글", created, reused)
    return index


def _attach_participants(
    db: Session, event: Event, attendee: User | None, organizer: User | None
) -> None:
    """이 서버에는 Event.organizer 칸이 없다. 주최자도 참석자 행이고
    is_organizer 로 구분한다. 구 시스템의 author(일정 주인)와 created_by(등록한
    사람)가 다를 수 있어 둘 다 넣는다."""
    # 세션이 autoflush=False 라 방금 add() 한 행은 아래 조회에 안 잡힌다.
    # 주최자와 참석자가 같은 사람일 때 같은 행을 두 번 넣지 않도록 직접 센다.
    seen: set[uuid.UUID] = set()
    for user, is_org in ((attendee, False), (organizer, True)):
        if user is None or user.id in seen:
            continue
        seen.add(user.id)
        existing = db.scalar(
            select(EventParticipant).where(
                EventParticipant.event_id == event.id,
                EventParticipant.user_id == user.id,
            )
        )
        if existing is not None:
            if is_org:
                existing.is_organizer = True
            continue
        db.add(
            EventParticipant(
                event_id=event.id,
                user_id=user.id,
                is_organizer=is_org,
                response=ParticipantResponse.ACCEPTED,
            )
        )
        # 다음 호출의 조회가 이 행을 보게 한다. 같은 회의가 사람 수만큼
        # 행으로 쪼개져 있어 같은 주최자로 여러 번 들어온다.
        db.flush()


def migrate_events(
    db: Session, src: sqlite3.Connection, st: Stats, users: dict[str, User]
) -> None:
    """구 공용 캘린더. 사무/출장/휴가 구분은 EVENT_CATEGORY 코드로 붙는다."""
    created = reused = 0
    calendar = db.scalar(select(Calendar).where(Calendar.type == CalendarType.COMPANY))
    if calendar is None:
        calendar = Calendar(
            name="공유 캘린더", type=CalendarType.COMPANY, color="#3B82F6"
        )
        db.add(calendar)
        db.flush()

    cat_group = _group(db, "EVENT_CATEGORY")
    for row in src.execute(
        "SELECT author, category, title, start_date, end_date, start_time, end_time,"
        " place, detail, created_by FROM events ORDER BY id"
    ):
        (
            author,
            category,
            title,
            start_date,
            end_date,
            start_time,
            end_time,
            place,
            detail,
            created_by,
        ) = row
        starts = to_utc(f"{start_date} {start_time or '09:00'}:00")
        ends = to_utc(f"{end_date} {end_time or '18:00'}:00")
        if starts is None:
            continue
        # 구 시스템은 한 사람당 한 행이라, 같은 회의에 두 명이 걸리면 제목과
        # 시각이 같은 행이 두 개 있다. 이 서버는 일정 하나에 참석자 여러 명이
        # 맞는 모양이므로, 이미 있으면 건너뛰지 말고 그 일정에 사람을 더한다.
        existing = db.scalar(
            select(Event).where(Event.title == title, Event.starts_at == starts)
        )
        if existing is not None:
            reused += 1
            _attach_participants(db, existing, users.get(author), users.get(created_by))
            continue
        item = None
        if cat_group is not None:
            item = db.scalar(
                select(CodeItem).where(
                    CodeItem.group_id == cat_group.id, CodeItem.name == category
                )
            )
        organizer = users.get(created_by) or users.get(author)
        event = Event(
            calendar_id=calendar.id,
            title=title or category,
            location=place or None,
            description=detail or None,
            starts_at=starts,
            ends_at=ends or starts,
            all_day=not (start_time or end_time),
            status=EventStatus.SCHEDULED,
            category_id=item.id if item else None,
        )
        db.add(event)
        db.flush()

        _attach_participants(db, event, users.get(author), organizer)
        created += 1
    st.add("일정", created, reused)


def migrate_files(
    db: Session,
    src: sqlite3.Connection,
    st: Stats,
    source_root: Path,
    tickets: dict[int, ServiceTicket],
    posts: dict[int, Post],
    dry_run: bool,
) -> None:
    """첨부 파일을 storage/ 로 복사하고 Attachment 행을 만든다."""
    created = reused = missing = 0

    jobs: list[tuple[str, uuid.UUID, str, Path]] = []
    for rec_no, filename, stored in src.execute(
        "SELECT record_no, filename, stored FROM attachments WHERE stored<>''"
    ):
        ticket = tickets.get(rec_no)
        if ticket is not None:
            jobs.append(
                (
                    "service_ticket",
                    ticket.id,
                    filename,
                    source_root / "uploads" / str(rec_no) / stored,
                )
            )
    for doc_id, filename, stored in src.execute(
        "SELECT doc_id, filename, stored FROM doc_files WHERE stored<>''"
    ):
        post = posts.get(doc_id)
        if post is not None:
            jobs.append(
                ("post", post.id, filename, source_root / "docs" / str(doc_id) / stored)
            )

    for entity_type, entity_id, original_name, path in jobs:
        existing = db.scalar(
            select(Attachment).where(
                Attachment.entity_type == entity_type,
                Attachment.entity_id == entity_id,
                Attachment.original_name == original_name,
                Attachment.deleted_at.is_(None),
            )
        )
        if existing is not None:
            reused += 1
            continue
        if not path.exists():
            print(f"  ! 파일 없음: {path}")
            missing += 1
            continue
        dest_dir = settings.storage_path / entity_type / str(entity_id)
        dest = dest_dir / f"{uuid.uuid4().hex}_{path.name}"
        if not dry_run:
            dest_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, dest)
        db.add(
            Attachment(
                entity_type=entity_type,
                entity_id=entity_id,
                original_name=original_name,
                stored_path=str(dest),
                content_type=mimetypes.guess_type(original_name)[0],
                size_bytes=path.stat().st_size,
            )
        )
        created += 1
    st.add("첨부 파일", created, reused)
    if missing:
        st.add("  원본 없음", missing, 0)


def migrate_worklogs(
    db: Session,
    src: sqlite3.Connection,
    st: Stats,
    users: dict[str, User],
    source_root: Path,
    dry_run: bool,
) -> None:
    """근무일지(worklogs) + 첨부(worklog_files → Attachment entity worklog).

    작성자 이름을 계정에 맞춘다(구 서버는 로그인 아이디 = 이름). 못 맞추면 이름만 남긴다.
    """
    created = reused = files_created = files_missing = 0
    by_name = {u.full_name: u for u in users.values()}
    for row in src.execute(
        "SELECT id, author, position, date, work_start, work_end, summary, detail, overtime, overtime_note,"
        " plan, needs, visibility, created_at, created_by, updated_at, updated_by FROM worklogs ORDER BY id"
    ):
        (
            wid,
            author,
            position,
            wdate,
            ws,
            we,
            summary,
            detail,
            overtime,
            note,
            plan,
            needs,
            visibility,
            created_at,
            created_by,
            updated_at,
            updated_by,
        ) = row
        log = db.scalar(select(WorkLog).where(WorkLog.legacy_id == wid))
        if log is not None:
            reused += 1
        else:
            user = users.get(author) or by_name.get(author)
            log = WorkLog(
                legacy_id=wid,
                author_id=user.id if user else None,
                author_name=author,
                position=position or None,
                work_date=to_date(wdate) or datetime.now(ZoneInfo("Asia/Seoul")).date(),
                work_start=ws or "09:00",
                work_end=we or "18:00",
                summary=summary or "-",
                detail=detail or "-",
                overtime=(overtime == "O"),
                overtime_note=note or None,
                plan=plan or None,
                needs=needs or None,
                visibility=WorkLogVisibility.TEAM
                if visibility == "team"
                else WorkLogVisibility.PRIVATE,
                created_by_id=(users.get(created_by) or by_name.get(created_by)).id
                if (users.get(created_by) or by_name.get(created_by))
                else None,
                updated_by_id=(users.get(updated_by) or by_name.get(updated_by)).id
                if (users.get(updated_by) or by_name.get(updated_by))
                else None,
            )
            db.add(log)
            db.flush()
            log.created_at = to_utc(created_at) or log.created_at
            log.updated_at = to_utc(updated_at) or log.created_at
            created += 1
        # 첨부: data/worklogs/<작성자>/<년>/<월>/<stored>
        for filename, stored, uploaded_by in src.execute(
            "SELECT filename, stored, uploaded_by FROM worklog_files WHERE worklog_id=? AND stored<>''",
            (wid,),
        ):
            exists = db.scalar(
                select(Attachment).where(
                    Attachment.entity_type == "worklog",
                    Attachment.entity_id == log.id,
                    Attachment.original_name == filename,
                    Attachment.deleted_at.is_(None),
                )
            )
            if exists is not None:
                continue
            path = source_root / "worklogs" / author / wdate[:4] / wdate[5:7] / stored
            if not path.exists():
                print(f"  ! 파일 없음: {path}")
                files_missing += 1
                continue
            dest_dir = settings.storage_path / "worklog" / str(log.id)
            dest = dest_dir / f"{uuid.uuid4().hex}_{path.name}"
            if not dry_run:
                dest_dir.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, dest)
            up = users.get(uploaded_by) or by_name.get(uploaded_by)
            db.add(
                Attachment(
                    entity_type="worklog",
                    entity_id=log.id,
                    original_name=filename,
                    stored_path=str(dest.relative_to(settings.storage_path)).replace(
                        "\\", "/"
                    ),
                    content_type=mimetypes.guess_type(filename)[0],
                    size_bytes=path.stat().st_size,
                    uploaded_by_id=up.id if up else None,
                )
            )
            files_created += 1
    st.add("근무일지", created, reused)
    st.add("  근무일지 첨부", files_created, 0)
    if files_missing:
        st.add("  근무일지 첨부 원본 없음", files_missing, 0)


# --------------------------------------------------------------- 진입점


def main() -> int:
    ap = argparse.ArgumentParser(description="구 서버(CS_Record) 자료 이관")
    ap.add_argument(
        "--source", required=True, help="구 서버 백업 폴더 (cs.db 가 있는 곳)"
    )
    ap.add_argument(
        "--password", default="ddeck1234", help="새로 만드는 계정의 임시 비밀번호"
    )
    ap.add_argument(
        "--dry-run", action="store_true", help="실제로 쓰지 않고 건수만 센다"
    )
    ap.add_argument(
        "--only",
        default="",
        help="쉼표로 나눈 단계 이름만 실행 (예: worklogs). 계정 매핑은 항상 읽는다",
    )
    args = ap.parse_args()

    source_root = Path(args.source).expanduser().resolve()
    db_path = source_root / "cs.db"
    if not db_path.exists():
        print(f"cs.db 를 찾을 수 없습니다: {db_path}")
        return 1

    target_engine, session_factory, scratch = engine, SessionLocal, None
    if args.dry_run:
        # Work on an isolated SQLite snapshot. Bootstrap commits must never touch
        # the actual target during a preview.
        import tempfile

        from sqlalchemy import create_engine
        from sqlalchemy.orm import sessionmaker

        if not settings.is_sqlite:
            ap.error(
                "--dry-run은 SQLite 복제본에서 실행하세요. PostgreSQL은 별도 검증 DB를 사용하세요."
            )
        scratch = tempfile.TemporaryDirectory(prefix="ddeck-legacy-preview-")
        shadow = Path(scratch.name) / "preview.db"
        original = Path(engine.url.database)
        if original.is_file():
            with (
                closing(
                    sqlite3.connect(f"file:{original.resolve()}?mode=ro", uri=True)
                ) as old,
                closing(sqlite3.connect(shadow)) as new,
            ):
                old.backup(new)
        target_engine = create_engine(f"sqlite:///{shadow}")
        session_factory = sessionmaker(bind=target_engine, autoflush=False)
        Base.metadata.create_all(bind=target_engine)
    else:
        from sqlalchemy import inspect

        if not inspect(target_engine).has_table("alembic_version"):
            ap.error(
                "대상 DB에 먼저 alembic upgrade head를 실행하세요. 기존 DB는 adopt_schema.py로 검증하세요."
            )

    # 부트스트랩을 먼저 돌린다. 이 스크립트가 ASSET_CATEGORY 같은 시스템
    # 코드군을 먼저 만들어 버리면 이름이 코드값 그대로 남고, 나중에 서버가
    # 떠도 이미 있다고 보고 고치지 않는다.
    boot_db = session_factory()
    try:
        bootstrap.run(boot_db)
    finally:
        boot_db.close()

    src = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    db = session_factory()
    st = Stats()
    try:
        print(f"원본: {db_path}")
        print(f"대상: {engine.url.render_as_string(hide_password=True)}")
        if args.dry_run:
            print("*** DRY RUN - 마지막에 되돌립니다 ***")
        print()

        only = {x.strip() for x in args.only.split(",") if x.strip()}
        users = migrate_users(db, src, st, args.password)
        if not only:
            codes = migrate_codes(db, src, st, users)
            stores = migrate_stores(db, src, st, codes)
            places = migrate_places(db, src, st)
            migrate_assets(db, src, st, codes, stores, places)
            deactivate_unused_categories(db, st)
            tickets = migrate_tickets(db, src, st, codes, stores, users)
            posts = migrate_board(db, src, st, users)
            migrate_events(db, src, st, users)
            migrate_files(db, src, st, source_root, tickets, posts, args.dry_run)
        if not only or "history" in only:
            from legacy_history import migrate

            migrate(db, src, st, users, to_utc, code_for)
        if not only or "worklogs" in only:
            migrate_worklogs(db, src, st, users, source_root, args.dry_run)

        if args.dry_run:
            db.rollback()
        else:
            db.commit()
        st.report()
        if args.dry_run:
            print("  DRY RUN - 아무것도 저장하지 않았습니다.")
        else:
            print(f"  새 계정 임시 비밀번호: {args.password} (첫 로그인 시 변경 요구)")
        return 0
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()
        src.close()
        if scratch is not None:
            target_engine.dispose()
            scratch.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
