"""구 서버(CS_Record)에서 옮겨 온 규칙의 동작 확인. 스모크 테스트(smoke_test.py)와 같은 방식,
따로 만든 임시 SQLite 파일에 대고 돈다.

Run:  python scripts/smoke_test_legacy.py
검사하는 것: 재고 상태 규칙(설치는 매장 필수 · 창고는 매장 자동 비움 · AS 는 매장 유지),
S/N 중복 · 제조사 필수, 여러 대 등록/이동, 현황, 매장 장비 세트 설정(NG 관리 번호),
접수의 서비스구분/증상/제조사/대응인원/렌탈 규칙, 렌탈 ↔ 재고 연동, 종결 규칙,
검색 조건, 크로스탭 · 운영 매장 · 대시보드, 폐점 회수, 공휴일, 엑셀.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

TEST_DB = ROOT / "smoke_test_legacy.db"
TEST_DB.unlink(missing_ok=True)
os.environ["DATABASE_URL"] = f"sqlite+pysqlite:///{TEST_DB.as_posix()}"
os.environ["SCHEDULER_ENABLED"] = "false"
os.environ["ENVIRONMENT"] = "test"
os.environ["DEBUG"] = "false"
os.environ["AUTH_RATE_LIMIT_ENABLED"] = "false"
os.environ["FIRST_SUPERADMIN_EMAIL"] = "admin@ddeck.local"
os.environ["FIRST_SUPERADMIN_PASSWORD"] = "admin1234"

from app.core.database import engine
from app.main import app
from fastapi.testclient import TestClient

PASSED = 0
XLSX = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"


def check(label: str, condition: bool, detail: object = "") -> None:
    global PASSED
    if condition:
        PASSED += 1
        print(f"  OK   {label}")
    else:
        print(f"  FAIL {label}\n       {detail}")
        raise SystemExit(1)


def err(r) -> str:
    try:
        return r.json()["error"]["code"]
    except Exception:  # noqa: BLE001 - isolate background/diagnostic failures
        return f"HTTP {r.status_code}"


with TestClient(app) as c:
    r = c.post("/api/v1/auth/login", json={"email": "admin", "password": "admin1234"})
    check("관리자 로그인 (아이디만으로)", r.status_code == 200, r.text)
    H = {"Authorization": f"Bearer {r.json()['access_token']}"}
    r = c.post(
        "/api/v1/auth/change-password",
        headers=H,
        json={"current_password": "admin1234", "new_password": "admin5678"},
    )
    check("초기 관리자 비밀번호 변경", r.status_code == 200, r.text)

    H = {
        "Authorization": "Bearer "
        + c.post(
            "/api/v1/auth/login", json={"email": "admin", "password": "admin5678"}
        ).json()["access_token"]
    }

    def group(code):
        r = c.get(f"/api/v1/admin/codes/{code}", headers=H)
        assert r.status_code == 200, r.text
        return r.json()

    def by_name(g, name):
        return next(i for i in g["items"] if i["name"] == name)

    def add_item(g, code, name, parent_id=None, **kw):
        r = c.post(
            f"/api/v1/admin/codes/{g['id']}/items",
            headers=H,
            json={
                "code": code,
                "name": name,
                "parent_id": parent_id,
                "sort_order": 50,
                **kw,
            },
        )
        assert r.status_code == 201, r.text
        return r.json()

    def item_or_add(g, code, name, parent_id=None, **kw):
        """시드에 이미 있으면 그것을 쓴다 (2026-09-25 부터 구 서버 서비스구분·세부분류가 기본값)."""
        for i in g["items"]:
            if i["name"] == name and (parent_id is None or i["parent_id"] == parent_id):
                return i
        return add_item(g, code, name, parent_id, **kw)

    # ============================================================ 기본 목록
    print("\n[1] 기본 목록: 장비 종류 · 상태 규칙 · 품명 · 제조사 · 위치")
    kinds = group("ASSET_CATEGORY")
    robot, ctrl, ne_gripper = (
        by_name(kinds, "로봇팔"),
        by_name(kinds, "제어박스"),
        by_name(kinds, "비전동 그리퍼"),
    )
    check(
        "장비 종류 5종 시드",
        all(
            any(i["name"] == n for i in kinds["items"])
            for n in ["로봇팔", "제어박스", "전동 그리퍼", "비전동 그리퍼", "툴체인저"]
        ),
    )
    statuses = group("ASSET_STATUS")
    st = {i["name"]: i for i in statuses["items"]}
    check("상태 13종 시드", len(statuses["items"]) == 13, len(statuses["items"]))
    check(
        "상태 규칙 extra",
        st["설치"]["extra"]["rule"] == "store"
        and st["창고"]["extra"]["rule"] == "clear"
        and st["AS 대기"]["extra"]["rule"] == "as"
        and st["바른 회수"]["extra"]["rule"] == "free",
        st["설치"],
    )
    makers = group("ASSET_MAKER")
    rainbow = next(
        i
        for i in makers["items"]
        if i["name"] == "레인보우로보틱스" and i["parent_id"] == robot["id"]
    )
    check("종류별 제조사 시드 (로봇팔 → 레인보우로보틱스)", rainbow is not None)
    rainbow_ctrl = next(
        i
        for i in makers["items"]
        if i["name"] == "레인보우로보틱스" and i["parent_id"] == ctrl["id"]
    )
    check("제어박스 제조사 시드", rainbow_ctrl is not None)
    models = group("ASSET_MODEL")
    check(
        "종류별 품명 시드 (CB-04 · CB-06)",
        {i["name"] for i in models["items"] if i["parent_id"] == ctrl["id"]}
        == {"CB-04", "CB-06"},
    )
    locs = {
        l["name"]: l for l in c.get("/api/v1/inventory/locations", headers=H).json()
    }
    check("창고 · 사무실 위치 시드", "창고" in locs and "사무실" in locs, list(locs))

    # 서비스 목록: 서비스구분 로봇팔 · 제어박스, 증상, 대응인원, 렌탈 종류, 브랜드
    cats = group("SERVICE_CATEGORY")
    cat_robot = item_or_add(cats, "ROBOT_ARM", "로봇팔")
    cat_ctrl = item_or_add(cats, "CONTROL_BOX", "제어박스")
    cat_comm = item_or_add(cats, "COMM", "통신")
    symptoms = group("SERVICE_SYMPTOM")
    sym_grip = item_or_add(symptoms, "GRIP_ERR", "그리퍼 오류", cat_robot["id"])
    sym_power = item_or_add(symptoms, "POWER_CABLE", "파워 케이블", cat_ctrl["id"])
    responders = group("SERVICE_RESPONDER")
    resp_a = add_item(responders, "SEO", "서선재")
    resp_b = add_item(responders, "LEE", "이재룡")
    rental_types = group("SERVICE_RENTAL_TYPE")
    rt_ctrl = add_item(rental_types, "CTRL", "제어박스")
    brands = group("STORE_BRAND")
    bareun = add_item(brands, "BAREUN", "바른치킨")
    faults = group("SERVICE_FAULT")
    fault_user = by_name(faults, "사용자 오조작")

    # ============================================================ 매장
    print("\n[2] 매장: 등록 · 회수 위치 안내")
    r = c.post(
        "/api/v1/stores",
        headers=H,
        json={"name": "테스트 문산점", "brand_id": bareun["id"]},
    )
    check("매장 등록", r.status_code == 201, r.text)
    store = r.json()
    check(
        "기본 그리퍼 종류(설정)", store["gripper_type"] == "전동", store["gripper_type"]
    )
    check(
        "폐점 회수 위치 = 바른 회수 · 창고 · 사무실",
        [o["name"] for o in store["recover_options"]]
        == ["바른 회수", "창고", "사무실"],
        store["recover_options"],
    )
    r = c.post(
        "/api/v1/stores",
        headers=H,
        json={"name": "테스트 2호점", "brand_id": bareun["id"]},
    )
    store2 = r.json()

    # ============================================================ 재고 규칙
    print("\n[3] 재고: 상태 규칙 · S/N · 제조사 · 여러 대")
    r = c.post(
        "/api/v1/inventory/assets",
        headers=H,
        json={
            "name": "로봇팔 RB5-850EN",
            "category_id": robot["id"],
            "serial_no": "R585EN-0001",
            "location_id": locs["창고"]["id"],
        },
    )
    check(
        "로봇팔은 제조사 필수",
        r.status_code == 400 and err(r) == "MAKER_REQUIRED",
        r.text,
    )

    r = c.post(
        "/api/v1/inventory/assets",
        headers=H,
        json={
            "name": "로봇팔 RB5-850EN",
            "category_id": robot["id"],
            "serial_no": "R585EN-0001",
            "manufacturer": "레인보우로보틱스",
            "status_item_id": st["설치"]["id"],
        },
    )
    check(
        "'설치'는 매장 필수",
        r.status_code == 400 and err(r) == "STORE_REQUIRED",
        r.text,
    )

    r = c.post(
        "/api/v1/inventory/assets",
        headers=H,
        json={
            "name": "로봇팔 RB5-850EN",
            "category_id": robot["id"],
            "serial_no": "R585EN-0001",
            "model_name": "RB5-850EN",
            "manufacturer": "레인보우로보틱스",
            "status_item_id": st["설치"]["id"],
            "store_id": store["id"],
            "set_no": 1,
        },
    )
    check("매장에 설치 등록", r.status_code == 201, r.text)
    r1 = r.json()
    check(
        "세부 상태 '설치' → enum IN_USE",
        r1["status"] == "IN_USE" and r1["status_item"]["name"] == "설치",
        r1["status"],
    )
    check(
        "설치 장비는 위치 없이 매장만",
        r1["location_id"] is None and r1["store"]["name"] == "테스트 문산점",
        r1,
    )

    r = c.post(
        "/api/v1/inventory/assets",
        headers=H,
        json={
            "name": "로봇팔",
            "category_id": robot["id"],
            "serial_no": "r585en-0001",
            "manufacturer": "레인보우로보틱스",
            "location_id": locs["창고"]["id"],
        },
    )
    check(
        "같은 종류 안 S/N 중복 차단 (대소문자 무시)",
        r.status_code == 409 and err(r) == "SERIAL_TAKEN",
        r.text,
    )

    r = c.post(
        "/api/v1/inventory/assets/bulk",
        headers=H,
        json={
            "serial_nos": ["C06-0001, C06-0002", "C06-0003"],
            "category_id": ctrl["id"],
            "model_name": "CB-06",
            "manufacturer": "레인보우로보틱스",
            "location_id": locs["창고"]["id"],
            "status_item_id": st["창고"]["id"],
        },
    )
    check(
        "여러 대 한 번에 등록 (쉼표·공백 분리)",
        r.status_code == 201 and len(r.json()["created"]) == 3,
        r.text,
    )
    ctrls = {a["serial_no"]: a for a in r.json()["created"]}
    check(
        "등록 이름 자동",
        ctrls["C06-0001"]["name"] == "제어박스 CB-06",
        ctrls["C06-0001"]["name"],
    )
    r = c.post(
        "/api/v1/inventory/assets/bulk",
        headers=H,
        json={
            "serial_nos": ["C06-0001 C06-0009"],
            "category_id": ctrl["id"],
            "manufacturer": "레인보우로보틱스",
            "location_id": locs["창고"]["id"],
        },
    )
    check(
        "여러 대 등록 시 중복은 건너뜀",
        len(r.json()["created"]) == 1 and r.json()["duplicates"] == ["C06-0001"],
        r.text,
    )
    ctrls["C06-0009"] = r.json()["created"][0]

    def move(aid, **body):
        return c.post(
            f"/api/v1/inventory/assets/{aid}/move",
            headers=H,
            json={"movement_type": "MOVE", **body},
        )

    r = move(r1["id"], to_status_item_id=st["창고"]["id"])
    check(
        "'창고'로 바꾸면 매장 자동 비움 + 창고 위치",
        r.status_code == 200
        and r.json()["store_id"] is None
        and r.json()["location"]["name"] == "창고"
        and r.json()["status"] == "IN_STOCK"
        and r.json()["set_no"] == 0,
        r.text,
    )
    r = move(r1["id"], to_store_id=store["id"], to_set_no=2)
    check(
        "상태 없이 매장으로 보내면 '설치'로",
        r.json()["status_item"]["name"] == "설치" and r.json()["set_no"] == 2,
        r.text,
    )
    r = move(r1["id"], to_status_item_id=st["AS 대기"]["id"])
    check(
        "AS 대기는 매장에 둔 채 상태만",
        r.json()["store_id"] == store["id"]
        and r.json()["status"] == "REPAIR"
        and r.json()["set_no"] == 2,
        r.text,
    )
    r = move(r1["id"], to_status_item_id=st["AS 대기"]["id"])
    check(
        "바뀐 것 없는 이동은 거절",
        r.status_code == 400 and err(r) == "NO_CHANGE",
        r.text,
    )
    r = move(r1["id"], to_status_item_id=st["설치"]["id"], to_store_id=store2["id"])
    check(
        "다른 매장으로 가면 세트 미지정",
        r.json()["store_id"] == store2["id"] and r.json()["set_no"] == 0,
        r.text,
    )
    r = move(
        r1["id"],
        to_status_item_id=st["설치"]["id"],
        to_store_id=store["id"],
        to_set_no=1,
    )
    r = move(r1["id"], to_location_id=locs["사무실"]["id"])
    check(
        "매장을 떠나 위치로 가면 자리에 맞는 상태(사무실)",
        r.json()["status_item"]["name"] == "사무실" and r.json()["store_id"] is None,
        r.text,
    )
    r = move(r1["id"], to_status_item_id=st["미상"]["id"])
    check(
        "'미상'은 위치도 비움 (LOST)",
        r.json()["status"] == "LOST" and r.json()["location_id"] is None,
        r.text,
    )
    r = move(
        r1["id"],
        to_status_item_id=st["설치"]["id"],
        to_store_id=store["id"],
        to_set_no=1,
    )
    check("다시 설치", r.status_code == 200, r.text)
    r = c.get(f"/api/v1/inventory/assets/{r1['id']}/movements", headers=H)
    check("이동 이력 누적", r.json()["total"] >= 8, r.json()["total"])

    r = c.post(
        "/api/v1/inventory/assets/bulk-move",
        headers=H,
        json={
            "asset_ids": [ctrls["C06-0001"]["id"], ctrls["C06-0002"]["id"]],
            "to_store_id": store["id"],
            "to_status_item_id": st["설치"]["id"],
            "to_set_no": 1,
            "reason": "납품",
        },
    )
    check(
        "여러 대 한 번에 이동",
        r.status_code == 200 and len(r.json()["moved"]) == 2,
        r.text,
    )
    r = c.post(
        "/api/v1/inventory/assets/bulk-move",
        headers=H,
        json={
            "asset_ids": [ctrls["C06-0001"]["id"], ctrls["C06-0002"]["id"]],
            "to_store_id": store["id"],
            "to_status_item_id": st["설치"]["id"],
            "to_set_no": 1,
        },
    )
    check(
        "이미 그 자리인 장비는 건너뜀",
        len(r.json()["skipped"]) == 2 and not r.json()["moved"],
        r.text,
    )
    r = c.post(
        "/api/v1/inventory/assets/bulk-move",
        headers=H,
        json={
            "asset_ids": [ctrls["C06-0003"]["id"]],
            "to_status_item_id": st["렌탈 중"]["id"],
        },
    )
    check(
        "일괄 이동에서 규칙 위반은 오류 목록으로",
        r.json()["errors"] and "매장" in r.json()["errors"][0],
        r.text,
    )

    r = c.patch(
        f"/api/v1/inventory/assets/{ctrls['C06-0003']['id']}",
        headers=H,
        json={"status_item_id": st["사무실"]["id"]},
    )
    check(
        "PATCH 로 상태를 바꿔도 규칙 + 이력",
        r.json()["location"]["name"] == "사무실",
        r.text,
    )
    r = c.get(
        f"/api/v1/inventory/assets/{ctrls['C06-0003']['id']}/movements", headers=H
    )
    check("PATCH 상태 변경이 이력에 남음", r.json()["total"] == 2, r.json()["total"])

    r = c.get("/api/v1/inventory/overview", headers=H)
    ov = r.json()
    check("재고 현황", r.status_code == 200 and ov["total"] == 5, r.text)
    brand_row = next(x for x in ov["by_brand"] if x["label"] == "바른치킨")
    check(
        "현황: 브랜드×종류 (바른치킨 로봇팔 1 · 제어박스 2)",
        brand_row["counts"][robot["id"]] == 1 and brand_row["counts"][ctrl["id"]] == 2,
        brand_row,
    )
    check(
        "현황: 장소×종류 (창고 · 사무실)",
        {x["label"] for x in ov["by_place"]} == {"창고", "사무실"},
        ov["by_place"],
    )
    check(
        "현황: 상태 행에 설치 3",
        next(x for x in ov["by_status"] if x["label"] == "설치")["total"] == 3,
        ov["by_status"],
    )

    r = c.get(
        f"/api/v1/inventory/assets?store_id={store['id']}&sort=kind_serial", headers=H
    )
    check("매장 필터", r.json()["total"] == 3, r.json()["total"])
    r = c.get("/api/v1/inventory/assets?at_store=false", headers=H)
    check("미설치 필터", r.json()["total"] == 2, r.json()["total"])
    r = c.get(f"/api/v1/inventory/assets?status_item_id={st['설치']['id']}", headers=H)
    check("세부 상태 필터", r.json()["total"] == 3, r.json()["total"])
    r = c.get("/api/v1/inventory/assets?q=문산", headers=H)
    check("검색어로 매장 이름", r.json()["total"] == 3, r.json()["total"])
    r = c.get("/api/v1/inventory/assets/export.xlsx", headers=H)
    check(
        "재고 엑셀",
        r.status_code == 200
        and r.headers["content-type"].startswith(XLSX)
        and len(r.content) > 2000,
        r.headers,
    )

    # ============================================================ 매장 장비 설정
    print("\n[4] 매장 장비 설정: 세트 · 관리 번호 · 세트 이름")
    r = c.post(
        f"/api/v1/stores/{store2['id']}/equipment",
        headers=H,
        json={
            "install_date": "2026-09-01",
            "sets": [
                {
                    "gripper_type": "비전동",
                    "name": "1호기",
                    "slots": [
                        {
                            "category_id": robot["id"],
                            "serial_no": "R585EN-0002",
                            "model_name": "RB5-850EN",
                        },
                        {"category_id": ctrl["id"], "serial_no": "C06-0009"},
                    ],
                }
            ],
        },
    )
    check(
        "재고에 없는 S/N 은 거절 (아무것도 저장 안 함)",
        r.status_code == 400
        and err(r) == "SERIAL_UNKNOWN"
        and r.json()["error"]["details"]["unknown"] == ["로봇팔 R585EN-0002"],
        r.text,
    )
    r = c.post(
        "/api/v1/inventory/assets/bulk",
        headers=H,
        json={
            "serial_nos": ["R585EN-0002"],
            "category_id": robot["id"],
            "model_name": "RB5-850EN",
            "manufacturer": "레인보우로보틱스",
            "location_id": locs["창고"]["id"],
            "purchase_date": "2026-09-01",
        },
    )
    check(
        "장비 목록에서 먼저 등록",
        r.status_code == 201 and len(r.json()["created"]) == 1,
        r.text,
    )
    r = c.post(
        f"/api/v1/stores/{store2['id']}/equipment",
        headers=H,
        json={
            "install_date": "2026-09-01",
            "sets": [
                {
                    "gripper_type": "비전동",
                    "name": "1호기",
                    "slots": [
                        {
                            "category_id": robot["id"],
                            "serial_no": "R585EN-0002",
                            "model_name": "RB5-850EN",
                        },
                        {"category_id": ctrl["id"], "serial_no": "C06-0009"},
                    ],
                }
            ],
        },
    )
    check("장비 설정 저장", r.status_code == 200, r.text)
    eq = r.json()
    check(
        "비전동 관리 번호 자동 등록",
        any("NG-0001" in a for a in eq["added"]),
        eq["added"],
    )
    check(
        "창고에 있던 장비는 이 매장으로 이동",
        any("C06-0009" in m for m in eq["moved"])
        and any("R585EN-0002" in m for m in eq["moved"]),
        eq["moved"],
    )
    check("매장 그리퍼 종류 갱신", eq["store"]["gripper_type"] == "비전동")
    check(
        "세트 이름 저장", eq["store"]["sets"][0]["name"] == "1호기", eq["store"]["sets"]
    )
    check(
        "새 로봇팔에 기본 제조사",
        next(
            a
            for g in eq["store"]["asset_groups"]
            for a in g["assets"]
            if a["serial_no"] == "R585EN-0002"
        )
        is not None,
    )
    r = c.get("/api/v1/inventory/assets?q=R585EN-0002", headers=H)
    check(
        "이동한 장비: 매장 설치 · 세트 1",
        r.json()["items"][0]["store_id"] == store2["id"]
        and r.json()["items"][0]["set_no"] == 1,
        r.json()["items"][0],
    )
    r = c.post(
        f"/api/v1/stores/{store2['id']}/equipment",
        headers=H,
        json={
            "sets": [
                {
                    "gripper_type": "비전동",
                    "slots": [{"category_id": robot["id"], "serial_no": "R585EN-0002"}],
                }
            ]
        },
    )
    check(
        "다시 저장해도 관리 번호 중복 없음",
        not r.json()["added"] and "로봇팔 R585EN-0002" in r.json()["kept"],
        r.json(),
    )
    r = c.post(
        f"/api/v1/stores/{store2['id']}/equipment",
        headers=H,
        json={"sets": [{"gripper_type": "수동", "slots": []}]},
    )
    check(
        "그리퍼 종류 검사",
        r.status_code == 400 and err(r) == "BAD_GRIPPER_TYPE",
        r.text,
    )

    r = c.post(f"/api/v1/stores/{store2['id']}/sets", headers=H, json={"name": "2호기"})
    check(
        "세트 추가 (다음 번호)",
        r.status_code == 201 and [s["set_no"] for s in r.json()["sets"]] == [1, 2],
        r.json()["sets"],
    )
    r = c.patch(
        f"/api/v1/stores/{store2['id']}/sets/2", headers=H, json={"name": "예비"}
    )
    check("세트 이름 변경", r.json()["sets"][1]["name"] == "예비", r.json()["sets"])
    r = c.delete(f"/api/v1/stores/{store2['id']}/sets/1", headers=H)
    check(
        "장비 있는 세트 삭제 차단",
        r.status_code == 400 and err(r) == "SET_NOT_EMPTY",
        r.text,
    )
    r = c.delete(f"/api/v1/stores/{store2['id']}/sets/2", headers=H)
    check("빈 세트 삭제", r.status_code == 200 and len(r.json()["sets"]) == 1, r.text)

    # ============================================================ 대응 기록 규칙
    print("\n[5] 대응 기록: 서비스구분 · 증상 · 제조사 · 대응인원 · 렌탈")
    base = {
        "title": "그리퍼가 안 열림",
        "store_id": store["id"],
        "description": "그리퍼 동작 불량",
        "received_at": "2026-03-10T01:00:00Z",
        "fault_id": fault_user["id"],
    }
    r = c.post("/api/v1/service/tickets", headers=H, json={**base, "causes": []})
    check(
        "서비스구분 1 필수",
        r.status_code == 400 and err(r) == "CATEGORY_REQUIRED",
        r.text,
    )
    r = c.post(
        "/api/v1/service/tickets",
        headers=H,
        json={
            **base,
            "causes": [{"category_id": cat_robot["id"], "symptom_id": sym_grip["id"]}],
        },
    )
    check(
        "로봇팔 원인은 제조사 필수",
        r.status_code == 400 and err(r) == "MAKER_REQUIRED",
        r.text,
    )
    r = c.post(
        "/api/v1/service/tickets",
        headers=H,
        json={
            **base,
            "causes": [
                {
                    "category_id": cat_ctrl["id"],
                    "symptom_id": sym_grip["id"],
                    "maker_id": rainbow_ctrl["id"],
                }
            ],
        },
    )
    check(
        "증상은 그 서비스구분에 딸린 것만",
        r.status_code == 400 and err(r) == "SYMPTOM_MISMATCH",
        r.text,
    )
    r = c.post(
        "/api/v1/service/tickets",
        headers=H,
        json={
            **base,
            "causes": [
                {
                    "category_id": cat_ctrl["id"],
                    "symptom_id": sym_power["id"],
                    "maker_id": rainbow["id"],
                }
            ],
        },
    )
    check(
        "제조사는 그 종류의 제조사 목록에서",
        r.status_code == 400 and err(r) == "MAKER_MISMATCH",
        r.text,
    )
    r = c.post(
        "/api/v1/service/tickets",
        headers=H,
        json={
            **base,
            "causes": [
                {
                    "category_id": cat_robot["id"],
                    "symptom_id": sym_grip["id"],
                    "maker_id": rainbow["id"],
                },
                {"category_id": cat_comm["id"]},
            ],
            "responder_ids": [resp_a["id"], resp_b["id"]],
        },
    )
    check("접수 등록 (원인 2 · 대응인원 2)", r.status_code == 201, r.text)
    t1 = r.json()
    check(
        "대표 분류 = 첫 원인",
        t1["category_id"] == cat_robot["id"] and t1["symptom_id"] == sym_grip["id"],
    )
    check(
        "원인 목록 · 제조사",
        len(t1["causes"]) == 2
        and t1["causes"][0]["maker"]["name"] == "레인보우로보틱스",
        t1["causes"],
    )
    check(
        "대응인원 순서",
        [x["name"] for x in t1["responders"]] == ["서선재", "이재룡"],
        t1["responders"],
    )
    check(
        "매장 · 브랜드 · 과실 동봉",
        t1["store"]["name"] == "테스트 문산점"
        and t1["brand_name"] == "바른치킨"
        and t1["fault"]["name"] == "사용자 오조작",
        t1,
    )
    check(
        "원인 라벨",
        t1["cause_labels"] == ["로봇팔 > 그리퍼 오류 (레인보우로보틱스)", "통신"],
        t1["cause_labels"],
    )
    check(
        "거래처 이름은 매장 이름으로",
        t1["customer_name"] == "테스트 문산점",
        t1["customer_name"],
    )

    rental = {
        "title": "제어박스 렌탈",
        "store_id": store["id"],
        "received_at": "2026-04-01T01:00:00Z",
        "causes": [
            {
                "category_id": cat_ctrl["id"],
                "symptom_id": sym_power["id"],
                "maker_id": rainbow_ctrl["id"],
            }
        ],
        "is_rental": True,
    }
    r = c.post("/api/v1/service/tickets", headers=H, json=rental)
    check(
        "렌탈 O 면 종류 필수",
        r.status_code == 400 and err(r) == "RENTAL_TYPE_REQUIRED",
        r.text,
    )
    r = c.post(
        "/api/v1/service/tickets",
        headers=H,
        json={**rental, "rental_type_id": rt_ctrl["id"]},
    )
    check(
        "렌탈 O 면 시리얼 필수",
        r.status_code == 400 and err(r) == "RENTAL_SERIAL_REQUIRED",
        r.text,
    )
    r = c.post(
        "/api/v1/service/tickets",
        headers=H,
        json={
            **rental,
            "rental_type_id": rt_ctrl["id"],
            "rental_serials": "C06-9999",
            "rental_due_date": "2026-04-20",
        },
    )
    check(
        "렌탈 시리얼은 재고 S/N 만",
        r.status_code == 400
        and err(r) == "RENTAL_SERIAL_UNKNOWN"
        and r.json()["error"]["details"]["missing"] == ["C06-9999"],
        r.text,
    )
    r = c.post(
        "/api/v1/service/tickets",
        headers=H,
        json={**rental, "rental_type_id": rt_ctrl["id"], "rental_serials": "C06-0003"},
    )
    check(
        "렌탈 O 면 회수 예정일 필수",
        r.status_code == 400 and err(r) == "RENTAL_DUE_REQUIRED",
        r.text,
    )
    r = c.post(
        "/api/v1/service/tickets",
        headers=H,
        json={
            **rental,
            "rental_type_id": rt_ctrl["id"],
            "rental_serials": "C06-0003 ; C06-0009",
            "rental_due_date": "2026-04-20",
        },
    )
    check("렌탈 접수 등록", r.status_code == 201, r.text)
    t2 = r.json()
    check(
        "시리얼 표기 통일",
        t2["rental_serials"] == "C06-0003, C06-0009",
        t2["rental_serials"],
    )
    check(
        "재고 연동 안내",
        len(t2["notices"]) == 2 and all("렌탈 중" in n for n in t2["notices"]),
        t2["notices"],
    )
    a = c.get(f"/api/v1/inventory/assets/{ctrls['C06-0003']['id']}", headers=H).json()
    check(
        "렌탈 장비 → 그 매장 '렌탈 중' (LOANED)",
        a["status"] == "LOANED"
        and a["status_item"]["name"] == "렌탈 중"
        and a["store_id"] == store["id"],
        a,
    )
    a9 = c.get(f"/api/v1/inventory/assets/{ctrls['C06-0009']['id']}", headers=H).json()
    check(
        "다른 매장에 설치돼 있던 장비도 렌탈 매장으로",
        a9["store_id"] == store["id"] and a9["set_no"] == 0,
        a9,
    )
    r = c.get(
        f"/api/v1/inventory/assets/{ctrls['C06-0003']['id']}/movements", headers=H
    )
    check(
        "렌탈 이동 이력에 기록 번호",
        r.json()["items"][0]["reference_type"] == "service_ticket"
        and r.json()["items"][0]["reference_id"] == t2["id"],
        r.json()["items"][0],
    )

    r = c.patch(
        f"/api/v1/service/tickets/{t2['id']}", headers=H, json={"rental_returned": True}
    )
    check(
        "회수 O 면 실제 회수일 필수",
        r.status_code == 400 and err(r) == "RENTAL_RETURN_DATE_REQUIRED",
        r.text,
    )
    r = c.patch(
        f"/api/v1/service/tickets/{t2['id']}",
        headers=H,
        json={"rental_returned": True, "rental_return_date": "2026-04-15"},
    )
    check(
        "회수 저장",
        r.status_code == 200 and r.json()["rental_returned"] is True,
        r.text,
    )
    a = c.get(f"/api/v1/inventory/assets/{ctrls['C06-0003']['id']}", headers=H).json()
    check(
        "회수 → 재고 '창고'로 복귀",
        a["status"] == "IN_STOCK"
        and a["status_item"]["name"] == "창고"
        and a["store_id"] is None
        and a["location"]["name"] == "창고",
        a,
    )
    r = c.patch(
        f"/api/v1/service/tickets/{t2['id']}", headers=H, json={"is_rental": False}
    )
    check(
        "렌탈 X 면 렌탈 칸 비움",
        r.json()["rental_serials"] is None and r.json()["rental_due_date"] is None,
        r.json(),
    )

    r = c.post(
        f"/api/v1/service/tickets/{t1['id']}/status",
        headers=H,
        json={"status": "COMPLETED"},
    )
    check(
        "종결에는 대응 내용",
        r.status_code == 400 and err(r) == "RESULT_NOTE_REQUIRED",
        r.text,
    )
    r = c.post(
        f"/api/v1/service/tickets/{t2['id']}/status",
        headers=H,
        json={"status": "COMPLETED", "result_note": "케이블 교체"},
    )
    check(
        "종결에는 대응인원",
        r.status_code == 400 and err(r) == "RESPONDER_REQUIRED",
        r.text,
    )
    r = c.post(
        f"/api/v1/service/tickets/{t2['id']}/status",
        headers=H,
        json={
            "status": "COMPLETED",
            "result_note": "케이블 교체",
            "responder_ids": [resp_a["id"]],
            "completed_at": "2026-04-02T02:00:00Z",
        },
    )
    check(
        "종결 (대응일 지정)",
        r.status_code == 200 and r.json()["completed_at"].startswith("2026-04-02"),
        r.text,
    )
    r = c.post(
        f"/api/v1/service/tickets/{t1['id']}/status",
        headers=H,
        json={"status": "COMPLETED", "result_note": "그리퍼 교체"},
    )
    check("대응인원이 이미 있으면 종결", r.status_code == 200, r.text)

    r = c.patch(
        f"/api/v1/service/tickets/{t1['id']}",
        headers=H,
        json={
            "causes": [{"category_id": cat_comm["id"]}],
            "responder_ids": [resp_b["id"]],
        },
    )
    check(
        "원인 · 대응인원 통째로 수정",
        len(r.json()["causes"]) == 1
        and r.json()["category_id"] == cat_comm["id"]
        and [x["name"] for x in r.json()["responders"]] == ["이재룡"],
        r.json(),
    )
    c.patch(
        f"/api/v1/service/tickets/{t1['id']}",
        headers=H,
        json={
            "causes": [
                {
                    "category_id": cat_robot["id"],
                    "symptom_id": sym_grip["id"],
                    "maker_id": rainbow["id"],
                },
                {"category_id": cat_comm["id"]},
            ],
            "responder_ids": [resp_a["id"], resp_b["id"]],
        },
    )

    # 3번째 건: 다른 연도 · 다른 매장 · 미종결
    r = c.post(
        "/api/v1/service/tickets",
        headers=H,
        json={
            "title": "통신 끊김",
            "store_id": store2["id"],
            "received_at": "2025-07-01T01:00:00Z",
            "causes": [{"category_id": cat_comm["id"]}],
            "responder_ids": [resp_b["id"]],
        },
    )
    t3 = r.json()

    print("\n[6] 검색 조건 · 엑셀")

    def total(qs):
        r = c.get(f"/api/v1/service/tickets?{qs}", headers=H)
        assert r.status_code == 200, r.text
        return r.json()["total"]

    def expect(label, qs, n):
        got = total(qs)
        check(
            label,
            got == n,
            f"{qs} -> {got} (기대 {n}); "
            + str(
                [
                    (t["ticket_no"], t["store_name"], t["status"])
                    for t in c.get(f"/api/v1/service/tickets?{qs}", headers=H).json()[
                        "items"
                    ]
                ]
            ),
        )

    expect("매장 필터", f"store_id={store['id']}", 2)
    expect("브랜드 필터", f"brand_id={bareun['id']}", 3)
    expect("서비스구분 필터 (원인 중 하나라도)", f"category_id={cat_comm['id']}", 2)
    expect("증상 필터", f"symptom_id={sym_grip['id']}", 1)
    expect("제조사 필터 (로봇팔의 레인보우)", f"maker_id={rainbow['id']}", 1)
    expect("제조사 필터 (제어박스의 레인보우)", f"maker_id={rainbow_ctrl['id']}", 1)
    expect("대응인원 필터", f"responder_id={resp_a['id']}", 2)
    expect("과실 필터", f"fault_id={fault_user['id']}", 1)
    expect("연도 필터 2025", "year=2025", 1)
    expect("연도 필터 2026", "year=2026", 2)
    expect("연·월 필터", "year=2026&month=4", 1)
    expect("미종결 필터", "only_open=true", 1)
    expect("렌탈 필터", "is_rental=true", 0)
    expect("렌탈 미회수 필터", "rental_unreturned=true", 0)
    expect("검색어: 매장 이름", "q=2호점", 1)
    expect("검색어: 대응인원 이름", "q=서선재", 2)
    expect("검색어: 증상 이름", "q=그리퍼 오류", 1)
    expect("검색어: 대응 내용", "q=케이블 교체", 1)
    r = c.get("/api/v1/service/tickets?sort=created_desc&size=1", headers=H)
    check(
        "목록에 원인 · 대응인원 · 매장 동봉",
        r.json()["items"][0]["cause_labels"] and r.json()["items"][0]["store_name"],
        r.json()["items"][0],
    )
    r = c.get(f"/api/v1/service/tickets/export.xlsx?brand_id={bareun['id']}", headers=H)
    check(
        "대응 기록 엑셀",
        r.status_code == 200 and r.headers["content-type"].startswith(XLSX),
        r.headers,
    )

    print("\n[7] 통계: 원인 수 세기 · 크로스탭 · 운영 매장 · 대시보드")
    r = c.get("/api/v1/service/stats/grouped?group_by=category", headers=H)
    g = r.json()
    check(
        "분류별: 원인 수 4 / 대응 건수 3", g["total_causes"] == 4 and g["total"] == 3, g
    )
    check(
        "통신 = 원인 2 · 건 2",
        next(b for b in g["buckets"] if b["label"] == "통신")["count"] == 2,
    )
    r = c.get(
        f"/api/v1/service/stats/grouped?group_by=symptom&category_id={cat_robot['id']}",
        headers=H,
    )
    check(
        "서비스구분 탭은 그 구분의 원인만",
        r.json()["total_causes"] == 1
        and r.json()["buckets"][0]["label"] == "그리퍼 오류",
        r.json(),
    )
    r = c.get("/api/v1/service/stats/grouped?group_by=responder", headers=H)
    check(
        "대응인원별",
        {b["label"]: b["count"] for b in r.json()["buckets"]}
        == {"서선재": 2, "이재룡": 2},
        r.json(),
    )
    r = c.get("/api/v1/service/stats/crosstab?rows=year&cols=category", headers=H)
    ct = r.json()
    check(
        "크로스탭 연도×서비스구분",
        r.status_code == 200 and [x["key"] for x in ct["rows"]] == ["2025", "2026"],
        ct["rows"],
    )
    row26 = next(x for x in ct["rows"] if x["key"] == "2026")
    check(
        "2026 줄: 원인 3 · 건 2",
        row26["total"] == 3 and row26["ticket_count"] == 2,
        row26,
    )
    check(
        "목록의 서비스구분은 0 이어도 열로",
        any(col["label"] == "구조물" for col in ct["cols"]),
        [col["label"] for col in ct["cols"]],
    )
    r = c.get(
        f"/api/v1/service/stats/crosstab?rows=brand&cols=symptom&category_id={cat_robot['id']}",
        headers=H,
    )
    check(
        "구분 탭 브랜드×세부분류",
        any(col["label"] == "그리퍼 오류" for col in r.json()["cols"])
        and r.json()["total_causes"] == 1,
        r.json(),
    )
    r = c.get("/api/v1/service/stats/crosstab?rows=store&cols=year", headers=H)
    check(
        "매장×연도 (매장은 건수 순)",
        r.json()["rows"][0]["label"] == "테스트 문산점",
        r.json()["rows"],
    )
    r = c.get("/api/v1/service/stats/crosstab?rows=maker&cols=year", headers=H)
    check(
        "제조사×연도 (빈 제조사는 미상)",
        {x["label"] for x in r.json()["rows"]} == {"레인보우로보틱스", "(제조사 미상)"},
        r.json()["rows"],
    )
    r = c.get("/api/v1/service/stats/crosstab?rows=year&cols=year", headers=H)
    check("같은 축 거절", r.status_code == 400)
    r = c.get("/api/v1/service/stats/crosstab.xlsx?rows=year&cols=category", headers=H)
    check(
        "통계 엑셀", r.status_code == 200 and r.headers["content-type"].startswith(XLSX)
    )
    r = c.get("/api/v1/service/stats/trend?interval=year", headers=H)
    check(
        "연도 추이",
        [p["period"] for p in r.json()["points"]] == ["2025", "2026"],
        r.json(),
    )
    r = c.get("/api/v1/service/stats/store-years", headers=H)
    sy = r.json()
    check(
        "연도별 운영 매장",
        r.status_code == 200 and sy["total_stores"] == 2 and "2025" in sy["years"],
        sy,
    )
    row = next(x for x in sy["rows"] if x["year"] == "2026")
    check(
        "2026 운영 매장 2 (첫 기록·설치일로 추정)",
        row["operating"] == 2 and row["tickets"] == 2,
        row,
    )
    check(
        "브랜드별 운영 매장 + 전체",
        sy["by_brand"][-1]["brand"] == "전체"
        and sy["by_brand"][0]["brand"] == "바른치킨",
        sy["by_brand"],
    )
    r = c.get("/api/v1/service/dashboard", headers=H)
    d = r.json()
    check(
        "대시보드", r.status_code == 200 and d["total"] == 3 and d["open_count"] == 1, d
    )
    check(
        "미종결은 오래된 것부터 · 경과일",
        d["open_tickets"][0]["ticket_no"] == t3["ticket_no"]
        and d["open_tickets"][0]["days_open"] > 300,
        d["open_tickets"],
    )
    check(
        "연도별 건수",
        {y["year"]: y["count"] for y in d["by_year"]} == {"2025": 1, "2026": 2},
        d["by_year"],
    )
    r = c.get("/api/v1/service/stats/summary?year=2026", headers=H)
    check(
        "요약도 같은 조건 (2026: 2건 · 종결 2)",
        r.json()["total"] == 2 and r.json()["completed_count"] == 2,
        r.json(),
    )

    print("\n[8] 매장 상세 · 폐점 회수")
    r = c.get(f"/api/v1/stores/{store['id']}", headers=H)
    sd = r.json()
    check(
        "매장 상세: 서비스구분별 발생",
        next(x for x in sd["category_counts"] if x["label"] == "로봇팔")["count"] == 1,
        sd["category_counts"],
    )
    check(
        "매장 상세: 대응 이력",
        len(sd["recent_tickets"]) == 2 and sd["recent_tickets"][0]["cause_labels"],
        sd["recent_tickets"],
    )
    check(
        "매장 상세: 회수 대상 3 (설치 3) · 렌탈 0",
        sd["movable_count"] == 3 and sd["rental_count"] == 0,
        (sd["movable_count"], sd["rental_count"]),
    )
    check(
        "매장 상세: 장비 종류 순서 (로봇팔 먼저)",
        sd["asset_groups"][0]["category_name"] == "로봇팔",
        [g["category_name"] for g in sd["asset_groups"]],
    )
    r = c.post(
        f"/api/v1/stores/{store['id']}/close",
        headers=H,
        json={"closed_date": "2026-09-01"},
    )
    check(
        "회수 위치 없이 폐점 → 장비 그대로 + 안내",
        r.status_code == 200
        and not r.json()["moved"]
        and "남아 있습니다" in r.json()["notices"][0],
        r.json(),
    )
    check(
        "폐점 표시",
        r.json()["store"]["is_closed"] is True
        and r.json()["store"]["closed_date"] == "2026-09-01",
    )
    r = c.post(
        f"/api/v1/stores/{store['id']}/close",
        headers=H,
        json={"recover_to_status_item_id": st["바른 회수"]["id"]},
    )
    check("바른 회수로 폐점 회수 3대", len(r.json()["moved"]) == 3, r.json()["moved"])
    check("회수 뒤 매장 장비 0", r.json()["store"]["asset_count"] == 0)
    a = c.get(f"/api/v1/inventory/assets/{r1['id']}", headers=H).json()
    check(
        "회수 장비: 매장 없음 · 세트 0 · 상태 바른 회수",
        a["store_id"] is None
        and a["set_no"] == 0
        and a["status_item"]["name"] == "바른 회수"
        and a["status"] == "IN_STOCK",
        a,
    )
    r = c.get(f"/api/v1/inventory/assets/{r1['id']}/movements", headers=H)
    check(
        "폐점 회수 이력",
        "매장 폐점" in r.json()["items"][0]["reason"],
        r.json()["items"][0],
    )
    r = c.get("/api/v1/stores?include_closed=true", headers=H)
    check("폐점 포함 목록", r.json()["total"] == 2)
    r = c.get("/api/v1/stores", headers=H)
    check("기본 목록은 운영 매장만", r.json()["total"] == 1)
    r = c.patch(
        f"/api/v1/stores/{store2['id']}",
        headers=H,
        json={"is_closed": True, "recover_to_status_item_id": st["창고"]["id"]},
    )
    check(
        "PATCH 폐점 + 회수 위치",
        r.status_code == 200 and r.json()["is_closed"] and r.json()["asset_count"] == 0,
        r.json(),
    )
    a = c.get("/api/v1/inventory/assets?q=NG-0001", headers=H).json()["items"][0]
    check(
        "창고 회수는 창고 위치로",
        a["status_item_id"] == st["창고"]["id"]
        and a["location_id"] == locs["창고"]["id"],
        a,
    )

    print("\n[9] 공휴일")
    r = c.get("/api/v1/calendar/holidays?year=2026", headers=H)
    hol = {h["date"]: h["name"] for h in r.json()}
    check(
        "2026 공휴일",
        r.status_code == 200
        and hol.get("2026-02-17") == "설날"
        and hol.get("2026-10-09") == "한글날",
        hol,
    )
    check(
        "대체공휴일 (2026-03-01 일요일 → 03-02)",
        hol.get("2026-03-02") == "대체공휴일(삼일절)",
        hol,
    )
    r = c.put(
        "/api/v1/admin/settings/CALENDAR",
        headers=H,
        json={
            "settings": [
                {
                    "key": "extra_holidays",
                    "value": "05-01:노동절",
                    "value_type": "string",
                    "label": "추가 휴일",
                    "is_public": True,
                }
            ]
        },
    )
    r = c.get("/api/v1/calendar/holidays?year=2026", headers=H)
    check(
        "추가 휴일 설정 반영",
        any(h["date"] == "2026-05-01" and h["name"] == "노동절" for h in r.json()),
        r.json(),
    )

print(f"\n{'=' * 60}")
print(f"  통과 {PASSED}건 - 구 서버 규칙 정상 동작")
print(f"{'=' * 60}")
engine.dispose()
for suffix in ("", "-wal", "-shm"):
    Path(str(TEST_DB) + suffix).unlink(missing_ok=True)
