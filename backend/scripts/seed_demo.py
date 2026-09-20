"""Populate the database with realistic demo data.

For the frontend team: run this once and every screen has something to render -
approved users at each role, a pending approval, 60 AS tickets spread over the
last 90 days (so the statistics charts have a real shape), assets in a location
tree, board posts and a week of calendar events.

Run:  python scripts/seed_demo.py            (adds to the current DB)
      python scripts/seed_demo.py --reset    (drops and recreates first)
"""
from __future__ import annotations

import random
import sys
from datetime import date, timedelta
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from sqlalchemy import select  # noqa: E402

from app.core.database import SessionLocal, engine  # noqa: E402
from app.core.security import hash_password, now_utc  # noqa: E402
from app.models import Base  # noqa: E402
from app.models.admin import CodeGroup, CodeItem  # noqa: E402
from app.models.board import Board, Post, PostComment  # noqa: E402
from app.models.calendar import (  # noqa: E402
    Calendar,
    Event,
    EventParticipant,
    EventReminder,
)
from app.models.enums import (  # noqa: E402
    AssetStatus,
    CalendarType,
    LocationType,
    MovementType,
    ParticipantResponse,
    ReminderMethod,
    Role,
    ServiceChannel,
    ServicePriority,
    ServiceStatus,
    UserStatus,
)
from app.models.inventory import Asset, AssetMovement, Location  # noqa: E402
from app.models.service import Customer, ServiceLog, ServicePart, ServiceTicket  # noqa: E402
from app.models.user import Department, User  # noqa: E402
from app.services import bootstrap  # noqa: E402

rng = random.Random(20260920)  # fixed seed: the same demo data every run

PEOPLE = [
    ("김서준", "seojun.kim", Role.ADMIN, "부장", "기술지원팀"),
    ("이하윤", "hayun.lee", Role.MANAGER, "팀장", "기술지원팀"),
    ("박도현", "dohyun.park", Role.MEMBER, "대리", "기술지원팀"),
    ("최지우", "jiwoo.choi", Role.MEMBER, "사원", "기술지원팀"),
    ("정민재", "minjae.jung", Role.MANAGER, "팀장", "영업팀"),
    ("강수아", "sua.kang", Role.MEMBER, "주임", "영업팀"),
    ("윤지호", "jiho.yoon", Role.MEMBER, "사원", "관리팀"),
]
CUSTOMERS = [
    ("대한산업", "02-512-3300", "서울시 강남구 테헤란로 152"),
    ("한빛전자", "031-777-1020", "경기도 성남시 분당구 판교로 235"),
    ("동성기계", "051-404-8800", "부산시 해운대구 센텀중앙로 79"),
    ("태양물산", "042-611-2200", "대전시 유성구 대학로 291"),
    ("우진테크", "053-350-4400", "대구시 북구 대학로 80"),
]
PRODUCTS = [
    ("산업용 컴프레서", "AC-2200X", "에어테크"),
    ("냉각 칠러", "CH-450", "쿨링코리아"),
    ("포장 실링기", "SL-120", "패킹시스템"),
    ("컨베이어 모듈", "CV-900", "무빙테크"),
    ("제어 판넬", "CP-77", "일렉트로"),
]
SYMPTOM_TEXT = [
    "가동 중 이상 소음 발생",
    "전원이 간헐적으로 꺼짐",
    "설정 온도까지 도달하지 않음",
    "누유 흔적 확인됨",
    "디스플레이 표시 오류",
    "정기 점검 요청",
]
RESULT_TEXT = [
    "소모품 교체 후 정상 동작 확인",
    "배선 접촉 불량 - 커넥터 교체",
    "냉매 보충 및 누설 부위 실링",
    "제어보드 펌웨어 업데이트",
    "필터 청소 및 점검 완료",
]


