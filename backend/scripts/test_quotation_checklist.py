"""견적서 체크리스트 설정·조회·견적 저장 회귀 테스트. 격리된 DB만 쓴다."""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
TEMP = tempfile.TemporaryDirectory(prefix="ddeck-checklist-")
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

from app.core.database import engine
from app.main import app

RAINBOW_NOTES = "레인보우 로봇 입고 시 전원을 차단하고 포장 상태로 보관하세요."

try:
    with TestClient(app) as c:

        def login(password):
            r = c.post("/api/v1/auth/login", json={"email": "admin", "password": password})
            return {"Authorization": "Bearer " + r.json()["access_token"]}

        headers = login("admin1234")

        def call(method, path, data=None, expected=200):
            r = c.request(method, "/api/v1" + path, json=data, headers=headers)
            assert r.status_code == expected, (path, r.status_code, r.text)
            return r.json()

        call("POST", "/auth/change-password", {"current_password": "admin1234", "new_password": "admin5678"})
        headers = login("admin5678")

        def save_checklist(value, expected=200):
            return call(
                "PUT",
                "/admin/settings/SERVICE",
                {"settings": [{"key": "quotation_checklist", "value": value, "value_type": "json", "is_public": False}]},
                expected,
            )

        # Seeded empty and offered to the quotation screen as an empty list.
        seeded = next(s for s in call("GET", "/admin/settings/SERVICE")["settings"] if s["key"] == "quotation_checklist")
        assert seeded["value"] == [] and seeded["value_type"] == "json"
        assert call("GET", "/service/quotations/checklist") == []

        # Saved values are normalized: ids kept, numbers as quotation strings.
        saved = save_checklist([
            {
                "id": "rainbow",
                "label": " 레인보우 입고 ",
                "notes": RAINBOW_NOTES,
                "items": [{"name": "입고 점검", "specification": "RB5", "quantity": "1.50", "unit_price": 120000, "note": ""}],
            },
            {"id": "old", "label": "사용 안 하는 항목", "notes": "예전 문구", "active": False},
        ])
        stored = next(s for s in saved["settings"] if s["key"] == "quotation_checklist")["value"]
        assert stored[0] == {
            "id": "rainbow",
            "label": "레인보우 입고",
            "notes": RAINBOW_NOTES,
            "items": [{"name": "입고 점검", "specification": "RB5", "quantity": "1.5", "unit_price": "120000", "note": ""}],
            "active": True,
        }, stored[0]
        assert stored[1]["active"] is False

        # The quotation screen only gets active entries.
        offered = call("GET", "/service/quotations/checklist")
        assert [e["id"] for e in offered] == ["rainbow"]

        # Invalid entries are rejected with a message naming the problem.
        for value, needle in [
            ("not a list", "목록"),
            ([{"id": "x", "label": "", "notes": "a"}], "이름"),
            ([{"id": "x", "label": "빈 항목"}], "안내사항이나 품목"),
            ([{"id": "x", "label": "a", "notes": "a"}, {"id": "x", "label": "b", "notes": "b"}], "중복"),
            ([{"id": "x", "label": "단가", "items": [{"name": "p", "quantity": "1", "unit_price": "-5"}]}], "품목"),
            ([{"id": "../x", "label": "a", "notes": "a"}], "id"),
        ]:
            r = save_checklist(value, 400)
            assert r["error"]["code"] == "INVALID_SETTING_VALUE" and needle in r["error"]["message"], r
        assert [e["id"] for e in call("GET", "/service/quotations/checklist")] == ["rainbow"], "rejected save changed the value"

        # Checked ids are kept in the quotation snapshot for the next version.
        category = next(i["id"] for i in call("GET", "/admin/codes/SERVICE_CATEGORY")["items"] if i["code"] == "PROGRAM")
        ticket = call("POST", "/service/tickets", {"title": "체크리스트 견적", "category_id": category}, 201)
        path = f"/service/tickets/{ticket['id']}/quotations"
        body = call("GET", path + "/defaults")
        body.update(
            base_version=0,
            recipient={**body["recipient"], "company": "수신처"},
            items=[{"name": "입고 점검", "specification": "RB5", "quantity": "1.5", "unit_price": "120000", "note": ""}],
            notes=RAINBOW_NOTES,
            checks=["rainbow"],
        )
        body.pop("checklist", None)
        created = call("POST", path, body, 201)
        assert created["snapshot"]["checks"] == ["rainbow"]
        assert created["snapshot"]["notes"] == RAINBOW_NOTES
        assert call("GET", f"{path}/{created['id']}")["snapshot"]["checks"] == ["rainbow"]
        bad = dict(body, base_version=1, checks=["x" * 41])
        call("POST", path, bad, 422)
    print("quotation checklist tests passed")
finally:
    engine.dispose()
    TEMP.cleanup()
