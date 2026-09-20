"""End-to-end smoke test of the whole skeleton against a throwaway SQLite file.

Run:  python scripts/smoke_test.py
It exercises the entry flow (가입 -> 승인 -> 로그인) and then one full round
trip through each of the five modules. Exits non-zero on the first failure.
"""
from __future__ import annotations

import os
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

# Must be set before app.core.config is imported.
TEST_DB = ROOT / "smoke_test.db"
TEST_DB.unlink(missing_ok=True)
os.environ["DATABASE_URL"] = f"sqlite+pysqlite:///{TEST_DB.as_posix()}"
os.environ["SCHEDULER_ENABLED"] = "false"
os.environ["FIRST_SUPERADMIN_EMAIL"] = "admin@ddeck.local"
os.environ["FIRST_SUPERADMIN_PASSWORD"] = "admin1234"

from fastapi.testclient import TestClient  # noqa: E402


from app.core.database import engine  # noqa: E402
from app.main import app  # noqa: E402

PASSED = 0


def check(label: str, condition: bool, detail: object = "") -> None:
    global PASSED
    if condition:
        PASSED += 1
        print(f"  OK   {label}")
    else:
        print(f"  FAIL {label}\n       {detail}")
        raise SystemExit(1)


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def utc(**kw) -> str:
    return (datetime.now(timezone.utc) + timedelta(**kw)).isoformat()


def q(**kw) -> str:
    """Query string with the +00:00 offsets percent-encoded."""
    return urlencode(kw)