def main() -> None:
    if "--reset" in sys.argv:
        print("dropping all tables...")
        Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)

    db = SessionLocal()
    try:
        bootstrap.run(db)
        if db.scalar(select(Customer.id).where(Customer.name == "대한산업")):
            print("demo data already present - nothing to do.")
            return

        depts = seed_departments(db)
        users, pending = seed_users(db, depts)
        codes = load_codes(db)
        customers = seed_customers(db)
        seed_tickets(db, users, customers, codes)
        locations = seed_locations(db, users)
        seed_assets(db, users, locations, codes)
        seed_posts(db, users)
        seed_events(db, users, codes)
        db.commit()

        print("\ndemo data ready")
        print(f"  부서 {len(depts)} / 사용자 {len(users)} (+ 승인대기 {len(pending)})")
        print(f"  거래처 {len(customers)} / AS 60건 / 자산 {len(locations) and 24}건")
        print("\n로그인 계정 (비밀번호는 모두 demo1234):")
        for name, login, role, _, dept in PEOPLE:
            print(f"  {login}@ddeck.local  {name:5s} {role.value:10s} {dept}")
        print("  admin@ddeck.local   최고관리자 (SUPERADMIN, 비밀번호 admin1234)")
    finally:
        db.close()


def seed_departments(db) -> dict[str, Department]:
    out = {}
    for order, name in enumerate(["기술지원팀", "영업팀", "관리팀"], start=1):
        dept = db.scalar(select(Department).where(Department.name == name))
        if dept is None:
            dept = Department(name=name, code=name[:2].upper(), sort_order=order)
            db.add(dept)
        out[name] = dept
    db.flush()
    return out


def seed_users(db, depts) -> tuple[list[User], list[User]]:
    admin = db.scalar(select(User).where(User.role == Role.SUPERADMIN))
    users: list[User] = []
    for name, login, role, position, dept in PEOPLE:
        email = f"{login}@ddeck.local"
        user = db.scalar(select(User).where(User.email == email))
        if user is None:
            user = User(
                email=email,
                password_hash=hash_password("demo1234"),
                full_name=name,
                employee_no=f"E{2000 + len(users) + 1}",
                phone=f"010-{rng.randint(1000, 9999)}-{rng.randint(1000, 9999)}",
                position=position,
                department_id=depts[dept].id,
                role=role,
                status=UserStatus.APPROVED,
                approved_at=now_utc() - timedelta(days=120),
                approved_by_id=admin.id if admin else None,
            )
            db.add(user)
        users.append(user)

    # One account left waiting, so the approval queue screen has a row.
    pending: list[User] = []
    waiting = db.scalar(select(User).where(User.email == "newbie@ddeck.local"))
    if waiting is None:
        waiting = User(
            email="newbie@ddeck.local",
            password_hash=hash_password("demo1234"),
            full_name="신입사원",
            phone="010-2222-3333",
            department_id=depts["기술지원팀"].id,
            signup_note="3월 입사 예정입니다. 계정 승인 부탁드립니다.",
            status=UserStatus.PENDING,
        )
        db.add(waiting)
    pending.append(waiting)

    db.flush()
    return users, pending


def load_codes(db) -> dict[str, dict[str, CodeItem]]:
    out: dict[str, dict[str, CodeItem]] = {}
    for group in db.scalars(select(CodeGroup)).all():
        items = db.scalars(select(CodeItem).where(CodeItem.group_id == group.id)).all()
        out[group.code] = {i.code: i for i in items}
    return out


def seed_customers(db) -> list[Customer]:
    out = []
    for name, phone, address in CUSTOMERS:
        customer = Customer(
            name=name,
            code=f"C{rng.randint(1000, 9999)}",
            contact_name="담당자",
            phone=phone,
            address=address,
        )
        db.add(customer)
        out.append(customer)
    db.flush()
    return out


