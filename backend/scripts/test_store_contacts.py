"""Extensible service work types: API, history, filters and exports in a temporary DB."""

from __future__ import annotations

import os
import sys
import tempfile
from io import BytesIO
from pathlib import Path

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
from pypdf import PdfReader

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
        first = call(
            "POST",
            "/stores",
            {
                "name": "연락정보 매장",
                "contact_name": "홍담당",
                "contact_phone": "010-0000-0001",
                "address": "서울 테스트로 1",
            },
            201,
        )
        second = call(
            "POST",
            "/stores",
            {
                "name": "두번째 매장",
                "contact_name": "김담당",
                "contact_phone": "010-0000-0002",
                "address": "부산 테스트로 2",
            },
            201,
        )
        category = next(
            i["id"]
            for i in call("GET", "/admin/codes/SERVICE_CATEGORY")["items"]
            if i["code"] == "PROGRAM"
        )
        base = {
            "title": "연락정보 검증",
            "category_id": category,
            "store_id": first["id"],
        }
        ticket = call("POST", "/service/tickets", base, 201)
        path = "/service/tickets/" + ticket["id"]
        assert (
            ticket["contact_name"],
            ticket["contact_phone"],
            ticket["site_address"],
        ) == (first["contact_name"], first["contact_phone"], first["address"])
        call(
            "PATCH",
            "/stores/" + first["id"],
            {
                "contact_name": "새담당",
                "contact_phone": "02-0000-0000",
                "address": "수정 주소",
            },
        )
        unchanged = call("PATCH", path, {"store_id": first["id"], "title": "제목 수정"})
        assert (
            unchanged["contact_name"] == "홍담당"
            and unchanged["site_address"] == first["address"]
        )
        recipient = call("GET", path + "/quotations/defaults")["recipient"]
        assert (
            recipient["contact"] == "홍담당"
            and recipient["address"] == first["address"]
            and recipient["phone"] == first["contact_phone"]
        )
        defaults = call("GET", path + "/quotations/defaults")
        quote = call(
            "POST",
            path + "/quotations",
            {
                **defaults,
                "base_version": 0,
                "supplier": {"company": "검증 공급사"},
                "items": [
                    {"name": "장비 점검", "quantity": "1", "unit_price": "10000"}
                ],
            },
            201,
        )
        pdf_path = "/api/v1" + path + "/quotations/" + quote["id"] + "/pdf"
        original_pdf = client.get(pdf_path, headers=headers).content
        pdf_text = "".join(
            page.extract_text() for page in PdfReader(BytesIO(original_pdf)).pages
        )
        assert (
            "홍담당" in pdf_text
            and first["contact_phone"] in pdf_text
            and first["address"] in pdf_text
        )
        changed = call("PATCH", path, {"store_id": second["id"]})
        assert client.get(pdf_path, headers=headers).content == original_pdf
        assert (
            changed["contact_name"] == "김담당"
            and changed["site_address"] == second["address"]
        )
        explicit = call(
            "POST",
            "/service/tickets",
            {
                **base,
                "contact_name": "직접 입력",
                "contact_phone": None,
                "site_address": "현장 별도 주소",
            },
            201,
        )
        assert (
            explicit["contact_name"] == "직접 입력"
            and explicit["contact_phone"] is None
            and explicit["site_address"] == "현장 별도 주소"
        )
        call(
            "PATCH",
            "/stores/" + first["id"],
            {"contact_name": None, "contact_phone": None, "address": None},
        )
        cleared = call("GET", "/stores/" + first["id"])
        assert cleared["contact_name"] is None and cleared["address"] is None
        legacy = call(
            "POST",
            "/service/tickets",
            {**base, "store_id": second["id"], "contact_name": None},
            201,
        )
        assert (
            call("GET", "/service/tickets/" + legacy["id"] + "/quotations/defaults")[
                "recipient"
            ]["contact"]
            == "김담당"
        )
        call("PATCH", "/stores/" + second["id"], {"address": "가" * 301}, 422)
        print(
            "Store contacts: CRUD, service snapshots, overrides, store changes and quotation defaults passed"
        )
finally:
    engine.dispose()
    TEMP.cleanup()