with TestClient(app) as c:
    # ============================================================ entry flow
    print("\n[1] 진입 흐름: 가입 -> 승인 -> 로그인")

    email = f"tester_{uuid.uuid4().hex[:6]}@ddeck.local"
    r = c.post(
        "/api/v1/auth/signup",
        json={
            "email": email,
            "password": "test1234",
            "full_name": "김테스트",
            "phone": "010-0000-0000",
            "signup_note": "스모크 테스트 계정",
        },
    )
    check("회원가입 신청", r.status_code == 201, r.text)

    r = c.post("/api/v1/auth/signup", json={"email": email, "password": "test1234", "full_name": "중복"})
    check("중복 이메일 거절", r.status_code == 409 and r.json()["error"]["code"] == "EMAIL_TAKEN", r.text)

    r = c.post("/api/v1/auth/signup", json={"email": "weak@x.com", "password": "abcdefgh", "full_name": "약함"})
    check("비밀번호 정책 거절 (숫자 없음)", r.status_code == 422, r.status_code)

    r = c.post("/api/v1/auth/login", json={"email": email, "password": "test1234"})
    check(
        "승인 전 로그인 차단",
        r.status_code == 403 and r.json()["error"]["code"] == "ACCOUNT_NOT_ACTIVE",
        r.text,
    )

    r = c.post("/api/v1/auth/login", json={"email": "admin@ddeck.local", "password": "admin1234"})
    check("최고관리자 로그인", r.status_code == 200, r.text)
    admin_token = r.json()["access_token"]
    check("초기 비밀번호 변경 요구 플래그", r.json()["user"]["must_change_password"] is True)

    r = c.get("/api/v1/users/pending", headers=bearer(admin_token))
    check("승인 대기열 조회", r.status_code == 200 and r.json()["total"] == 1, r.text)
    pending_id = r.json()["items"][0]["id"]
    check("대기열에 가입 사유 노출", r.json()["items"][0]["signup_note"] == "스모크 테스트 계정")

    r = c.post(
        f"/api/v1/users/{pending_id}/approve",
        headers=bearer(admin_token),
        json={"role": "MANAGER"},
    )
    check("관리자 승인", r.status_code == 200 and r.json()["status"] == "APPROVED", r.text)

    r = c.post("/api/v1/auth/login", json={"email": email, "password": "test1234"})
    check("승인 후 로그인", r.status_code == 200, r.text)
    user_token = r.json()["access_token"]
    user_id = r.json()["user"]["id"]
    refresh = r.json()["refresh_token"]

    r = c.post("/api/v1/auth/refresh", json={"refresh_token": refresh})
    check("토큰 갱신", r.status_code == 200 and "access_token" in r.json(), r.text)

    r = c.get("/api/v1/auth/me", headers=bearer(user_token))
    check("내 정보 조회", r.status_code == 200 and r.json()["role"] == "MANAGER", r.text)

    r = c.get("/api/v1/users", headers=bearer(user_token))
    check("일반 권한으로 관리자 목록 차단", r.status_code == 403, r.status_code)

    r = c.get("/api/v1/auth/me")
    check("토큰 없이 접근 차단", r.status_code == 401, r.status_code)

    # ============================================================ admin: settings + codes
    print("\n[2] 관리기능: 모듈 설정 / 분류 코드")

    r = c.get("/api/v1/admin/settings/SERVICE", headers=bearer(admin_token))
    check("서비스 설정창 로드", r.status_code == 200 and len(r.json()["settings"]) >= 5, r.text)
    check("설정창에 분류 코드 동봉", len(r.json()["code_groups"]) == 4, len(r.json()["code_groups"]))

    r = c.put(
        "/api/v1/admin/settings/SERVICE",
        headers=bearer(admin_token),
        json={
            "settings": [
                {"key": "ticket_prefix", "value": "SVC", "value_type": "string",
                 "label": "접수번호 접두어", "is_public": True},
                {"key": "require_result_note", "value": True, "value_type": "bool",
                 "label": "완료 시 처리내용 필수", "is_public": True},
            ]
        },
    )
    check("설정 저장", r.status_code == 200, r.text)
    saved = {s["key"]: s["value"] for s in r.json()["settings"]}
    check("저장값 반영", saved["ticket_prefix"] == "SVC", saved.get("ticket_prefix"))

    r = c.get("/api/v1/admin/codes/SERVICE_CATEGORY", headers=bearer(user_token))
    check("분류 그룹 조회", r.status_code == 200 and len(r.json()["items"]) == 6, r.text)
    categories = {i["code"]: i["id"] for i in r.json()["items"]}
    group_id = r.json()["id"]

    r = c.post(
        f"/api/v1/admin/codes/{group_id}/items",
        headers=bearer(admin_token),
        json={"code": "EMERGENCY", "name": "긴급출동", "color": "#DC2626", "sort_order": 7},
    )
    check("분류 항목 추가", r.status_code == 201, r.text)

    r = c.get("/api/v1/admin/codes/SERVICE_SYMPTOM", headers=bearer(user_token))
    symptoms = {i["code"]: i["id"] for i in r.json()["items"]}

    r = c.post(
        "/api/v1/admin/departments",
        headers=bearer(admin_token),
        json={"name": "기술지원팀", "code": "TECH"},
    )
    check("부서 생성", r.status_code == 201, r.text)
    dept_id = r.json()["id"]

    # ============================================================ service
    print("\n[3] 서비스(AS): 접수 -> 처리 -> 자동 통계")

    r = c.post(
        "/api/v1/service/customers",
        headers=bearer(user_token),
        json={"name": "대한산업", "phone": "02-1234-5678", "address": "서울시 강남구"},
    )
    check("거래처 등록", r.status_code == 201, r.text)
    customer_id = r.json()["id"]

    ticket_ids = []
    for i, (cat, sym) in enumerate(
        [("REPAIR", "POWER"), ("REPAIR", "NOISE"), ("INSTALL", "MALFUNCTION"), ("INSPECT", "ETC")]
    ):
        r = c.post(
            "/api/v1/service/tickets",
            headers=bearer(user_token),
            json={
                "title": f"AS 접수 테스트 {i + 1}",
                "customer_id": customer_id,
                "category_id": categories[cat],
                "symptom_id": symptoms[sym],
                "priority": "HIGH" if i == 0 else "NORMAL",
                "assignee_id": user_id,
                "description": "동작 중 갑자기 멈춤",
                "parts": [{"part_name": "메인보드", "quantity": 1, "unit_price": 150000}] if i == 0 else [],
            },
        )
        check(f"AS 접수 #{i + 1}", r.status_code == 201, r.text)
        ticket_ids.append(r.json()["id"])

    first = c.get(f"/api/v1/service/tickets/{ticket_ids[0]}", headers=bearer(user_token)).json()
    check("접수번호 채번 (설정 접두어 반영)", first["ticket_no"].startswith("SVC-"), first["ticket_no"])
    check("담당자 지정 시 상태 ASSIGNED", first["status"] == "ASSIGNED", first["status"])
    check("부품비 자동 합산", float(first["parts_cost"]) == 150000.0, first["parts_cost"])
    check("접수 이력 자동 기록", len(first["logs"]) == 1, first["logs"])
    check("기본 처리기한 자동 설정", first["due_at"] is not None)

    r = c.post(
        f"/api/v1/service/tickets/{ticket_ids[0]}/status",
        headers=bearer(user_token),
        json={"status": "COMPLETED"},
    )
    check("처리내용 없이 완료 차단", r.status_code == 400 and r.json()["error"]["code"] == "RESULT_NOTE_REQUIRED", r.text)

    for tid in ticket_ids[:3]:
        c.post(
            f"/api/v1/service/tickets/{tid}/status",
            headers=bearer(user_token),
            json={"status": "IN_PROGRESS", "note": "현장 출동"},
        )
        r = c.post(
            f"/api/v1/service/tickets/{tid}/status",
            headers=bearer(user_token),
            json={"status": "COMPLETED", "result_note": "부품 교체 완료", "work_minutes": 90},
        )
        check(f"완료 처리 {tid[:8]}", r.status_code == 200 and r.json()["status"] == "COMPLETED", r.text)

    detail = c.get(f"/api/v1/service/tickets/{ticket_ids[0]}", headers=bearer(user_token)).json()
    check("완료 시각 기록", detail["completed_at"] is not None)
    check("처리 소요시간 산출", detail["resolution_minutes"] is not None, detail["resolution_minutes"])
    check("상태 변경 이력 누적", len(detail["logs"]) == 3, len(detail["logs"]))

    r = c.get("/api/v1/service/stats/summary", headers=bearer(user_token))
    s = r.json()
    check("통계 요약 조회", r.status_code == 200, r.text)
    check("총 건수", s["total"] == 4, s["total"])
    check("완료 건수", s["completed_count"] == 3, s["completed_count"])
    check("미완료 건수", s["open_count"] == 1, s["open_count"])
    check("완료율 산출", s["completion_rate"] == 0.75, s["completion_rate"])
    check("평균 처리시간 산출", s["avg_resolution_minutes"] is not None, s["avg_resolution_minutes"])
    check("상태별 분포", len(s["by_status"]) == 2, s["by_status"])
    check("상태 라벨 한글화", {b["label"] for b in s["by_status"]} == {"완료", "배정"}, s["by_status"])

    r = c.get("/api/v1/service/stats/grouped?group_by=category", headers=bearer(user_token))
    g = r.json()
    check("분류별 집계", r.status_code == 200 and g["total"] == 4, r.text)
    by_cat = {b["label"]: b["count"] for b in g["buckets"]}
    check("수리 2건 집계", by_cat.get("수리") == 2, by_cat)
    check("비율 산출", abs(sum(b["ratio"] for b in g["buckets"]) - 1.0) < 0.01, g["buckets"])
    check("분류 색상 전달", any(b["color"] for b in g["buckets"]), g["buckets"])

    for axis in ["symptom", "cause", "action", "assignee", "priority", "channel", "status"]:
        r = c.get(f"/api/v1/service/stats/grouped?group_by={axis}", headers=bearer(user_token))
        check(f"집계 축 {axis}", r.status_code == 200, r.text)

    r = c.get("/api/v1/service/stats/trend?interval=day", headers=bearer(user_token))
    t = r.json()
    check("일별 추이", r.status_code == 200 and len(t["points"]) >= 1, r.text)
    check("추이 접수/완료 집계", t["points"][0]["received"] == 4 and t["points"][0]["completed"] == 3, t["points"])

    for iv in ["week", "month"]:
        r = c.get(f"/api/v1/service/stats/trend?interval={iv}", headers=bearer(user_token))
        check(f"{iv} 추이", r.status_code == 200 and len(r.json()["points"]) >= 1, r.text)

    r = c.get("/api/v1/service/tickets?only_open=true", headers=bearer(user_token))
    check("미완료 필터", r.json()["total"] == 1, r.json()["total"])
    r = c.get("/api/v1/service/tickets?q=테스트 2", headers=bearer(user_token))
    check("검색 필터", r.json()["total"] == 1, r.json()["total"])

    # ============================================================ inventory
    print("\n[4] 재고관리: 위치 -> 자산 -> 이동 이력")

    hq = c.get("/api/v1/inventory/locations", headers=bearer(user_token)).json()
    hq_id = hq[0]["id"]
    check("기본 위치 시드", hq[0]["code"] == "HQ", hq)

    r = c.post(
        "/api/v1/inventory/locations",
        headers=bearer(user_token),
        json={"code": "HQ-2F", "name": "2층", "type": "FLOOR", "parent_id": hq_id},
    )
    check("하위 위치 생성", r.status_code == 201, r.text)
    floor_id = r.json()["id"]
    check("경로 자동 생성", r.json()["path"] == "본사 > 2층", r.json()["path"])

    r = c.post(
        "/api/v1/inventory/locations",
        headers=bearer(user_token),
        json={"code": "HQ-2F-A", "name": "창고A", "type": "ROOM", "parent_id": floor_id},
    )
    warehouse_id = r.json()["id"]
    check("3단계 경로", r.json()["path"] == "본사 > 2층 > 창고A", r.json()["path"])

    asset_cats = c.get("/api/v1/admin/codes/ASSET_CATEGORY", headers=bearer(user_token)).json()
    it_cat = next(i["id"] for i in asset_cats["items"] if i["code"] == "IT")

    r = c.post(
        "/api/v1/inventory/assets",
        headers=bearer(user_token),
        json={
            "name": "노트북 ThinkPad X1",
            "category_id": it_cat,
            "manufacturer": "Lenovo",
            "serial_no": "SN-0001",
            "location_id": warehouse_id,
            "quantity": 1,
            "purchase_price": 2400000,
        },
    )
    check("자산 등록", r.status_code == 201, r.text)
    asset = r.json()
    asset_id = asset["id"]
    check("자산번호 자동 채번", asset["asset_no"].startswith("AST-"), asset["asset_no"])
    check("위치 경로 동봉", asset["location"]["path"] == "본사 > 2층 > 창고A", asset["location"])

    r = c.post(
        "/api/v1/inventory/assets",
        headers=bearer(user_token),
        json={"name": "위치없음", "category_id": it_cat},
    )
    check("위치 필수 설정 적용", r.status_code == 400 and r.json()["error"]["code"] == "LOCATION_REQUIRED", r.text)

    r = c.post(
        "/api/v1/inventory/assets",
        headers=bearer(user_token),
        json={
            "name": "토너 카트리지", "category_id": it_cat, "location_id": warehouse_id,
            "quantity": 2, "unit": "EA", "min_quantity": 5,
        },
    )
    check("소모품 등록", r.status_code == 201, r.text)
    check("안전재고 미만 감지", r.json()["is_below_min"] is True, r.json()["is_below_min"])

    r = c.post(
        f"/api/v1/inventory/assets/{asset_id}/move",
        headers=bearer(user_token),
        json={"movement_type": "ASSIGN", "to_holder_id": user_id, "reason": "신규 입사자 지급"},
    )
    check("자산 불출", r.status_code == 200, r.text)
    check("불출 시 상태 자동 IN_USE", r.json()["status"] == "IN_USE", r.json()["status"])
    check("보관자 반영", r.json()["holder"]["full_name"] == "김테스트", r.json()["holder"])

    r = c.post(
        f"/api/v1/inventory/assets/{asset_id}/move",
        headers=bearer(user_token),
        json={"movement_type": "MOVE", "to_location_id": floor_id, "reason": "사무실 이전"},
    )
    check("위치 이동", r.json()["location"]["path"] == "본사 > 2층", r.json()["location"])

    r = c.get(f"/api/v1/inventory/assets/{asset_id}/movements", headers=bearer(user_token))
    check("이동 이력 3건 (등록/불출/이동)", r.json()["total"] == 3, r.json()["total"])

    r = c.get(f"/api/v1/inventory/assets?location_id={hq_id}", headers=bearer(user_token))
    check("하위 위치 포함 검색", r.json()["total"] == 2, r.json()["total"])
    r = c.get(f"/api/v1/inventory/assets?location_id={hq_id}&include_sublocations=false", headers=bearer(user_token))
    check("하위 위치 제외 검색", r.json()["total"] == 0, r.json()["total"])

    r = c.get("/api/v1/inventory/locations/tree", headers=bearer(user_token))
    tree = r.json()
    check("위치 트리 조회", r.status_code == 200 and len(tree) == 1, r.text)
    check("트리 중첩 구조", tree[0]["children"][0]["children"][0]["name"] == "창고A", tree)

    r = c.get("/api/v1/inventory/summary", headers=bearer(user_token))
    inv = r.json()
    check("재고 요약", r.status_code == 200 and inv["total_assets"] == 2, r.text)
    check("안전재고 경고 집계", inv["below_min_count"] == 1, inv["below_min_count"])
    check("위치별 집계", len(inv["by_location"]) == 2, inv["by_location"])

    r = c.delete(f"/api/v1/inventory/locations/{floor_id}", headers=bearer(user_token))
    check("자산 있는 위치 삭제 차단", r.status_code == 400 and r.json()["error"]["code"] == "LOCATION_IN_USE", r.text)

    # ============================================================ board
    print("\n[5] 게시판: 설정 -> 글 -> 댓글")

    r = c.get("/api/v1/board/boards", headers=bearer(user_token))
    boards = {b["code"]: b for b in r.json()}
    check("기본 게시판 시드", set(boards) == {"NOTICE", "FREE", "QNA", "ARCHIVE"}, list(boards))
    check("공지 게시판 쓰기권한 ADMIN", boards["NOTICE"]["write_role"] == "ADMIN")

    r = c.post(
        f"/api/v1/board/boards/{boards['NOTICE']['id']}/posts",
        headers=bearer(user_token),
        json={"title": "권한 없는 공지", "content": "x"},
    )
    check("쓰기권한 없는 게시판 차단", r.status_code == 403, r.status_code)

    r = c.post(
        f"/api/v1/board/boards/{boards['FREE']['id']}/posts",
        headers=bearer(user_token),
        json={"title": "첫 글입니다", "content": "본문 내용", "is_pinned": True},
    )
    check("게시글 작성", r.status_code == 201, r.text)
    post_id = r.json()["id"]
    check("작성자 정보 동봉", r.json()["author"]["full_name"] == "김테스트", r.json()["author"])

    r = c.post(
        f"/api/v1/board/posts/{post_id}/comments",
        headers=bearer(admin_token),
        json={"content": "확인했습니다"},
    )
    check("댓글 작성", r.status_code == 200, r.text)

    r = c.get(f"/api/v1/board/posts/{post_id}", headers=bearer(admin_token))
    check("댓글 수 반영", r.json()["comment_count"] == 1, r.json()["comment_count"])
    check("댓글 본문 조회", r.json()["comments"][0]["content"] == "확인했습니다", r.json()["comments"])
    check("조회수 증가", r.json()["view_count"] == 1, r.json()["view_count"])

    r = c.get("/api/v1/calendar/notifications?unread_only=true", headers=bearer(user_token))
    titles = [n["title"] for n in r.json()["items"]]
    check("내 글 댓글 알림 수신", "내 글에 댓글이 달렸습니다" in titles, titles)

    r = c.patch(
        f"/api/v1/board/boards/{boards['FREE']['id']}",
        headers=bearer(admin_token),
        json={"allow_comment": False, "page_size": 50},
    )
    check("게시판 설정 변경", r.status_code == 200 and r.json()["page_size"] == 50, r.text)

    r = c.post(
        f"/api/v1/board/posts/{post_id}/comments",
        headers=bearer(admin_token),
        json={"content": "막혔나?"},
    )
    check("댓글 비허용 설정 적용", r.status_code == 400 and r.json()["error"]["code"] == "COMMENT_NOT_ALLOWED", r.text)

    # ============================================================ calendar
    print("\n[6] 캘린더: 일정 공유 -> 참석자 -> 알림")

    r = c.get("/api/v1/calendar/calendars", headers=bearer(user_token))
    check("전사 캘린더 공유", r.status_code == 200 and len(r.json()) == 1, r.text)
    cal_id = r.json()[0]["id"]

    admin_me = c.get("/api/v1/auth/me", headers=bearer(admin_token)).json()
    admin_id = admin_me["id"]

    r = c.post(
        "/api/v1/calendar/events",
        headers=bearer(user_token),
        json={
            "calendar_id": cal_id,
            "title": "주간 업무 회의",
            "location": "대회의실",
            "starts_at": utc(hours=2),
            "ends_at": utc(hours=3),
            "participant_ids": [admin_id],
        },
    )
    check("일정 등록", r.status_code == 201, r.text)
    event = r.json()
    event_id = event["id"]
    check("주최자 자동 참석", len(event["participants"]) == 2, event["participants"])
    check("기본 알림 자동 생성", len(event["reminders"]) == 1, event["reminders"])
    check("알림 시각 = 시작 30분 전", event["reminders"][0]["offset_minutes"] == 30, event["reminders"])

    r = c.get("/api/v1/calendar/notifications?unread_only=true", headers=bearer(admin_token))
    titles = [n["title"] for n in r.json()["items"]]
    check("참석자에게 초대 알림", "[일정 초대] 주간 업무 회의" in titles, titles)

    r = c.post(
        f"/api/v1/calendar/events/{event_id}/respond",
        headers=bearer(admin_token),
        json={"response": "ACCEPTED"},
    )
    check("참석 응답", r.status_code == 200 and r.json()["response"] == "ACCEPTED", r.text)

    r = c.get(
        "/api/v1/calendar/events?" + q(date_from=utc(hours=-1), date_to=utc(days=1)),
        headers=bearer(admin_token),
    )
    check("기간 조회", r.status_code == 200 and len(r.json()) == 1, r.text)

    r = c.get(
        "/api/v1/calendar/events?" + q(date_from=utc(days=5), date_to=utc(days=6)),
        headers=bearer(admin_token),
    )
    check("범위 밖 일정 제외", len(r.json()) == 0, r.json())

    # A past-due reminder must be picked up by the sweep.
    r = c.patch(
        f"/api/v1/calendar/events/{event_id}",
        headers=bearer(user_token),
        json={"starts_at": utc(minutes=5), "ends_at": utc(minutes=65)},
    )
    check("일정 시간 변경", r.status_code == 200, r.text)
    check("알림 재계산", r.json()["reminders"][0]["sent_at"] is None, r.json()["reminders"])

    r = c.post("/api/v1/calendar/reminders/run", headers=bearer(admin_token))
    check("알림 스윕 실행", r.status_code == 200 and "1건" in r.json()["message"], r.text)

    r = c.get("/api/v1/calendar/notifications?unread_only=true", headers=bearer(admin_token))
    titles = [n["title"] for n in r.json()["items"]]
    check("일정 알림 도착", "[일정 알림] 주간 업무 회의" in titles, titles)

    r = c.get("/api/v1/calendar/notifications/count", headers=bearer(admin_token))
    unread = r.json()["unread"]
    check("미읽음 카운트", unread >= 3, unread)

    r = c.post("/api/v1/calendar/notifications/read-all", headers=bearer(admin_token))
    check("전체 읽음 처리", r.status_code == 200, r.text)
    check("카운트 0", c.get("/api/v1/calendar/notifications/count", headers=bearer(admin_token)).json()["unread"] == 0)

    r = c.post(
        "/api/v1/calendar/calendars",
        headers=bearer(user_token),
        json={"name": "내 개인 일정", "type": "PERSONAL", "color": "#8B5CF6"},
    )
    check("개인 캘린더 생성", r.status_code == 201, r.text)
    personal_id = r.json()["id"]

    r = c.get("/api/v1/calendar/calendars", headers=bearer(admin_token))
    check("남의 개인 캘린더는 안 보임", personal_id not in [x["id"] for x in r.json()], r.json())

    r = c.patch(
        f"/api/v1/calendar/calendars/{personal_id}",
        headers=bearer(admin_token),
        json={"name": "가로채기"},
    )
    check("남의 개인 캘린더 수정 차단", r.status_code == 403, r.status_code)

    r = c.patch(
        f"/api/v1/calendar/calendars/{personal_id}",
        headers=bearer(user_token),
        json={"name": "내 일정(수정)"},
    )
    check("본인 개인 캘린더 수정", r.status_code == 200 and r.json()["name"] == "내 일정(수정)", r.text)

    r = c.delete(f"/api/v1/calendar/calendars/{cal_id}", headers=bearer(admin_token))
    check("전사 캘린더 삭제 차단", r.status_code == 400, r.status_code)

    r = c.delete(f"/api/v1/calendar/calendars/{personal_id}", headers=bearer(user_token))
    check("개인 캘린더 삭제", r.status_code == 200, r.text)

    r = c.post(
        "/api/v1/calendar/notifications/broadcast",
        headers=bearer(admin_token),
        json={"title": "서버 점검 안내", "body": "금요일 22시"},
    )
    check("전체 공지 발송", r.status_code == 200 and "2명" in r.json()["message"], r.text)

    # ============================================================ admin ops
    print("\n[7] 관리기능: 상태 / 통계 / 감사로그")

    r = c.get("/api/v1/admin/health", headers=bearer(admin_token))
    check("헬스체크", r.status_code == 200 and r.json()["database_ok"] is True, r.text)
    check("DB 종류 노출", r.json()["database"] == "sqlite", r.json()["database"])

    r = c.get("/api/v1/admin/stats", headers=bearer(admin_token))
    st = r.json()
    check("시스템 통계", r.status_code == 200, r.text)
    check("계정 수", st["users_active"] == 2, st["users_active"])
    check("AS 건수", st["tickets_total"] == 4, st["tickets_total"])
    check("자산 건수", st["assets_total"] == 2, st["assets_total"])
    check("테이블 목록", len(st["tables"]) == 24, len(st["tables"]))

    r = c.get("/api/v1/admin/audit-logs?size=100", headers=bearer(admin_token))
    logs = r.json()
    check("감사로그 조회", r.status_code == 200 and len(logs) > 5, len(logs))
    actions = {log["action"] for log in logs}
    check("로그인 기록", "LOGIN" in actions, actions)
    check("승인 기록", "APPROVE" in actions, actions)
    check("설정변경 기록", "SETTING_CHANGE" in actions, actions)

    r = c.get("/api/v1/admin/audit-logs?action=APPROVE", headers=bearer(admin_token))
    check("감사로그 필터", len(r.json()) == 1 and "가입 승인" in r.json()[0]["summary"], r.json())

    r = c.get("/api/v1/admin/audit-logs", headers=bearer(user_token))
    check("감사로그 관리자 전용", r.status_code == 403, r.status_code)

    # ============================================================ security
    print("\n[8] 보안 동작")

    r = c.patch(
        f"/api/v1/users/{user_id}",
        headers=bearer(admin_token),
        json={"status": "SUSPENDED"},
    )
    check("계정 정지", r.status_code == 200, r.text)

    r = c.get("/api/v1/auth/me", headers=bearer(user_token))
    check("정지 시 기존 토큰 즉시 차단", r.status_code == 403, r.status_code)

    r = c.post("/api/v1/auth/refresh", json={"refresh_token": refresh})
    check("정지 시 토큰 갱신 차단", r.status_code in (401, 403), r.status_code)

    c.patch(f"/api/v1/users/{user_id}", headers=bearer(admin_token), json={"status": "APPROVED"})
    r = c.post("/api/v1/auth/login", json={"email": email, "password": "wrong-pass-1"})
    check("오답 로그인 거절", r.status_code == 401, r.status_code)

    r = c.post(
        f"/api/v1/users/{admin_id}/approve",
        headers=bearer(admin_token),
        json={"role": "MEMBER"},
    )
    check("이미 승인된 계정 재승인 차단", r.status_code == 400, r.status_code)

print(f"\n{'=' * 60}")
print(f"  통과 {PASSED}건 - 전 모듈 정상 동작")
print(f"{'=' * 60}")
# Windows keeps the file locked until the connection pool is closed, and
# WAL mode leaves two sidecar files behind.
engine.dispose()
for suffix in ("", "-wal", "-shm"):
    Path(str(TEST_DB) + suffix).unlink(missing_ok=True)