def seed_tickets(db, users, customers, codes) -> None:
    """60 tickets over the last 90 days, weighted so the charts look real."""
    cats = list(codes["SERVICE_CATEGORY"].values())
    symptoms = list(codes["SERVICE_SYMPTOM"].values())
    causes = list(codes["SERVICE_CAUSE"].values())
    actions = list(codes["SERVICE_ACTION"].values())
    engineers = [u for u in users if u.department_id == users[0].department_id]

    now = now_utc()
    for i in range(60):
        received = now - timedelta(
            days=rng.randint(0, 89), hours=rng.randint(0, 23), minutes=rng.randint(0, 59)
        )
        customer = rng.choice(customers)
        product, model, maker = rng.choice(PRODUCTS)
        assignee = rng.choice(engineers)
        category = rng.choices(cats, weights=[35, 30, 15, 10, 7, 3, 1][: len(cats)])[0]

        # 80% closed, the rest spread across the open states.
        closed = rng.random() < 0.8
        ticket = ServiceTicket(
            ticket_no=f"AS-{received.strftime('%Y%m')}-{i + 1:04d}",
            title=f"{customer.name} {product} {rng.choice(['수리', '점검', '설치'])} 요청",
            customer_id=customer.id,
            contact_phone=customer.phone,
            site_address=customer.address,
            product_name=product,
            model_name=model,
            serial_no=f"SN-{maker[:2].upper()}{rng.randint(10000, 99999)}",
            category_id=category.id,
            symptom_id=rng.choice(symptoms).id,
            priority=rng.choices(
                list(ServicePriority), weights=[10, 60, 25, 5]
            )[0],
            channel=rng.choices(list(ServiceChannel), weights=[50, 10, 20, 15, 5])[0],
            assignee_id=assignee.id,
            department_id=assignee.department_id,
            received_at=received,
            due_at=received + timedelta(days=3),
            is_warranty=rng.random() < 0.6,
            description=rng.choice(SYMPTOM_TEXT),
            created_by_id=assignee.id,
        )

        if closed:
            work = rng.randint(30, 480)
            started = received + timedelta(hours=rng.randint(1, 20))
            completed = started + timedelta(minutes=work + rng.randint(0, 600))
            ticket.status = ServiceStatus.COMPLETED
            ticket.started_at = started
            ticket.completed_at = min(completed, now)
            ticket.work_minutes = work
            ticket.cause_id = rng.choice(causes).id
            ticket.action_id = rng.choice(actions).id
            ticket.result_note = rng.choice(RESULT_TEXT)
            ticket.satisfaction = rng.choices([3, 4, 5], weights=[15, 45, 40])[0]
            ticket.labor_cost = Decimal(work * 500)
        else:
            ticket.status = rng.choice(
                [
                    ServiceStatus.RECEIVED,
                    ServiceStatus.ASSIGNED,
                    ServiceStatus.IN_PROGRESS,
                    ServiceStatus.PENDING_PARTS,
                ]
            )
            if ticket.status == ServiceStatus.IN_PROGRESS:
                ticket.started_at = received + timedelta(hours=2)

        db.add(ticket)
        db.flush()

        if rng.random() < 0.45:
            qty = rng.randint(1, 3)
            price = Decimal(rng.choice([12000, 35000, 88000, 150000, 240000]))
            db.add(
                ServicePart(
                    ticket_id=ticket.id,
                    part_name=rng.choice(
                        ["메인보드", "베어링", "압력센서", "구동벨트", "필터 세트"]
                    ),
                    quantity=Decimal(qty),
                    unit_price=price,
                )
            )
            ticket.parts_cost = price * qty
        ticket.total_cost = (ticket.labor_cost or Decimal(0)) + (
            ticket.parts_cost or Decimal(0)
        ) or None

        db.add(
            ServiceLog(
                ticket_id=ticket.id,
                author_id=assignee.id,
                to_status=ServiceStatus.RECEIVED,
                content="접수 등록",
            )
        )
        if ticket.status == ServiceStatus.COMPLETED:
            db.add(
                ServiceLog(
                    ticket_id=ticket.id,
                    author_id=assignee.id,
                    from_status=ServiceStatus.IN_PROGRESS,
                    to_status=ServiceStatus.COMPLETED,
                    content=ticket.result_note,
                    work_minutes=ticket.work_minutes,
                )
            )
    db.flush()


