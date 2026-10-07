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
os.environ["ENVIRONMENT"] = "test"
os.environ["DEBUG"] = "false"
os.environ["AUTH_RATE_LIMIT_ENABLED"] = "false"
os.environ["FIRST_SUPERADMIN_EMAIL"] = "admin@ddeck.local"
os.environ["FIRST_SUPERADMIN_PASSWORD"] = "admin1234"
TEST_STORAGE = ROOT / "smoke_test_storage"
os.environ["STORAGE_DIR"] = str(TEST_STORAGE)

import shutil

from fastapi.testclient import TestClient

from app.core.database import engine
from app.main import app

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

    r = c.post(
        "/api/v1/auth/signup",
        json={"email": email, "password": "test1234", "full_name": "중복"},
    )
    check(
        "중복 이메일 거절",
        r.status_code == 409 and r.json()["error"]["code"] == "EMAIL_TAKEN",
        r.text,
    )

    r = c.post(
        "/api/v1/auth/signup",
        json={"email": "weak@x.com", "password": "abcdefgh", "full_name": "약함"},
    )
    check("비밀번호 정책 거절 (숫자 없음)", r.status_code == 422, r.status_code)

    r = c.post("/api/v1/auth/login", json={"email": email, "password": "test1234"})
    check(
        "승인 전 로그인 차단",
        r.status_code == 403 and r.json()["error"]["code"] == "ACCOUNT_NOT_ACTIVE",
        r.text,
    )

    r = c.post(
        "/api/v1/auth/login",
        json={"email": "admin@ddeck.local", "password": "admin1234"},
    )
    check("최고관리자 로그인", r.status_code == 200, r.text)
    admin_token = r.json()["access_token"]
    check(
        "초기 비밀번호 변경 요구 플래그",
        r.json()["user"]["must_change_password"] is True,
    )

    # 서버가 직접 막는다: 비밀번호를 바꾸기 전에는 내 정보·변경·로그아웃 외 전부 403
    r = c.get("/api/v1/users/pending", headers=bearer(admin_token))
    check(
        "비밀번호 변경 전 다른 API 차단",
        r.status_code == 403
        and r.json()["error"]["code"] == "PASSWORD_CHANGE_REQUIRED",
        r.text,
    )
    r = c.get("/api/v1/auth/me", headers=bearer(admin_token))
    check("변경 전에도 내 정보 조회는 허용", r.status_code == 200, r.text)
    r = c.post(
        "/api/v1/auth/change-password",
        headers=bearer(admin_token),
        json={"current_password": "admin1234", "new_password": "admin5678"},
    )
    check("초기 비밀번호 변경", r.status_code == 200, r.text)
    r = c.post(
        "/api/v1/auth/login",
        json={"email": "admin@ddeck.local", "password": "admin5678"},
    )
    check(
        "새 비밀번호 로그인 · 플래그 해제",
        r.status_code == 200 and r.json()["user"]["must_change_password"] is False,
        r.text,
    )
    admin_token = r.json()["access_token"]
    # 아래 검사들이 admin1234 로 다시 로그인하므로 되돌린다 ("이전과 달라야" 규칙은 현재 값 기준)
    r = c.post(
        "/api/v1/auth/change-password",
        headers=bearer(admin_token),
        json={"current_password": "admin5678", "new_password": "admin1234"},
    )
    check("비밀번호 되돌리기", r.status_code == 200, r.text)
    r = c.post(
        "/api/v1/auth/login",
        json={"email": "admin@ddeck.local", "password": "admin1234"},
    )
    admin_token = r.json()["access_token"]

    r = c.get("/api/v1/users/pending", headers=bearer(admin_token))
    check("승인 대기열 조회", r.status_code == 200 and r.json()["total"] == 1, r.text)
    pending_id = r.json()["items"][0]["id"]
    check(
        "대기열에 가입 사유 노출",
        r.json()["items"][0]["signup_note"] == "스모크 테스트 계정",
    )

    r = c.post(
        f"/api/v1/users/{pending_id}/approve",
        headers=bearer(admin_token),
        json={"role": "MANAGER"},
    )
    check(
        "관리자 승인", r.status_code == 200 and r.json()["status"] == "APPROVED", r.text
    )

    r = c.post("/api/v1/auth/login", json={"email": email, "password": "test1234"})
    check("승인 후 로그인", r.status_code == 200, r.text)
    user_token = r.json()["access_token"]
    user_id = r.json()["user"]["id"]
    refresh = r.json()["refresh_token"]

    r = c.post("/api/v1/auth/refresh", json={"refresh_token": refresh})
    check("토큰 갱신", r.status_code == 200 and "access_token" in r.json(), r.text)

    r = c.get("/api/v1/auth/me", headers=bearer(user_token))
    check(
        "내 정보 조회", r.status_code == 200 and r.json()["role"] == "MANAGER", r.text
    )

    r = c.get("/api/v1/users", headers=bearer(user_token))
    check("일반 권한으로 관리자 목록 차단", r.status_code == 403, r.status_code)

    r = c.get("/api/v1/auth/me")
    check("토큰 없이 접근 차단", r.status_code == 401, r.status_code)

    # ============================================================ admin: settings + codes
    print("\n[2] 관리기능: 모듈 설정 / 분류 코드")

    r = c.get("/api/v1/admin/settings/SERVICE", headers=bearer(admin_token))
    check(
        "서비스 설정창 로드",
        r.status_code == 200 and len(r.json()["settings"]) >= 5,
        r.text,
    )
    check(
        "설정창에 분류 코드 동봉",
        len(r.json()["code_groups"]) == 8
        and any(g["code"] == "SERVICE_WORK_TYPE" for g in r.json()["code_groups"]),
        len(r.json()["code_groups"]),
    )

    r = c.put(
        "/api/v1/admin/settings/SERVICE",
        headers=bearer(admin_token),
        json={
            "settings": [
                {
                    "key": "ticket_prefix",
                    "value": "SVC",
                    "value_type": "string",
                    "label": "접수번호 접두어",
                    "is_public": True,
                },
                {
                    "key": "require_result_note",
                    "value": True,
                    "value_type": "bool",
                    "label": "완료 시 처리내용 필수",
                    "is_public": True,
                },
            ]
        },
    )
    check("설정 저장", r.status_code == 200, r.text)
    saved = {s["key"]: s["value"] for s in r.json()["settings"]}
    check("저장값 반영", saved["ticket_prefix"] == "SVC", saved.get("ticket_prefix"))

    # 값은 선언된 타입으로 검증된다 - "3일" 을 정수 자리에 넣으면 접수 등록이 전부 500 이 되던 구멍
    r = c.put(
        "/api/v1/admin/settings/SERVICE",
        headers=bearer(admin_token),
        json={
            "settings": [
                {
                    "key": "default_due_days",
                    "value": "3일",
                    "value_type": "string",
                    "label": "기본 처리 기한(일)",
                    "is_public": True,
                }
            ]
        },
    )
    check(
        "설정값 형식 검증 (정수 자리에 문자열 거절)",
        r.status_code == 400 and r.json()["error"]["code"] == "INVALID_SETTING_VALUE",
        r.text,
    )
    r = c.put(
        "/api/v1/admin/settings/SERVICE",
        headers=bearer(admin_token),
        json={
            "settings": [
                {
                    "key": "default_due_days",
                    "value": "3",
                    "value_type": "string",
                    "label": "기본 처리 기한(일)",
                    "is_public": True,
                },
                {
                    "key": "maker_required_categories",
                    "value": "로봇팔, 제어박스, 전동 그리퍼",
                    "value_type": "string",
                    "label": "제조사 필수",
                    "is_public": True,
                },
            ]
        },
    )
    saved = {s["key"]: s for s in r.json()["settings"]}
    check(
        "문자열로 온 정수·목록은 선언 타입으로 고쳐 저장",
        r.status_code == 200
        and saved["default_due_days"]["value"] == 3
        and saved["default_due_days"]["value_type"] == "int"
        and saved["maker_required_categories"]["value"]
        == ["로봇팔", "제어박스", "전동 그리퍼"],
        r.text,
    )

    r = c.get("/api/v1/admin/codes/SERVICE_CATEGORY", headers=bearer(user_token))
    check(
        "분류 그룹 조회 (구 서버 서비스구분 12종)",
        r.status_code == 200 and len(r.json()["items"]) == 12,
        r.text,
    )
    categories = {i["code"]: i["id"] for i in r.json()["items"]}
    group_id = r.json()["id"]

    r = c.post(
        f"/api/v1/admin/codes/{group_id}/items",
        headers=bearer(admin_token),
        json={
            "code": "EMERGENCY",
            "name": "긴급출동",
            "color": "#DC2626",
            "sort_order": 7,
        },
    )
    check("분류 항목 추가", r.status_code == 201, r.text)

    # --- 항목 삭제 · 되살리기 · 규칙 항목 보호 (2026-09-25)
    r = c.post(
        f"/api/v1/admin/codes/{group_id}/items",
        headers=bearer(admin_token),
        json={"code": "TEMP_DEL", "name": "임시 분류", "sort_order": 99},
    )
    check(
        "삭제 시험용 항목 추가",
        r.status_code == 201 and r.json()["is_protected"] is False,
        r.text,
    )
    temp_id = r.json()["id"]
    r = c.get(f"/api/v1/admin/codes/items/{temp_id}/usage", headers=bearer(admin_token))
    check(
        "항목 사용처 조회 (안 쓰는 항목은 0건)",
        r.status_code == 200
        and r.json()["count"] == 0
        and r.json()["is_protected"] is False,
        r.text,
    )
    r = c.delete(f"/api/v1/admin/codes/items/{temp_id}", headers=bearer(user_token))
    check("일반 사용자는 항목 삭제 불가", r.status_code == 403, r.text)
    r = c.delete(f"/api/v1/admin/codes/items/{temp_id}", headers=bearer(admin_token))
    check(
        "항목 삭제",
        r.status_code == 200 and "삭제했습니다" in r.json()["message"],
        r.text,
    )
    r = c.get("/api/v1/admin/codes/SERVICE_CATEGORY", headers=bearer(user_token))
    check(
        "삭제한 항목은 목록에서 사라짐",
        all(i["code"] != "TEMP_DEL" for i in r.json()["items"]),
        r.text,
    )
    r = c.patch(
        f"/api/v1/admin/codes/items/{temp_id}",
        headers=bearer(admin_token),
        json={"name": "x"},
    )
    check("삭제한 항목은 수정 불가 (404)", r.status_code == 404, r.text)
    r = c.post(
        f"/api/v1/admin/codes/{group_id}/items",
        headers=bearer(admin_token),
        json={"code": "TEMP_DEL", "name": "임시 분류 2", "sort_order": 99},
    )
    check(
        "같은 코드로 다시 추가하면 되살아남 (같은 id)",
        r.status_code == 201
        and r.json()["id"] == temp_id
        and r.json()["name"] == "임시 분류 2",
        r.text,
    )
    c.delete(f"/api/v1/admin/codes/items/{temp_id}", headers=bearer(admin_token))

    r = c.get("/api/v1/admin/codes/ASSET_STATUS", headers=bearer(admin_token))
    statuses = {i["name"]: i for i in r.json()["items"]}
    check(
        "재고 상태 규칙 항목은 보호 표시 (설치·창고 O, 폐기 X)",
        statuses["설치"]["is_protected"]
        and statuses["창고"]["is_protected"]
        and not statuses["폐기"]["is_protected"],
        {k: v["is_protected"] for k, v in statuses.items()},
    )
    r = c.delete(
        f"/api/v1/admin/codes/items/{statuses['설치']['id']}",
        headers=bearer(admin_token),
    )
    check(
        "규칙 항목 삭제 거절 (SYSTEM_ITEM)",
        r.status_code == 400 and r.json()["error"]["code"] == "SYSTEM_ITEM",
        r.text,
    )

    # --- 하위 그룹(증상 → 서비스 분류): 상위 필수 · 같은 축만 (2026-09-25)
    r = c.get("/api/v1/admin/codes/SERVICE_SYMPTOM", headers=bearer(user_token))
    check(
        "증상 그룹은 서비스 분류의 하위 (parent_group_code)",
        r.json()["parent_group_code"] == "SERVICE_CATEGORY",
        r.json().get("parent_group_code"),
    )
    sym_group_id = r.json()["id"]
    check(
        "기본 증상은 모두 상위 분류 아래에 있음",
        len(r.json()["items"]) >= 10 and all(i["parent_id"] for i in r.json()["items"]),
        [i["code"] for i in r.json()["items"] if not i["parent_id"]],
    )
    r = c.post(
        f"/api/v1/admin/codes/{sym_group_id}/items",
        headers=bearer(admin_token),
        json={"code": "TMP_SYM", "name": "임시 증상"},
    )
    check(
        "증상은 상위 없이 추가 불가 (PARENT_REQUIRED)",
        r.status_code == 400 and r.json()["error"]["code"] == "PARENT_REQUIRED",
        r.text,
    )
    r = c.post(
        f"/api/v1/admin/codes/{sym_group_id}/items",
        headers=bearer(admin_token),
        json={
            "code": "TMP_SYM",
            "name": "임시 증상",
            "parent_id": statuses["설치"]["id"],
        },
    )
    check(
        "다른 축의 항목을 상위로 못 씀 (PARENT_MISMATCH)",
        r.status_code == 400 and r.json()["error"]["code"] == "PARENT_MISMATCH",
        r.text,
    )
    r = c.post(
        f"/api/v1/admin/codes/{sym_group_id}/items",
        headers=bearer(admin_token),
        json={
            "code": "TMP_SYM",
            "name": "임시 증상",
            "parent_id": categories["PROGRAM"],
        },
    )
    check(
        "증상 추가 (상위 = 프로그램)",
        r.status_code == 201 and r.json()["parent_id"] == categories["PROGRAM"],
        r.text,
    )
    tmp_sym = r.json()["id"]
    r = c.patch(
        f"/api/v1/admin/codes/items/{tmp_sym}",
        headers=bearer(admin_token),
        json={"parent_id": None},
    )
    check(
        "상위를 비울 수 없음",
        r.status_code == 400 and r.json()["error"]["code"] == "PARENT_REQUIRED",
        r.text,
    )
    r = c.patch(
        f"/api/v1/admin/codes/items/{tmp_sym}",
        headers=bearer(admin_token),
        json={"parent_id": categories["COMM"]},
    )
    check(
        "상위 분류 옮기기",
        r.status_code == 200 and r.json()["parent_id"] == categories["COMM"],
        r.text,
    )
    c.delete(f"/api/v1/admin/codes/items/{tmp_sym}", headers=bearer(admin_token))
    r = c.get("/api/v1/admin/codes/SERVICE_CATEGORY", headers=bearer(user_token))
    check(
        "서비스 분류는 최상위 (parent_group_code 없음)",
        r.json()["parent_group_code"] is None,
        r.text,
    )

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
        [
            ("PROGRAM", "PROGRAM_01"),
            ("PROGRAM", "PROGRAM_02"),
            ("COMM", "COMM_01"),
            ("STRUCTURE", "STRUCTURE_01"),
        ]
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
                "parts": [
                    {"part_name": "메인보드", "quantity": 1, "unit_price": 150000}
                ]
                if i == 0
                else [],
            },
        )
        check(f"AS 접수 #{i + 1}", r.status_code == 201, r.text)
        ticket_ids.append(r.json()["id"])

    first = c.get(
        f"/api/v1/service/tickets/{ticket_ids[0]}", headers=bearer(user_token)
    ).json()
    check(
        "접수번호 채번 (설정 접두어 반영)",
        first["ticket_no"].startswith("SVC-"),
        first["ticket_no"],
    )
    check(
        "담당자 지정 시 상태 ASSIGNED", first["status"] == "ASSIGNED", first["status"]
    )
    check(
        "부품비 자동 합산", float(first["parts_cost"]) == 150000.0, first["parts_cost"]
    )
    check("접수 이력 자동 기록", len(first["logs"]) == 1, first["logs"])
    check("기본 처리기한 자동 설정", first["due_at"] is not None)

    r = c.post(
        f"/api/v1/service/tickets/{ticket_ids[0]}/status",
        headers=bearer(user_token),
        json={"status": "COMPLETED"},
    )
    check(
        "처리내용 없이 완료 차단",
        r.status_code == 400 and r.json()["error"]["code"] == "RESULT_NOTE_REQUIRED",
        r.text,
    )

    # 구 서버 규칙: 종결에는 대응인원이 있어야 한다.
    r = c.get("/api/v1/admin/codes/SERVICE_RESPONDER", headers=bearer(user_token))
    r = c.post(
        f"/api/v1/admin/codes/{r.json()['id']}/items",
        headers=bearer(admin_token),
        json={"code": "KIM", "name": "김테스트", "sort_order": 1},
    )
    check("대응인원 항목 추가", r.status_code == 201, r.text)
    responder_id = r.json()["id"]

    r = c.post(
        f"/api/v1/service/tickets/{ticket_ids[0]}/status",
        headers=bearer(user_token),
        json={"status": "COMPLETED", "result_note": "부품 교체 완료"},
    )
    check(
        "대응인원 없이 종결 차단",
        r.status_code == 400 and r.json()["error"]["code"] == "RESPONDER_REQUIRED",
        r.text,
    )

    for tid in ticket_ids[:3]:
        c.post(
            f"/api/v1/service/tickets/{tid}/status",
            headers=bearer(user_token),
            json={"status": "IN_PROGRESS", "note": "현장 출동"},
        )
        r = c.post(
            f"/api/v1/service/tickets/{tid}/status",
            headers=bearer(user_token),
            json={
                "status": "COMPLETED",
                "result_note": "부품 교체 완료",
                "work_minutes": 90,
                "responder_ids": [responder_id],
            },
        )
        check(
            f"완료 처리 {tid[:8]}",
            r.status_code == 200 and r.json()["status"] == "COMPLETED",
            r.text,
        )
    check(
        "종결 건에 대응인원 기록",
        r.json()["responders"][0]["name"] == "김테스트",
        r.json()["responders"],
    )

    detail = c.get(
        f"/api/v1/service/tickets/{ticket_ids[0]}", headers=bearer(user_token)
    ).json()
    check("완료 시각 기록", detail["completed_at"] is not None)
    check(
        "처리 소요시간 산출",
        detail["resolution_minutes"] is not None,
        detail["resolution_minutes"],
    )
    check("상태 변경 이력 누적", len(detail["logs"]) == 3, len(detail["logs"]))

    r = c.get("/api/v1/service/stats/summary", headers=bearer(user_token))
    s = r.json()
    check("통계 요약 조회", r.status_code == 200, r.text)
    check("총 건수", s["total"] == 4, s["total"])
    check("완료 건수", s["completed_count"] == 3, s["completed_count"])
    check("미완료 건수", s["open_count"] == 1, s["open_count"])
    check("완료율 산출", s["completion_rate"] == 0.75, s["completion_rate"])
    check(
        "평균 처리시간 산출",
        s["avg_resolution_minutes"] is not None,
        s["avg_resolution_minutes"],
    )
    check("상태별 분포", len(s["by_status"]) == 2, s["by_status"])
    check(
        "상태 라벨 한글화",
        {b["label"] for b in s["by_status"]} == {"완료", "배정"},
        s["by_status"],
    )

    r = c.get(
        "/api/v1/service/stats/grouped?group_by=category", headers=bearer(user_token)
    )
    g = r.json()
    check("분류별 집계", r.status_code == 200 and g["total"] == 4, r.text)
    by_cat = {b["label"]: b["count"] for b in g["buckets"]}
    check("프로그램 2건 집계", by_cat.get("프로그램") == 2, by_cat)
    check(
        "비율 산출",
        abs(sum(b["ratio"] for b in g["buckets"]) - 1.0) < 0.01,
        g["buckets"],
    )
    check("분류 색상 전달", any(b["color"] for b in g["buckets"]), g["buckets"])

    for axis in [
        "symptom",
        "cause",
        "action",
        "assignee",
        "priority",
        "channel",
        "status",
    ]:
        r = c.get(
            f"/api/v1/service/stats/grouped?group_by={axis}", headers=bearer(user_token)
        )
        check(f"집계 축 {axis}", r.status_code == 200, r.text)

    r = c.get("/api/v1/service/stats/trend?interval=day", headers=bearer(user_token))
    t = r.json()
    check("일별 추이", r.status_code == 200 and len(t["points"]) >= 1, r.text)
    check(
        "추이 접수/완료 집계",
        t["points"][0]["received"] == 4 and t["points"][0]["completed"] == 3,
        t["points"],
    )

    for iv in ["week", "month"]:
        r = c.get(
            f"/api/v1/service/stats/trend?interval={iv}", headers=bearer(user_token)
        )
        check(
            f"{iv} 추이", r.status_code == 200 and len(r.json()["points"]) >= 1, r.text
        )

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
        json={
            "code": "HQ-2F-A",
            "name": "창고A",
            "type": "ROOM",
            "parent_id": floor_id,
        },
    )
    warehouse_id = r.json()["id"]
    check("3단계 경로", r.json()["path"] == "본사 > 2층 > 창고A", r.json()["path"])

    asset_cats = c.get(
        "/api/v1/admin/codes/ASSET_CATEGORY", headers=bearer(user_token)
    ).json()
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
    check(
        "위치 경로 동봉",
        asset["location"]["path"] == "본사 > 2층 > 창고A",
        asset["location"],
    )

    r = c.post(
        "/api/v1/inventory/assets",
        headers=bearer(user_token),
        json={"name": "위치없음", "category_id": it_cat},
    )
    check(
        "위치 필수 설정 적용",
        r.status_code == 400 and r.json()["error"]["code"] == "LOCATION_REQUIRED",
        r.text,
    )

    r = c.post(
        "/api/v1/inventory/assets",
        headers=bearer(user_token),
        json={
            "name": "토너 카트리지",
            "category_id": it_cat,
            "location_id": warehouse_id,
            "quantity": 2,
            "unit": "EA",
            "min_quantity": 5,
        },
    )
    check("소모품 등록", r.status_code == 201, r.text)
    check(
        "안전재고 미만 감지", r.json()["is_below_min"] is True, r.json()["is_below_min"]
    )

    r = c.post(
        "/api/v1/stores", headers=bearer(admin_token), json={"name": "불출 검사 매장"}
    )
    check("불출 대상 매장 생성", r.status_code == 201, r.text)
    assignment_store_id = r.json()["id"]
    r = c.post(
        f"/api/v1/inventory/assets/{asset_id}/move",
        headers=bearer(user_token),
        json={
            "movement_type": "ASSIGN",
            "to_holder_id": user_id,
            "reason": "매장 설치",
            "to_store_id": assignment_store_id,
        },
    )
    check("자산 불출", r.status_code == 200, r.text)
    check(
        "불출 시 상태 자동 IN_USE", r.json()["status"] == "IN_USE", r.json()["status"]
    )
    check(
        "보관자 반영", r.json()["holder"]["full_name"] == "김테스트", r.json()["holder"]
    )

    r = c.post(
        f"/api/v1/inventory/assets/{asset_id}/move",
        headers=bearer(user_token),
        json={
            "movement_type": "MOVE",
            "to_location_id": floor_id,
            "reason": "사무실 이전",
        },
    )
    check(
        "위치 이동", r.json()["location"]["path"] == "본사 > 2층", r.json()["location"]
    )

    r = c.get(
        f"/api/v1/inventory/assets/{asset_id}/movements", headers=bearer(user_token)
    )
    check("이동 이력 3건 (등록/불출/이동)", r.json()["total"] == 3, r.json()["total"])

    r = c.get(
        f"/api/v1/inventory/assets?location_id={hq_id}", headers=bearer(user_token)
    )
    check("하위 위치 포함 검색", r.json()["total"] == 2, r.json()["total"])
    r = c.get(
        f"/api/v1/inventory/assets?location_id={hq_id}&include_sublocations=false",
        headers=bearer(user_token),
    )
    check("하위 위치 제외 검색", r.json()["total"] == 0, r.json()["total"])

    r = c.get("/api/v1/inventory/locations/tree", headers=bearer(user_token))
    tree = r.json()
    check("위치 트리 조회", r.status_code == 200 and len(tree) == 1, r.text)
    check(
        "트리 중첩 구조", tree[0]["children"][0]["children"][0]["name"] == "창고A", tree
    )

    r = c.get("/api/v1/inventory/summary", headers=bearer(user_token))
    inv = r.json()
    check("재고 요약", r.status_code == 200 and inv["total_assets"] == 2, r.text)
    check("안전재고 경고 집계", inv["below_min_count"] == 1, inv["below_min_count"])
    check("위치별 집계", len(inv["by_location"]) == 2, inv["by_location"])

    r = c.delete(f"/api/v1/inventory/locations/{floor_id}", headers=bearer(user_token))
    check(
        "자산 있는 위치 삭제 차단",
        r.status_code == 400 and r.json()["error"]["code"] == "LOCATION_IN_USE",
        r.text,
    )

    # ============================================================ board
    print("\n[5] 게시판: 설정 -> 글 -> 댓글")

    r = c.get("/api/v1/board/boards", headers=bearer(user_token))
    boards = {b["code"]: b for b in r.json()}
    check(
        "기본 게시판 시드",
        set(boards) == {"NOTICE", "FREE", "QNA", "ARCHIVE"},
        list(boards),
    )
    check("공지 게시판 쓰기권한 ADMIN", boards["NOTICE"]["write_role"] == "ADMIN")
    check("기존 게시판 기본 아이콘", all(b["icon"] == "auto" for b in boards.values()))
    r = c.post("/api/v1/board/boards", headers=bearer(admin_token),
               json={"code": "ICON_TEST", "name": "아이콘 검증", "icon": "equipment"})
    check("아이콘 선택 게시판 생성", r.status_code == 201 and r.json()["icon"] == "equipment", r.text)
    icon_board_id = r.json()["id"]
    r = c.patch(f"/api/v1/board/boards/{icon_board_id}", headers=bearer(admin_token), json={"icon": "calendar"})
    check("게시판 아이콘 변경", r.status_code == 200 and r.json()["icon"] == "calendar", r.text)
    r = c.get("/api/v1/board/boards", headers=bearer(user_token))
    check("아이콘 저장 조회", any(b["id"] == icon_board_id and b["icon"] == "calendar" for b in r.json()))
    for icon in ["unknown", None]:
        r = c.patch(f"/api/v1/board/boards/{icon_board_id}", headers=bearer(admin_token), json={"icon": icon})
        check("잘못된 아이콘 차단", r.status_code == 422, r.text)
    r = c.patch(f"/api/v1/board/boards/{icon_board_id}", headers=bearer(user_token), json={"icon": "chat"})
    check("일반 사용자 아이콘 설정 차단", r.status_code == 403, r.text)
    c.delete(f"/api/v1/board/boards/{icon_board_id}", headers=bearer(admin_token))


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
    check(
        "작성자 정보 동봉",
        r.json()["author"]["full_name"] == "김테스트",
        r.json()["author"],
    )

    r = c.post(
        f"/api/v1/board/posts/{post_id}/comments",
        headers=bearer(admin_token),
        json={"content": "확인했습니다"},
    )
    check("댓글 작성", r.status_code == 200, r.text)

    r = c.get(f"/api/v1/board/posts/{post_id}", headers=bearer(admin_token))
    check("댓글 수 반영", r.json()["comment_count"] == 1, r.json()["comment_count"])
    check(
        "댓글 본문 조회",
        r.json()["comments"][0]["content"] == "확인했습니다",
        r.json()["comments"],
    )
    check("조회수 증가", r.json()["view_count"] == 1, r.json()["view_count"])

    r = c.get(
        "/api/v1/calendar/notifications?unread_only=true", headers=bearer(user_token)
    )
    titles = [n["title"] for n in r.json()["items"]]
    check("내 글 댓글 알림 수신", "내 글에 댓글이 달렸습니다" in titles, titles)

    r = c.patch(
        f"/api/v1/board/boards/{boards['FREE']['id']}",
        headers=bearer(admin_token),
        json={"allow_comment": False, "page_size": 50},
    )
    check(
        "게시판 설정 변경", r.status_code == 200 and r.json()["page_size"] == 50, r.text
    )

    r = c.post(
        f"/api/v1/board/posts/{post_id}/comments",
        headers=bearer(admin_token),
        json={"content": "막혔나?"},
    )
    check(
        "댓글 비허용 설정 적용",
        r.status_code == 400 and r.json()["error"]["code"] == "COMMENT_NOT_ALLOWED",
        r.text,
    )

    # ============================================================ calendar
    print("\n[6] 캘린더: 일정 공유 -> 참석자 -> 알림")

    r = c.get("/api/v1/calendar/calendars", headers=bearer(user_token))
    check("공유 캘린더 공유", r.status_code == 200 and len(r.json()) == 1, r.text)
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
    check(
        "알림 시각 = 시작 30분 전",
        event["reminders"][0]["offset_minutes"] == 30,
        event["reminders"],
    )

    # ---- 기기 로컬 알람 예약 목록 (오프라인에서도 울려야 하므로 필요) ----
    r = c.get("/api/v1/calendar/reminders/upcoming?days=7", headers=bearer(user_token))
    check("예정 알람 목록 조회", r.status_code == 200, r.text)
    alarms = r.json()
    check("내가 만든 일정의 알람이 포함", len(alarms) >= 1, alarms)
    alarm = next(x for x in alarms if x["event_id"] == event_id)
    check("알람에 울릴 시각 포함", alarm["scheduled_at"] is not None, alarm)
    check("알람에 일정 제목 포함", alarm["title"] == "주간 업무 회의", alarm["title"])
    check("알람에 장소 포함", alarm["location"] == "대회의실", alarm.get("location"))
    check(
        "알람에 색상 포함 (일정 또는 캘린더)",
        alarm["color"] is not None,
        alarm.get("color"),
    )
    check("알람 리드타임 30분", alarm["offset_minutes"] == 30, alarm["offset_minutes"])

    r = c.get("/api/v1/calendar/reminders/upcoming?days=7", headers=bearer(admin_token))
    check(
        "참석자에게도 같은 알람이 내려감",
        any(x["event_id"] == event_id for x in r.json()),
        r.json(),
    )

    r = c.get(
        "/api/v1/calendar/notifications?unread_only=true", headers=bearer(admin_token)
    )
    titles = [n["title"] for n in r.json()["items"]]
    check("참석자에게 초대 알림", "[일정 초대] 주간 업무 회의" in titles, titles)

    r = c.post(
        f"/api/v1/calendar/events/{event_id}/respond",
        headers=bearer(admin_token),
        json={"response": "ACCEPTED"},
    )
    check(
        "참석 응답", r.status_code == 200 and r.json()["response"] == "ACCEPTED", r.text
    )

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
    check(
        "알림 재계산",
        r.json()["reminders"][0]["sent_at"] is None,
        r.json()["reminders"],
    )
    # 사용자가 정한 알림은 시각만 바꿔도 남아야 한다
    r = c.patch(
        f"/api/v1/calendar/events/{event_id}",
        headers=bearer(user_token),
        json={
            "reminders": [
                {"offset_minutes": 10, "method": "PUSH"},
                {"offset_minutes": 60, "method": "INAPP"},
            ]
        },
    )
    check(
        "알림 두 개로 변경",
        r.status_code == 200 and len(r.json()["reminders"]) == 2,
        r.text,
    )
    r = c.patch(
        f"/api/v1/calendar/events/{event_id}",
        headers=bearer(user_token),
        json={"starts_at": utc(minutes=6), "ends_at": utc(minutes=66)},
    )
    offsets = sorted(x["offset_minutes"] for x in r.json()["reminders"])
    check("시각만 바꿔도 기존 알림 유지", offsets == [10, 60], r.json()["reminders"])
    # 뒤의 스윕 검사(1건 발송)를 위해 기본 알림 하나로 되돌린다
    r = c.patch(
        f"/api/v1/calendar/events/{event_id}",
        headers=bearer(user_token),
        json={
            "starts_at": utc(minutes=5),
            "ends_at": utc(minutes=65),
            "reminders": [{"offset_minutes": 30, "method": "PUSH"}],
        },
    )
    check("알림 하나로 되돌림", len(r.json()["reminders"]) == 1, r.json()["reminders"])

    r = c.post("/api/v1/calendar/reminders/run", headers=bearer(admin_token))
    check(
        "알림 스윕 실행", r.status_code == 200 and "1건" in r.json()["message"], r.text
    )

    r = c.get(
        "/api/v1/calendar/notifications?unread_only=true", headers=bearer(admin_token)
    )
    titles = [n["title"] for n in r.json()["items"]]
    check("일정 알림 도착", "[일정 알림] 주간 업무 회의" in titles, titles)

    r = c.get("/api/v1/calendar/reminders/upcoming?days=7", headers=bearer(user_token))
    remaining = [x["reminder_id"] for x in r.json()]
    check(
        "이미 발송된 알람은 예약 목록에서 빠짐",
        alarm["reminder_id"] not in remaining,
        f"기기에서 중복으로 울리면 안 된다 (남은 것: {remaining})",
    )

    r = c.get("/api/v1/calendar/notifications/count", headers=bearer(admin_token))
    unread = r.json()["unread"]
    check("미읽음 카운트", unread >= 3, unread)

    r = c.post("/api/v1/calendar/notifications/read-all", headers=bearer(admin_token))
    check("전체 읽음 처리", r.status_code == 200, r.text)
    check(
        "카운트 0",
        c.get(
            "/api/v1/calendar/notifications/count", headers=bearer(admin_token)
        ).json()["unread"]
        == 0,
    )

    r = c.post(
        "/api/v1/calendar/calendars",
        headers=bearer(user_token),
        json={"name": "내 개인 일정", "type": "PERSONAL", "color": "#8B5CF6"},
    )
    check("개인 캘린더 생성", r.status_code == 201, r.text)
    personal_id = r.json()["id"]

    r = c.get("/api/v1/calendar/calendars", headers=bearer(admin_token))
    check(
        "남의 개인 캘린더는 안 보임",
        personal_id not in [x["id"] for x in r.json()],
        r.json(),
    )

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
    check(
        "본인 개인 캘린더 수정",
        r.status_code == 200 and r.json()["name"] == "내 일정(수정)",
        r.text,
    )

    r = c.delete(f"/api/v1/calendar/calendars/{cal_id}", headers=bearer(admin_token))
    check("공유 캘린더 삭제 차단", r.status_code == 400, r.status_code)

    r = c.delete(
        f"/api/v1/calendar/calendars/{personal_id}", headers=bearer(user_token)
    )
    check("개인 캘린더 삭제", r.status_code == 200, r.text)

    r = c.post(
        "/api/v1/calendar/notifications/broadcast",
        headers=bearer(admin_token),
        json={"title": "서버 점검 안내", "body": "금요일 22시"},
    )
    check(
        "전체 공지 발송", r.status_code == 200 and "2명" in r.json()["message"], r.text
    )
    r = c.delete("/api/v1/calendar/notifications", headers=bearer(user_token))
    check("알림 초기화", r.status_code == 200, r.text)
    check(
        "내 알림만 지워짐",
        c.get("/api/v1/calendar/notifications", headers=bearer(user_token)).json()[
            "total"
        ]
        == 0
        and c.get(
            "/api/v1/calendar/notifications", headers=bearer(admin_token)
        ).json()["total"]
        > 0,
    )

    # ============================================================ worklog
    print("\n[6b] 근무일지: 규칙 · 임시 저장 · 공개 범위 · 엑셀")

    r = c.get("/api/v1/worklogs/lookups", headers=bearer(user_token))
    check(
        "근무일지 기본값",
        r.status_code == 200
        and r.json()["default_work_start"] == "09:00"
        and "대리" in r.json()["positions"],
        r.text,
    )
    check("계정 직급 없음 → 폼에서 고름", r.json()["fixed_position"] is None)

    r = c.put(
        "/api/v1/worklogs/draft",
        headers=bearer(user_token),
        json={"data": {"summary": "쓰다 만 것", "work_date": "2026-09-25"}},
    )
    check(
        "임시 저장",
        r.status_code == 200 and r.json()["data"]["summary"] == "쓰다 만 것",
        r.text,
    )
    r = c.get("/api/v1/worklogs/lookups", headers=bearer(user_token))
    check(
        "기본값에 임시 저장 동봉",
        r.json()["draft"]["data"]["summary"] == "쓰다 만 것",
        r.json()["draft"],
    )

    body = {
        "work_date": "2026-09-25",
        "work_start": "09:00",
        "work_end": "18:00",
        "summary": "강남역점 점검\n- 신규 매장 설치 준비\n\n3) 창고 정리",
        "detail": "시간 순서대로 한 일",
        "overtime": False,
        "overtime_note": "지워져야 함",
        "plan": "내일 할 일",
        "visibility": "PRIVATE",
    }
    r = c.post("/api/v1/worklogs", headers=bearer(user_token), json=body)
    check(
        "직급 없으면 거절",
        r.status_code == 400 and r.json()["error"]["code"] == "POSITION_REQUIRED",
        r.text,
    )
    r = c.post(
        "/api/v1/worklogs",
        headers=bearer(user_token),
        json={**body, "position": "대리"},
    )
    check("근무일지 등록", r.status_code == 201, r.text)
    wl = r.json()
    check(
        "요약 자동 번호",
        wl["summary"] == "1. 강남역점 점검\n2. 신규 매장 설치 준비\n3. 창고 정리",
        wl["summary"],
    )
    check(
        "18:00 까지면 연장 아님 + 사유 비움",
        wl["overtime"] is False
        and wl["overtime_minutes"] == 0
        and wl["overtime_note"] is None,
        wl,
    )
    check(
        "작성자 = 로그인 사용자",
        wl["author_name"] == "김테스트" and wl["can_edit"] is True,
        wl,
    )
    r = c.get("/api/v1/worklogs/draft", headers=bearer(user_token))
    check("등록하면 임시 저장 삭제", r.json() is None, r.text)

    r = c.post(
        "/api/v1/worklogs",
        headers=bearer(user_token),
        json={**body, "position": "대리"},
    )
    check(
        "같은 날 두 장 거절 + 기존 id",
        r.status_code == 409 and r.json()["error"]["details"]["id"] == wl["id"],
        r.text,
    )
    r = c.post(
        "/api/v1/worklogs",
        headers=bearer(user_token),
        json={**body, "position": "대리", "work_start": "9:00"},
    )
    check(
        "근무시간 형식",
        r.status_code == 422
        or (r.status_code == 400 and r.json()["error"]["code"] == "BAD_TIME"),
        r.text,
    )

    r = c.get(f"/api/v1/worklogs/{wl['id']}", headers=bearer(admin_token))
    check("관리자는 비공개도 봄", r.status_code == 200, r.text)
    # 열람 고정: 작성자, 같은 부서 팀장, 관리자만. 일반 사원은 남의 일지를 못 본다.
    r = c.post(
        "/api/v1/auth/signup",
        json={
            "email": "peer@ddeck.local",
            "password": "peerpass1",
            "full_name": "동료",
        },
    )
    peer_id = r.json().get("id") or next(
        u["id"]
        for u in c.get("/api/v1/users/pending", headers=bearer(admin_token)).json()[
            "items"
        ]
        if u["email"] == "peer@ddeck.local"
    )
    c.post(
        f"/api/v1/users/{peer_id}/approve",
        headers=bearer(admin_token),
        json={"role": "MEMBER"},
    )
    peer_token = c.post(
        "/api/v1/auth/login",
        json={"email": "peer@ddeck.local", "password": "peerpass1"},
    ).json()["access_token"]
    r = c.get(f"/api/v1/worklogs/{wl['id']}", headers=bearer(peer_token))
    check("다른 일반 사원은 못 봄", r.status_code == 403, r.status_code)
    r = c.get(f"/api/v1/worklogs/{wl['id']}/pdf", headers=bearer(user_token))
    check(
        "근무일지 PDF 다운로드",
        r.status_code == 200
        and r.headers["content-type"] == "application/pdf"
        and r.content.startswith(b"%PDF"),
        r.status_code,
    )
    r = c.get(f"/api/v1/worklogs/{wl['id']}/pdf", headers=bearer(peer_token))
    check("다른 일반 사원 PDF 차단", r.status_code == 403, r.status_code)
    # 첨부도 본문 규칙을 따른다 (id 만 알면 열리던 구멍)
    r = c.post(
        "/api/v1/files",
        headers=bearer(user_token),
        data={"entity_type": "worklog", "entity_id": wl["id"]},
        files={"file": ("메모.txt", b"hello", "text/plain")},
    )
    check("근무일지 첨부 업로드", r.status_code == 201, r.text)
    att_id = r.json()["id"]
    r = c.get(f"/api/v1/files/by-entity/worklog/{wl['id']}", headers=bearer(peer_token))
    check("다른 일반 사원 첨부 목록 차단", r.status_code == 403, r.status_code)
    r = c.get(f"/api/v1/files/{att_id}", headers=bearer(peer_token))
    check("다른 일반 사원 첨부 다운로드 차단", r.status_code == 403, r.status_code)
    r = c.post(
        "/api/v1/files",
        headers=bearer(peer_token),
        data={"entity_type": "worklog", "entity_id": wl["id"]},
        files={"file": ("x.txt", b"x", "text/plain")},
    )
    check("남의 일지에 첨부 추가 차단", r.status_code == 403, r.status_code)
    r = c.post(
        "/api/v1/files",
        headers=bearer(peer_token),
        data={"entity_type": "service_ticket", "entity_id": str(uuid.uuid4())},
        files={"file": ("x.txt", b"x", "text/plain")},
    )
    check("없는 대상에 첨부 차단", r.status_code == 404, r.status_code)
    r = c.post(
        "/api/v1/files",
        headers=bearer(peer_token),
        data={"entity_type": "user", "entity_id": user_id},
        files={"file": ("x.txt", b"x", "text/plain")},
    )
    check("남의 계정에 첨부 차단", r.status_code == 403, r.status_code)
    r = c.get(f"/api/v1/files/{att_id}", headers=bearer(user_token))
    check(
        "작성자는 첨부 내려받기",
        r.status_code == 200 and r.content == b"hello",
        r.status_code,
    )
    r = c.get("/api/v1/worklogs?scope=team", headers=bearer(peer_token))
    check("일반 사원 목록에 남의 일지 없음", r.json()["total"] == 0, r.json())
    r = c.patch(
        f"/api/v1/worklogs/{wl['id']}",
        headers=bearer(user_token),
        json={"work_start": "08:00", "work_end": "20:30"},
    )
    check(
        "18:00 이후 근무는 연장 사유 필수",
        r.status_code == 400
        and r.json()["error"]["code"] == "OVERTIME_REASON_REQUIRED",
        r.text,
    )
    r = c.patch(
        f"/api/v1/worklogs/{wl['id']}",
        headers=bearer(user_token),
        json={
            "visibility": "TEAM",  # 공개 범위는 고정이라 무시된다
            "work_start": "08:00",
            "work_end": "20:30",
            "overtime": False,
            "overtime_note": "18:00~20:30 출동",
        },
    )
    check(
        "공개 범위 요청 무시 + 자동 연장 (09:00 이전은 제외)",
        r.status_code == 200
        and r.json()["visibility"] == "PRIVATE"
        and r.json()["overtime"] is True
        and r.json()["overtime_minutes"] == 150
        and r.json()["overtime_note"] == "18:00~20:30 출동",
        r.text,
    )
    r = c.get(
        "/api/v1/worklogs/overtime-summary?year=2026&month=9",
        headers=bearer(user_token),
    )
    check(
        "연장 근무 월 종합",
        r.status_code == 200
        and r.json()["total_minutes"] == 150
        and [(i["work_date"], i["minutes"], i["reason"]) for i in r.json()["items"]]
        == [("2026-09-25", 150, "18:00~20:30 출동")],
        r.text,
    )
    r = c.get(
        "/api/v1/worklogs/overtime-summary?year=2026&month=9",
        headers=bearer(peer_token),
    )
    check("연장 종합은 내 일지만", r.json()["total_minutes"] == 0, r.text)
    r = c.get(
        "/api/v1/worklogs/overtime-summary.pdf?year=2026&month=9",
        headers=bearer(user_token),
    )
    check(
        "연장 근무 종합 PDF",
        r.status_code == 200 and r.content.startswith(b"%PDF"),
        r.status_code,
    )
    r = c.get(f"/api/v1/worklogs/{wl['id']}", headers=bearer(peer_token))
    check("팀 공개 요청해도 일반 사원은 못 봄", r.status_code == 403, r.status_code)

    def leader(email: str, department: str | None) -> str:
        r = c.post(
            "/api/v1/auth/signup",
            json={"email": email, "password": "leadpass1", "full_name": email[:6]},
        )
        leader_id = r.json().get("id") or next(
            u["id"]
            for u in c.get(
                "/api/v1/users/pending", headers=bearer(admin_token)
            ).json()["items"]
            if u["email"] == email
        )
        c.post(
            f"/api/v1/users/{leader_id}/approve",
            headers=bearer(admin_token),
            json={"role": "MANAGER", "department_id": department},
        )
        return c.post(
            "/api/v1/auth/login", json={"email": email, "password": "leadpass1"}
        ).json()["access_token"]

    r = c.patch(
        f"/api/v1/users/{user_id}",
        headers=bearer(admin_token),
        json={"department_id": dept_id},
    )
    check("작성자 부서 지정", r.status_code == 200, r.text)
    other_dept = c.post(
        "/api/v1/admin/departments",
        headers=bearer(admin_token),
        json={"name": "영업팀", "code": "SALES"},
    ).json()["id"]
    lead_token = leader("lead1@ddeck.local", dept_id)
    other_lead_token = leader("lead2@ddeck.local", other_dept)
    r = c.get(f"/api/v1/worklogs/{wl['id']}", headers=bearer(lead_token))
    check(
        "같은 부서 팀장은 봄 (수정 불가)",
        r.status_code == 200 and r.json()["can_edit"] is False,
        r.text,
    )
    r = c.get(f"/api/v1/worklogs/{wl['id']}", headers=bearer(other_lead_token))
    check("다른 부서 팀장은 못 봄", r.status_code == 403, r.status_code)
    r = c.get(f"/api/v1/worklogs/{wl['id']}/pdf", headers=bearer(lead_token))
    check("같은 부서 팀장 PDF", r.status_code == 200, r.status_code)
    r = c.get(f"/api/v1/files/by-entity/worklog/{wl['id']}", headers=bearer(lead_token))
    check(
        "같은 부서 팀장은 첨부 목록도 보임",
        r.status_code == 200 and len(r.json()) == 1,
        r.text,
    )
    r = c.get(
        f"/api/v1/files/by-entity/worklog/{wl['id']}", headers=bearer(other_lead_token)
    )
    check("다른 부서 팀장 첨부 차단", r.status_code == 403, r.status_code)
    r = c.post(
        "/api/v1/files",
        headers=bearer(lead_token),
        data={"entity_type": "worklog", "entity_id": wl["id"]},
        files={"file": ("x.txt", b"x", "text/plain")},
    )
    check("팀장이라도 남의 일지에 첨부 추가는 차단", r.status_code == 403, r.status_code)
    r = c.patch(
        f"/api/v1/worklogs/{wl['id']}",
        headers=bearer(lead_token),
        json={"detail": "가로채기"},
    )
    check("팀장이라도 남의 일지 수정 차단", r.status_code == 403, r.status_code)
    r = c.get("/api/v1/worklogs?scope=team", headers=bearer(lead_token))
    check(
        "같은 부서 팀장 목록에 부서원 일지",
        r.json()["total"] == 1 and r.json()["items"][0]["attachment_count"] == 1,
        r.json(),
    )
    r = c.get("/api/v1/worklogs?scope=team", headers=bearer(other_lead_token))
    check("다른 부서 팀장 목록에 없음", r.json()["total"] == 0, r.json())
    r = c.get(
        "/api/v1/worklogs?year=2026&month=9&overtime=true&q=강남",
        headers=bearer(user_token),
    )
    check("근무일지 검색 조건", r.json()["total"] == 1, r.json())
    r = c.get("/api/v1/worklogs/export.xlsx?scope=mine", headers=bearer(user_token))
    check(
        "근무일지 엑셀",
        r.status_code == 200 and "spreadsheetml" in r.headers["content-type"],
        r.headers,
    )
    r = c.delete(f"/api/v1/worklogs/{wl['id']}", headers=bearer(peer_token))
    check("남의 일지 삭제 차단", r.status_code == 403, r.status_code)
    r = c.delete(f"/api/v1/worklogs/{wl['id']}", headers=bearer(admin_token))
    check("관리자 삭제", r.status_code == 200, r.text)

    # ============================================================ board privacy
    print("\n[6c] 게시판: 비밀글 · 임시/숨김 글은 id 만 알아도 못 본다")

    qna = boards["QNA"]
    r = c.post(
        f"/api/v1/board/boards/{qna['id']}/posts",
        headers=bearer(admin_token),
        json={
            "title": "급여 문의 비밀글",
            "content": "비밀 본문 내용",
            "is_secret": True,
        },
    )
    check("비밀글 작성", r.status_code == 201, r.text)
    secret_id = r.json()["id"]
    r = c.get(f"/api/v1/board/posts/{secret_id}", headers=bearer(peer_token))
    check("남의 비밀글 열람 차단", r.status_code == 403, r.status_code)
    r = c.post(
        f"/api/v1/board/posts/{secret_id}/comments",
        headers=bearer(peer_token),
        json={"content": "끼어들기"},
    )
    check("남의 비밀글에 댓글 차단", r.status_code == 403, r.status_code)
    r = c.get(f"/api/v1/board/boards/{qna['id']}/posts", headers=bearer(peer_token))
    check(
        "목록에서 권한 없는 비밀글 제외",
        all(p["id"] != secret_id for p in r.json()["items"]),
        r.json(),
    )
    r = c.get(
        f"/api/v1/board/boards/{qna['id']}/posts?q=급여", headers=bearer(peer_token)
    )
    check("남의 비밀글은 검색되지 않음", r.json()["total"] == 0, r.json())
    r = c.get(
        f"/api/v1/board/boards/{qna['id']}/posts?q=급여", headers=bearer(admin_token)
    )
    check(
        "작성자는 비밀글 검색됨",
        r.json()["total"] == 1 and r.json()["items"][0]["title"] == "급여 문의 비밀글",
        r.json(),
    )
    r = c.post(
        f"/api/v1/board/boards/{qna['id']}/posts",
        headers=bearer(admin_token),
        json={"title": "쓰다 만 글", "content": "초안", "status": "DRAFT"},
    )
    draft_id = r.json()["id"]
    r = c.get(f"/api/v1/board/posts/{draft_id}", headers=bearer(peer_token))
    check("남의 임시 글은 없는 글처럼 404", r.status_code == 404, r.status_code)
    r = c.post(
        f"/api/v1/board/posts/{draft_id}/comments",
        headers=bearer(peer_token),
        json={"content": "x"},
    )
    check("임시 글에 댓글 차단", r.status_code == 404, r.status_code)
    r = c.get(f"/api/v1/board/posts/{draft_id}", headers=bearer(admin_token))
    check("작성자는 임시 글 열람", r.status_code == 200, r.status_code)
    r = c.patch(
        f"/api/v1/board/posts/{secret_id}",
        headers=bearer(admin_token),
        json={"status": "HIDDEN"},
    )
    r = c.get(f"/api/v1/board/posts/{secret_id}", headers=bearer(peer_token))
    check("숨김 글 404", r.status_code == 404, r.status_code)

    # ============================================================ admin ops
    print("\n[7] 관리기능: 상태 / 통계 / 감사로그")

    r = c.get("/api/v1/admin/health", headers=bearer(admin_token))
    check("헬스체크", r.status_code == 200 and r.json()["database_ok"] is True, r.text)
    check("DB 종류 노출", r.json()["database"] == "sqlite", r.json()["database"])

    r = c.get("/api/v1/admin/stats", headers=bearer(admin_token))
    st = r.json()
    check("시스템 통계", r.status_code == 200, r.text)
    check(
        "계정 수 (관리자·김테스트·동료·팀장 2)",
        st["users_active"] == 5,
        st["users_active"],
    )
    check("AS 건수", st["tickets_total"] == 4, st["tickets_total"])
    check("자산 건수", st["assets_total"] == 2, st["assets_total"])
    check("테이블 목록", len(st["tables"]) == 32, len(st["tables"]))

    r = c.get(
        f"/api/v1/admin/codes/items/{categories['PROGRAM']}/usage",
        headers=bearer(admin_token),
    )
    check(
        "쓰이는 항목의 사용처 (프로그램 → 대응 기록 2건 이상)",
        r.status_code == 200 and r.json()["by"].get("대응 기록", 0) >= 2,
        r.text,
    )
    r = c.delete(
        f"/api/v1/admin/codes/items/{categories['PROGRAM']}",
        headers=bearer(admin_token),
    )
    check(
        "쓰이는 항목도 삭제되며 기존 기록 건수를 알려 줌",
        r.status_code == 200 and "기존 기록" in r.json()["message"],
        r.text,
    )
    r = c.get(f"/api/v1/service/tickets/{ticket_ids[0]}", headers=bearer(user_token))
    check(
        "삭제한 분류를 쓰던 기록은 이름을 유지",
        r.status_code == 200
        and r.json()["causes"][0]["category"]["name"] == "프로그램",
        r.text,
    )
    r = c.post(
        f"/api/v1/admin/codes/{group_id}/items",
        headers=bearer(admin_token),
        json={"code": "PROGRAM", "name": "프로그램", "sort_order": 10},
    )
    check(
        "삭제한 분류를 같은 코드로 되살림",
        r.status_code == 201 and r.json()["id"] == categories["PROGRAM"],
        r.text,
    )
    r = c.get("/api/v1/admin/codes/SERVICE_SYMPTOM", headers=bearer(user_token))
    check(
        "분류를 되살리면 함께 지워졌던 증상도 돌아옴",
        any(i["code"] == "PROGRAM_01" for i in r.json()["items"]),
        [i["code"] for i in r.json()["items"]],
    )

    r = c.get("/api/v1/admin/audit-logs?size=100", headers=bearer(admin_token))
    logs = r.json()
    check("감사로그 조회", r.status_code == 200 and len(logs) > 5, len(logs))
    actions = {log["action"] for log in logs}
    check("로그인 기록", "LOGIN" in actions, actions)
    check("승인 기록", "APPROVE" in actions, actions)
    check("설정변경 기록", "SETTING_CHANGE" in actions, actions)

    r = c.get("/api/v1/admin/audit-logs?action=APPROVE", headers=bearer(admin_token))
    check(
        "감사로그 필터 (승인 4건: 김테스트·동료·팀장 2)",
        len(r.json()) == 4 and all("가입 승인" in x["summary"] for x in r.json()),
        r.json(),
    )

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

    c.patch(
        f"/api/v1/users/{user_id}",
        headers=bearer(admin_token),
        json={"status": "APPROVED"},
    )
    r = c.post("/api/v1/auth/login", json={"email": email, "password": "wrong-pass-1"})
    check("오답 로그인 거절", r.status_code == 401, r.status_code)

    r = c.post(
        f"/api/v1/users/{admin_id}/approve",
        headers=bearer(admin_token),
        json={"role": "MEMBER"},
    )
    check("이미 승인된 계정 재승인 차단", r.status_code == 400, r.status_code)

    # Regression: logs must not bypass completion rules, or mutate on failure.
    r = c.post(
        "/api/v1/service/tickets",
        headers=bearer(admin_token),
        json={"title": "상태 경로 회귀 검사", "category_id": categories["PROGRAM"]},
    )
    check("회귀 검사 접수 생성", r.status_code == 201, r.text)
    regression_id = r.json()["id"]
    path = f"/api/v1/service/tickets/{regression_id}"
    before_log = r.json()
    r = c.post(
        f"{path}/logs",
        headers=bearer(admin_token),
        json={"content": "우회 종결", "to_status": "COMPLETED", "work_minutes": 12},
    )
    check(
        "logs 종결도 대응 내용 필수",
        r.status_code == 400 and r.json()["error"]["code"] == "RESULT_NOTE_REQUIRED",
        r.text,
    )
    detail = c.get(path, headers=bearer(admin_token)).json()
    check(
        "실패한 logs 요청은 상태·시간·이력 보존",
        detail["status"] == before_log["status"]
        and detail["work_minutes"] == before_log["work_minutes"]
        and len(detail["logs"]) == len(before_log["logs"]),
        detail,
    )
    r = c.patch(path, headers=bearer(admin_token), json={"result_note": "조치 완료"})
    check("종결 내용 준비", r.status_code == 200, r.text)
    r = c.post(
        f"{path}/logs",
        headers=bearer(admin_token),
        json={"content": "인원 없이 종결", "to_status": "COMPLETED"},
    )
    check(
        "logs 종결도 대응인원 필수",
        r.status_code == 400 and r.json()["error"]["code"] == "RESPONDER_REQUIRED",
        r.text,
    )
    r = c.patch(
        path, headers=bearer(admin_token), json={"responder_ids": [responder_id]}
    )
    check("종결 인원 준비", r.status_code == 200, r.text)
    r = c.post(
        f"{path}/logs",
        headers=bearer(admin_token),
        json={"content": "종결 기록", "to_status": "COMPLETED", "work_minutes": 12},
    )
    check(
        "logs 정상 종결",
        r.status_code == 200 and r.json()["to_status"] == "COMPLETED",
        r.text,
    )
    detail = c.get(path, headers=bearer(admin_token)).json()
    check(
        "logs 종결 시각·시간·이력 동기화",
        detail["completed_at"] is not None
        and detail["work_minutes"] == 12
        and len(detail["logs"]) == 2,
        detail,
    )
    r = c.get(
        "/api/v1/admin/audit-logs",
        headers=bearer(admin_token),
        params={"q": detail["ticket_no"]},
    )
    check(
        "logs 상태 변경 감사 기록",
        r.status_code == 200 and any("상태 변경" in row["summary"] for row in r.json()),
        r.text,
    )
    r = c.post(
        f"{path}/logs",
        headers=bearer(admin_token),
        json={"content": "일반 댓글", "work_minutes": 3},
    )
    check(
        "일반 댓글 추가", r.status_code == 200 and r.json()["to_status"] is None, r.text
    )
    detail = c.get(path, headers=bearer(admin_token)).json()
    check(
        "일반 댓글 상태 보존·작업시간 1회 합산",
        detail["status"] == "COMPLETED" and detail["work_minutes"] == 15,
        detail,
    )
    r = c.delete(path, headers=bearer(admin_token))
    check("접수 삭제", r.status_code == 200, r.text)
    r = c.get(path, headers=bearer(admin_token))
    check("삭제된 접수 상세 조회 차단", r.status_code == 404, r.text)
    r = c.post(
        f"{path}/logs", headers=bearer(admin_token), json={"content": "삭제 후 댓글"}
    )
    check("삭제된 접수 댓글 차단", r.status_code == 404, r.text)

    # ---- 계정 삭제 (관리자): 본인 · 마지막 관리자는 못 지운다 (구 서버 규칙) ----
    r = c.delete(f"/api/v1/users/{admin_id}", headers=bearer(admin_token))
    check(
        "본인 계정 삭제 차단",
        r.status_code == 400 and r.json()["error"]["code"] == "CANNOT_DELETE_SELF",
        r.text,
    )
    r = c.delete(f"/api/v1/users/{user_id}", headers=bearer(admin_token))
    check("팀원 계정 삭제", r.status_code == 200, r.text)
    r = c.get(f"/api/v1/users/{user_id}", headers=bearer(admin_token))
    check("삭제된 계정은 조회되지 않음", r.status_code == 404, r.status_code)
    r = c.post("/api/v1/auth/login", json={"email": email, "password": "test1234"})
    check("삭제된 계정 로그인 차단", r.status_code in (401, 403), r.status_code)
    r = c.get("/api/v1/users?size=100", headers=bearer(admin_token))
    admins = [
        u
        for u in r.json()["items"]
        if u["role"] in ("ADMIN", "SUPERADMIN") and u["status"] == "APPROVED"
    ]
    check("남은 관리자 1명", len(admins) == 1, admins)
    # 다른 관리자로 마지막 관리자를 지우려 해도 막힌다: 임시 관리자를 만들어 시험
    r = c.post(
        "/api/v1/auth/signup",
        json={
            "email": "admin2@ddeck.local",
            "password": "admin2pass1",
            "full_name": "임시관리자",
        },
    )
    tmp_id = r.json()["id"] if r.status_code == 201 and "id" in r.json() else None
    if tmp_id is None:
        tmp_id = next(
            u["id"]
            for u in c.get("/api/v1/users/pending", headers=bearer(admin_token)).json()[
                "items"
            ]
            if u["email"] == "admin2@ddeck.local"
        )
    c.post(
        f"/api/v1/users/{tmp_id}/approve",
        headers=bearer(admin_token),
        json={"role": "ADMIN"},
    )
    r = c.post(
        "/api/v1/auth/login",
        json={"email": "admin2@ddeck.local", "password": "admin2pass1"},
    )
    check("임시 관리자 로그인", r.status_code == 200, r.text)
    tmp_token = r.json()["access_token"]
    r = c.delete(f"/api/v1/users/{admin_id}", headers=bearer(tmp_token))
    check("일반 관리자는 최고 관리자를 못 지움", r.status_code == 403, r.text)
    r = c.post(f"/api/v1/users/{admin_id}/reset-password", headers=bearer(tmp_token))
    check(
        "일반 관리자는 최고 관리자 비밀번호 초기화 못 함", r.status_code == 403, r.text
    )
    r = c.patch(
        f"/api/v1/users/{admin_id}", headers=bearer(tmp_token), json={"role": "MEMBER"}
    )
    check("일반 관리자는 최고 관리자 강등 못 함", r.status_code == 403, r.text)
    r = c.patch(
        f"/api/v1/users/{admin_id}",
        headers=bearer(tmp_token),
        json={"status": "SUSPENDED"},
    )
    check("일반 관리자는 최고 관리자 정지 못 함", r.status_code == 403, r.text)
    r = c.post(
        f"/api/v1/users/{admin_id}/reject",
        headers=bearer(tmp_token),
        json={"reason": "x"},
    )
    check("일반 관리자는 최고 관리자 반려 못 함", r.status_code == 403, r.text)
    r = c.post(
        f"/api/v1/users/{tmp_id}/reject",
        headers=bearer(admin_token),
        json={"reason": "x"},
    )
    check(
        "승인된 계정은 반려 대상이 아님",
        r.status_code == 400 and r.json()["error"]["code"] == "NOT_PENDING",
        r.text,
    )
    r = c.post(f"/api/v1/users/{tmp_id}/reset-password", headers=bearer(admin_token))
    check("최고 관리자는 관리자 비밀번호 초기화 가능", r.status_code == 200, r.text)
    r = c.delete(f"/api/v1/users/{tmp_id}", headers=bearer(admin_token))
    check("관리자가 둘이면 하나는 지울 수 있음", r.status_code == 200, r.text)

print(f"\n{'=' * 60}")
print(f"  통과 {PASSED}건 - 전 모듈 정상 동작")
print(f"{'=' * 60}")
# Windows keeps the file locked until the connection pool is closed, and
# WAL mode leaves two sidecar files behind.
engine.dispose()
for suffix in ("", "-wal", "-shm"):
    Path(str(TEST_DB) + suffix).unlink(missing_ok=True)
shutil.rmtree(TEST_STORAGE, ignore_errors=True)
