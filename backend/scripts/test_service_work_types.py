"""Extensible service work types: API, history, filters and exports in a temporary DB."""

from __future__ import annotations

import io
import os
import sys
import tempfile
from pathlib import Path
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
TEMP = tempfile.TemporaryDirectory(prefix="ddeck-work-types-")
os.environ.update(
    DATABASE_URL=f"sqlite+pysqlite:///{TEMP.name}/test.db",
    ENVIRONMENT="test",
    DEBUG="false",
    AUTH_RATE_LIMIT_ENABLED="false",
    SCHEDULER_ENABLED="false",
    STORAGE_DIR=f"{TEMP.name}/storage",
    FIRST_SUPERADMIN_EMAIL="admin@ddeck.local",
    FIRST_SUPERADMIN_PASSWORD="admin1234",
)
from fastapi.testclient import TestClient
from openpyxl import load_workbook

from app.core.database import engine
from app.main import app

try:
    with TestClient(app) as client:

        def login(password):
            return {
                "Authorization": "Bearer "
                + client.post(
                    "/api/v1/auth/login", json={"email": "admin", "password": password}
                ).json()["access_token"]
            }

        headers = login("admin1234")

        def call(method, path, body=None, expected=200):
            r = client.request(method, "/api/v1" + path, json=body, headers=headers)
            assert r.status_code == expected, (path, r.status_code, r.text)
            return r.json()

        call(
            "POST",
            "/auth/change-password",
            {"current_password": "admin1234", "new_password": "admin5678"},
        )
        headers = login("admin5678")
        group = call("GET", "/admin/codes/SERVICE_WORK_TYPE")
        types = {i["code"]: i["id"] for i in group["items"]}
        assert set(types) == {"AS", "CS", "PO"}
        custom = call(
            "POST",
            f"/admin/codes/{group['id']}/items",
            {"code": "INSTALL", "name": "설치 지원"},
            201,
        )
        types["INSTALL"] = custom["id"]
        category = next(
            i["id"]
            for i in call("GET", "/admin/codes/SERVICE_CATEGORY")["items"]
            if i["code"] == "PROGRAM"
        )
        base = {
            "title": "업무 구분 검사",
            "category_id": category,
            "received_at": "2026-09-27T00:00:00Z",
        }

        def create(**extra):
            return call("POST", "/service/tickets", {**base, **extra}, 201)

        legacy = create()
        assert legacy["work_type_id"] is None and legacy["work_type"] is None
        tickets = {
            code: create(work_type_id=identifier) for code, identifier in types.items()
        }
        for code, ticket in tickets.items():
            assert ticket["work_type"]["code"] == code
            query = f"work_type_id={types[code]}"
            assert call("GET", "/service/tickets?" + query)["total"] == 1
            assert call("GET", "/service/stats/summary?" + query)["total"] == 1
            grouped = call("GET", "/service/stats/grouped?group_by=work_type&" + query)
            assert grouped["total"] == 1, grouped
            assert len(grouped["buckets"]) == 1 and grouped["buckets"][0]["count"] == 1
            assert grouped["buckets"][0]["key"] == types[code]
            trend = call("GET", "/service/stats/trend?interval=month&" + query)
            assert sum(p["received"] for p in trend["points"]) == 1
            cross = call(
                "GET", "/service/stats/crosstab?rows=year&cols=category&" + query
            )
            assert cross["total_tickets"] == 1
        assert call("GET", "/service/tickets?missing=work_type")["total"] == 1
        assert call("GET", "/service/stats/summary?missing=work_type")["total"] == 1
        assert call("GET", "/service/tickets?q=INSTALL")["total"] == 1
        assert call("GET", "/service/tickets?q=설치 지원")["total"] == 1
        for invalid in (category, str(uuid4())):
            call("POST", "/service/tickets", {**base, "work_type_id": invalid}, 400)
        ticket_path = "/service/tickets/" + tickets["CS"]["id"]
        changed = call("PATCH", ticket_path, {"work_type_id": types["PO"]})
        assert changed["work_type"]["code"] == "PO"
        assert changed["ticket_no"] == tickets["CS"]["ticket_no"]
        assert (
            call("PATCH", ticket_path, {"title": "구매로 변경"})["work_type_id"]
            == types["PO"]
        )
        assert call("PATCH", ticket_path, {"work_type_id": None})["work_type"] is None
        assert call("GET", "/service/tickets?missing=work_type")["total"] == 2
        item_path = "/admin/codes/items/" + custom["id"]
        call("PATCH", item_path, {"name": "현장 설치", "is_active": False})
        custom_path = "/service/tickets/" + tickets["INSTALL"]["id"]
        assert call("GET", custom_path)["work_type"]["name"] == "현장 설치"
        assert call("GET", item_path + "/usage")["count"] >= 1
        call("POST", "/service/tickets", {**base, "work_type_id": custom["id"]}, 400)
        call("PATCH", ticket_path, {"work_type_id": custom["id"]}, 400)
        call(
            "PATCH",
            custom_path,
            {"work_type_id": custom["id"], "title": "기존 사용 중지 항목 유지"},
        )
        call("DELETE", item_path)
        assert call("GET", custom_path)["work_type"]["code"] == "INSTALL"
        call(
            "PATCH",
            custom_path,
            {"work_type_id": custom["id"], "title": "삭제 후에도 이력 유지"},
        )
        call("POST", "/service/tickets", {**base, "work_type_id": custom["id"]}, 400)
        r = client.get(
            "/api/v1/service/tickets/export.xlsx",
            params={"work_type_id": types["PO"]},
            headers=headers,
        )
        assert r.status_code == 200, r.text
        rows = list(load_workbook(io.BytesIO(r.content)).active.values)
        assert rows[0][-2:] == ("업무 구분 코드", "업무 구분"), rows[0]
        assert len(rows) == 2 and rows[1][-2:] == ("PO", "구매"), rows
        r = client.get(
            "/api/v1/service/stats/all.xlsx",
            params={"work_type_id": types["PO"]},
            headers=headers,
        )
        assert r.status_code == 200
        workbook = load_workbook(io.BytesIO(r.content))
        assert "업무 구분" in workbook.sheetnames
        assert list(workbook["업무 구분"].values)[1][:2] == ("구매", 1)
        call("DELETE", "/admin/codes/items/" + types["AS"])
        print(
            "PASS: defaults/custom codes, validation, legacy null, edit/history, filters/statistics and Excel"
        )
    # Startup must not restore deleted types or duplicate the defaults.
    with TestClient(app):
        pass
    with TestClient(app) as client:
        headers = login("admin5678")
        items = call("GET", "/admin/codes/SERVICE_WORK_TYPE")["items"]
        assert [i["code"] for i in items].count("PO") == 1
        assert not any(i["code"] == "AS" for i in items)
        assert not any(i["code"] == "INSTALL" for i in items)
    print("PASS: restart seeding is idempotent and preserves deleted custom types")
finally:
    engine.dispose()
    TEMP.cleanup()