def seed_locations(db, users) -> dict[str, Location]:
    hq = db.scalar(select(Location).where(Location.code == "HQ"))
    out = {"HQ": hq}
    tree = [
        ("HQ-1F", "1층", LocationType.FLOOR, "HQ"),
        ("HQ-2F", "2층", LocationType.FLOOR, "HQ"),
        ("HQ-1F-WH", "자재창고", LocationType.ROOM, "HQ-1F"),
        ("HQ-1F-SV", "정비실", LocationType.ROOM, "HQ-1F"),
        ("HQ-2F-OF", "사무실", LocationType.ROOM, "HQ-2F"),
        ("HQ-2F-SR", "서버실", LocationType.ROOM, "HQ-2F"),
        ("VAN-01", "출동차량 1호", LocationType.VEHICLE, "HQ"),
        ("VAN-02", "출동차량 2호", LocationType.VEHICLE, "HQ"),
    ]
    for code, name, ltype, parent_code in tree:
        parent = out[parent_code]
        loc = Location(
            code=code,
            name=name,
            type=ltype,
            parent_id=parent.id,
            path=f"{parent.path or parent.name} > {name}",
            manager_id=rng.choice(users).id,
        )
        db.add(loc)
        out[code] = loc
    db.flush()
    return out


def seed_assets(db, users, locations, codes) -> None:
    cats = codes["ASSET_CATEGORY"]
    catalog = [
        ("노트북 ThinkPad E14", "IT", "Lenovo", 1_350_000, "HQ-2F-OF", AssetStatus.IN_USE),
        ("노트북 MacBook Air M3", "IT", "Apple", 1_890_000, "HQ-2F-OF", AssetStatus.IN_USE),
        ("데스크탑 워크스테이션", "IT", "HP", 2_400_000, "HQ-2F-OF", AssetStatus.IN_USE),
        ("서버 R750", "IT", "Dell", 8_900_000, "HQ-2F-SR", AssetStatus.IN_USE),
        ("네트워크 스위치 48P", "IT", "Cisco", 1_200_000, "HQ-2F-SR", AssetStatus.IN_USE),
        ("무정전 전원장치 3kVA", "IT", "APC", 950_000, "HQ-2F-SR", AssetStatus.IN_USE),
        ("복합기 C4080", "OFFICE", "신도리코", 1_100_000, "HQ-2F-OF", AssetStatus.IN_USE),
        ("프로젝터 EB-2250U", "OFFICE", "Epson", 890_000, "HQ-2F-OF", AssetStatus.IN_STOCK),
        ("디지털 멀티미터", "TOOL", "Fluke", 420_000, "HQ-1F-SV", AssetStatus.IN_STOCK),
        ("적외선 열화상 카메라", "TOOL", "FLIR", 2_800_000, "HQ-1F-SV", AssetStatus.IN_USE),
        ("진동 측정기", "TOOL", "SKF", 1_650_000, "VAN-01", AssetStatus.IN_USE),
        ("토크 렌치 세트", "TOOL", "Stahlwille", 380_000, "VAN-01", AssetStatus.IN_USE),
        ("전동 임팩트 드릴", "TOOL", "Bosch", 240_000, "VAN-02", AssetStatus.IN_USE),
        ("유압 프레스 20T", "TOOL", "한국유압", 3_200_000, "HQ-1F-SV", AssetStatus.REPAIR),
        ("승합차 스타리아", "VEHICLE", "현대", 38_000_000, "HQ", AssetStatus.IN_USE),
        ("화물차 포터2", "VEHICLE", "현대", 22_000_000, "HQ", AssetStatus.IN_USE),
        ("사무용 책상", "FURNITURE", "퍼시스", 320_000, "HQ-2F-OF", AssetStatus.IN_USE),
        ("회의용 테이블", "FURNITURE", "리바트", 680_000, "HQ-2F-OF", AssetStatus.IN_USE),
        ("철제 캐비닛", "FURNITURE", "코아스", 190_000, "HQ-1F-WH", AssetStatus.IN_STOCK),
    ]
    consumables = [
        ("압축기 오일 필터", "PART", 2, 10, "HQ-1F-WH"),
        ("V벨트 A-38", "PART", 14, 6, "HQ-1F-WH"),
        ("냉매 R-410A 11kg", "PART", 3, 5, "HQ-1F-WH"),
        ("압력 센서 0-10bar", "PART", 8, 4, "HQ-1F-WH"),
        ("토너 CT-350", "OFFICE", 1, 3, "HQ-1F-WH"),
    ]

    year = now_utc().strftime("%Y")
    n = 0
    for name, cat, maker, price, loc_code, st in catalog:
        n += 1
        holder = rng.choice(users) if st == AssetStatus.IN_USE else None
        asset = Asset(
            asset_no=f"AST-{year}-{n:05d}",
            name=name,
            category_id=cats[cat].id,
            manufacturer=maker,
            serial_no=f"{maker[:3].upper()}-{rng.randint(100000, 999999)}",
            status=st,
            location_id=locations[loc_code].id,
            holder_id=holder.id if holder else None,
            quantity=Decimal(1),
            purchase_date=date.today() - timedelta(days=rng.randint(60, 1200)),
            purchase_price=Decimal(price),
            supplier=rng.choice(["오피스디포", "테크몰", "직거래", "조달청"]),
            warranty_until=date.today() + timedelta(days=rng.randint(-200, 500)),
        )
        db.add(asset)
        db.flush()
        db.add(
            AssetMovement(
                asset_id=asset.id,
                movement_type=MovementType.INBOUND,
                to_location_id=asset.location_id,
                to_status=asset.status,
                quantity=asset.quantity,
                moved_at=now_utc() - timedelta(days=rng.randint(30, 400)),
                reason="신규 등록",
            )
        )

    for name, cat, qty, minimum, loc_code in consumables:
        n += 1
        asset = Asset(
            asset_no=f"AST-{year}-{n:05d}",
            name=name,
            category_id=cats[cat].id,
            status=AssetStatus.IN_STOCK,
            location_id=locations[loc_code].id,
            quantity=Decimal(qty),
            min_quantity=Decimal(minimum),
            unit="EA",
            purchase_price=Decimal(rng.choice([8000, 15000, 42000, 96000])),
        )
        db.add(asset)
        db.flush()
        db.add(
            AssetMovement(
                asset_id=asset.id,
                movement_type=MovementType.INBOUND,
                to_location_id=asset.location_id,
                to_status=asset.status,
                quantity=asset.quantity,
                moved_at=now_utc() - timedelta(days=rng.randint(5, 90)),
                reason="입고",
            )
        )
    db.flush()


