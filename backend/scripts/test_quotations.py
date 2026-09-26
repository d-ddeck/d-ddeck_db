"""Quotation API/PDF regressions, isolated DB; optional synthetic review PDF."""

from __future__ import annotations

import copy
import hashlib
import io
import os
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
TEMP = tempfile.TemporaryDirectory(prefix="ddeck-quotes-")
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
    with TestClient(app) as c:

        def login(password):
            r = c.post(
                "/api/v1/auth/login", json={"email": "admin", "password": password}
            )
            return {"Authorization": "Bearer " + r.json()["access_token"]}

        headers = login("admin1234")

        def call(method, path, data=None, expected=200):
            r = c.request(method, "/api/v1" + path, json=data, headers=headers)
            assert r.status_code == expected, (path, r.status_code, r.text)
            return r.json()

        call(
            "POST",
            "/auth/change-password",
            {"current_password": "admin1234", "new_password": "admin5678"},
        )
        headers = login("admin5678")
        category = next(
            i["id"]
            for i in call("GET", "/admin/codes/SERVICE_CATEGORY")["items"]
            if i["code"] == "PROGRAM"
        )
        t = call(
            "POST",
            "/service/tickets",
            {"title": "견적 검증", "category_id": category},
            201,
        )
        t2 = call(
            "POST",
            "/service/tickets",
            {"title": "다른 대응", "category_id": category},
            201,
        )
        path = f"/service/tickets/{t['id']}/quotations"
        defaults = call("GET", path + "/defaults")
        assert defaults["supplier"]["company"] == ""
        assert call("GET", path) == []
        payload = {
            **defaults,
            "base_version": 0,
            "quote_date": "2026-09-27",
            "valid_until": "2026-10-27",
            "supplier": {
                "company": "검증용 공급회사",
                "contact": "검증 대표",
                "address": "서울시 테스트 주소",
                "phone": "02-000-0000",
                "email": "sample@example.test",
            },
            "recipient": {"company": "검증용 고객사", "contact": "담당자"},
            "bank_account": "검증용 계좌 (실제 계좌 아님)",
            "items": [
                {
                    "name": "정밀 부품 <A&B>",
                    "specification": "한글 규격 / 교체용",
                    "quantity": "1.005",
                    "unit_price": "100",
                    "note": "검증",
                }
            ],
            "notes": "견적 안내: 저장본 보존\n실제 거래용 견적서가 아닙니다.",
            "revision_note": "최초 작성",
        }
        v1 = call("POST", path, payload, 201)
        assert v1["version"] == 1 and v1["snapshot"]["subtotal"] == 101
        assert v1["snapshot"]["vat"] == 10 and v1["snapshot"]["total"] == 111
        assert "-v001_" in v1["filename"] and v1["filename"].endswith(".pdf")
        pdf1 = c.get("/api/v1" + path + "/" + v1["id"] + "/pdf", headers=headers)
        assert pdf1.status_code == 200 and pdf1.content.startswith(b"%PDF")
        assert hashlib.sha256(pdf1.content).hexdigest() == v1["sha256"]
        reader = PdfReader(io.BytesIO(pdf1.content))
        text = "".join(p.extract_text() for p in reader.pages)
        assert (
            "검증용 공급회사" in text and "정밀 부품 <A&B>" in text and "111" in text
        ), text
        assert len(reader.pages) == 1
        if "--sample-pdf" in sys.argv:
            dest = Path(sys.argv[sys.argv.index("--sample-pdf") + 1])
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(pdf1.content)
        updated = copy.deepcopy(payload)
        updated.update(base_version=1, revision_note="수량 수정")
        updated["items"][0]["quantity"] = "3"
        v2 = call("POST", path, updated, 201)
        assert v2["filename"] != v1["filename"] and v2["version"] == 2
        assert v2["snapshot"]["total"] == 330
        assert (
            c.get("/api/v1" + path + "/" + v1["id"] + "/pdf", headers=headers).content
            == pdf1.content
        )
        assert (
            call("GET", path + "/" + v1["id"])["snapshot"]["items"][0]["quantity"]
            == "1.005"
        )
        assert [r["version"] for r in call("GET", path)] == [2, 1]
        call("POST", path, updated, 409)
        call("PATCH", path + "/" + v1["id"], {}, 405)
        call("DELETE", path + "/" + v1["id"], expected=405)
        assert c.get("/api/v1" + path + "/" + v1["id"] + "/pdf").status_code == 401
        call(
            "GET",
            f"/service/tickets/{t2['id']}/quotations/{v1['id']}/pdf",
            expected=404,
        )
        for change in [
            {"items": []},
            {"valid_until": "2026-09-01"},
            {"items": [{"name": "", "quantity": 1, "unit_price": 10}]},
            {"items": [{"name": "항목", "quantity": -1, "unit_price": 10}]},
            {"items": [{"name": "항목", "quantity": "1.0001", "unit_price": 10}]},
            {"items": [{"name": "항목", "quantity": 1, "unit_price": "1.5"}]},
        ]:
            call("POST", path, {**payload, **change, "base_version": 2}, 422)
        # Rendering failure must leave no revision or consume a version number.
        with patch(
            "app.api.v1.quotations.render", side_effect=RuntimeError("render failure")
        ):
            try:
                call("POST", path, {**payload, "base_version": 2}, 201)
            except RuntimeError:
                pass
            else:
                raise AssertionError("render failure was ignored")
        assert len(call("GET", path)) == 2
        many = copy.deepcopy(payload)
        many["base_version"] = 2
        many["items"] = [
            {**payload["items"][0], "name": f"항목 {i + 1} 한글 품목"}
            for i in range(60)
        ]
        v3 = call("POST", path, many, 201)
        pdf3 = c.get(
            "/api/v1" + path + "/" + v3["id"] + "/pdf", headers=headers
        ).content
        reader = PdfReader(io.BytesIO(pdf3))
        assert len(reader.pages) > 1
        assert "항목 60" in "".join(p.extract_text() for p in reader.pages)

        # Two editors saving from the same base: exactly one new revision.
        def submit(_):
            return c.post(
                "/api/v1" + path, json={**payload, "base_version": 3}, headers=headers
            ).status_code

        with ThreadPoolExecutor(max_workers=2) as pool:
            assert sorted(pool.map(submit, range(2))) == [201, 409]
        assert [v["version"] for v in call("GET", path)] == [4, 3, 2, 1]
        call("DELETE", f"/service/tickets/{t['id']}")
        call("GET", path, expected=404)
        print(
            "PASS: quotation rounding, Korean PDF, immutable versions, concurrency, authorization, validation, failure rollback and multi-page PDF"
        )
finally:
    engine.dispose()
    TEMP.cleanup()