def seed_posts(db, users) -> None:
    boards = {b.code: b for b in db.scalars(select(Board)).all()}
    content = [
        ("NOTICE", "2026년 하계 휴가 일정 안내", "8월 1일부터 8월 9일까지 전사 휴가입니다.\n\n긴급 AS 대응 당번은 별도 공지합니다.", True),
        ("NOTICE", "사내 DB 서버 오픈 안내", "AS 접수, 재고, 일정이 하나의 시스템으로 통합되었습니다.\n\n문의는 관리팀으로 부탁드립니다.", True),
        ("NOTICE", "9월 정기 안전교육 실시", "9월 25일 14시, 2층 회의실에서 진행합니다.", False),
        ("FREE", "출동 차량 블랙박스 메모리 교체했습니다", "1호차, 2호차 모두 교체 완료했습니다.", False),
        ("FREE", "점심 맛집 추천받습니다", "사무실 근처 새로 생긴 곳 아시는 분?", False),
        ("QNA", "칠러 CH-450 냉매 규격 문의", "R-410A 맞나요? 매뉴얼이 안 보여서요.", False),
        ("QNA", "자산 반납 절차가 어떻게 되나요", "노트북 교체받았는데 기존 장비 처리 방법 문의드립니다.", False),
        ("ARCHIVE", "컴프레서 AC-2200X 정비 매뉴얼", "정비 주기 및 분해 순서 정리본입니다.", False),
        ("ARCHIVE", "AS 보고서 표준 양식 v2", "2026년 3월부터 이 양식을 사용합니다.", False),
    ]
    for board_code, title, body, pinned in content:
        author = rng.choice(users)
        post = Post(
            board_id=boards[board_code].id,
            title=title,
            content=body,
            author_id=author.id,
            created_by_id=author.id,
            is_pinned=pinned,
            view_count=rng.randint(3, 140),
        )
        db.add(post)
        db.flush()
        for _ in range(rng.randint(0, 3)):
            db.add(
                PostComment(
                    post_id=post.id,
                    author_id=rng.choice(users).id,
                    content=rng.choice(
                        ["확인했습니다.", "감사합니다!", "참고하겠습니다.", "저도 같은 의견입니다."]
                    ),
                )
            )
            post.comment_count += 1
    db.flush()


def seed_events(db, users, codes) -> None:
    company = db.scalar(select(Calendar).where(Calendar.type == CalendarType.COMPANY))
    cats = codes["EVENT_CATEGORY"]

    team = db.scalar(select(Calendar).where(Calendar.name == "기술지원팀 일정"))
    if team is None:
        team = Calendar(
            name="기술지원팀 일정",
            type=CalendarType.DEPARTMENT,
            color="#10B981",
            department_id=users[0].department_id,
            is_shared=True,
        )
        db.add(team)
        db.flush()

    plan = [
        ("주간 업무 회의", "MEETING", company, 1, 9, 60, [0, 1, 2, 3]),
        ("대한산업 정기점검 출동", "AS_VISIT", team, 1, 13, 240, [1, 2]),
        ("신규 장비 교육", "TRAINING", company, 2, 14, 120, [0, 1, 2, 3, 4, 5, 6]),
        ("한빛전자 설치 건", "AS_VISIT", team, 3, 10, 300, [2, 3]),
        ("영업 전략 회의", "MEETING", company, 3, 16, 90, [0, 4, 5]),
        ("박도현 연차", "LEAVE", team, 4, 0, 1440, [2]),
        ("동성기계 출장", "TRIP", team, 5, 8, 600, [1, 3]),
        ("월간 실적 보고", "MEETING", company, 7, 15, 90, [0, 4, 6]),
    ]
    base = now_utc().replace(hour=0, minute=0, second=0, microsecond=0)
    for title, cat, calendar, day_offset, hour, minutes, member_idx in plan:
        starts = base + timedelta(days=day_offset, hours=hour)
        organizer = users[member_idx[0]]
        event = Event(
            calendar_id=calendar.id,
            title=title,
            description=f"{title} 관련 일정입니다.",
            location=rng.choice(["2층 회의실", "고객사 현장", "온라인", "정비실"]),
            category_id=cats[cat].id,
            starts_at=starts,
            ends_at=starts + timedelta(minutes=minutes),
            all_day=(minutes >= 1440),
            created_by_id=organizer.id,
        )
        db.add(event)
        db.flush()
        for idx in member_idx:
            db.add(
                EventParticipant(
                    event_id=event.id,
                    user_id=users[idx].id,
                    is_organizer=(idx == member_idx[0]),
                    response=(
                        ParticipantResponse.ACCEPTED
                        if idx == member_idx[0]
                        else rng.choice(
                            [
                                ParticipantResponse.ACCEPTED,
                                ParticipantResponse.PENDING,
                                ParticipantResponse.TENTATIVE,
                            ]
                        )
                    ),
                )
            )
        db.add(
            EventReminder(
                event_id=event.id,
                offset_minutes=30,
                method=ReminderMethod.PUSH,
                scheduled_at=starts - timedelta(minutes=30),
            )
        )
    db.flush()


if __name__ == "__main__":
    main()
