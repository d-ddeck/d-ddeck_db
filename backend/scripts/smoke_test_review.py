"""Review regressions: rental ownership, inventory enum moves, service transitions."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
TEMP = tempfile.TemporaryDirectory(prefix="ddeck-review-")
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

PASSED = 0


def check(label, condition):
    global PASSED
    assert condition, label
    PASSED += 1
    print(f"PASS: {label}")


try:
    with TestClient(app) as c:
        login = c.post(
            "/api/v1/auth/login", json={"email": "admin", "password": "admin1234"}
        )
        H = {"Authorization": f"Bearer {login.json()['access_token']}"}

        def call(method, path, body=None, expected=200):
            r = c.request(method, "/api/v1" + path, headers=H, json=body)
            assert r.status_code == expected, (method, path, r.status_code, r.text)
            return r.json()

        call(
            "POST",
            "/auth/change-password",
            {"current_password": "admin1234", "new_password": "admin5678"},
        )
        H = {
            "Authorization": "Bearer "
            + c.post(
                "/api/v1/auth/login", json={"email": "admin", "password": "admin5678"}
            ).json()["access_token"]
        }

        def codes(group):
            return call("GET", "/admin/codes/" + group)

        category = next(
            i for i in codes("SERVICE_CATEGORY")["items"] if i["code"] == "PROGRAM"
        )["id"]
        rental_group = codes("SERVICE_RENTAL_TYPE")
        rental_type = call(
            "POST",
            f"/admin/codes/{rental_group['id']}/items",
            {"code": "TEST", "name": "검사 장비"},
            201,
        )["id"]
        responder_group = codes("SERVICE_RESPONDER")
        responder = call(
            "POST",
            f"/admin/codes/{responder_group['id']}/items",
            {"code": "TEST", "name": "검사 담당"},
            201,
        )["id"]
        store = call("POST", "/stores", {"name": "검사 매장"}, 201)["id"]
        status_items = {i["name"]: i["id"] for i in codes("ASSET_STATUS")["items"]}
        asset_ids = {}
        for sn in ["REVIEW-A", "REVIEW-B"]:
            asset_ids[sn] = call(
                "POST",
                "/inventory/assets",
                {"name": sn, "serial_no": sn, "status_item_id": status_items["창고"]},
                201,
            )["id"]

        def asset(sn):
            return call("GET", "/inventory/assets/" + asset_ids[sn])

        def move(sn, **body):
            return call(
                "POST",
                f"/inventory/assets/{asset_ids[sn]}/move",
                {"movement_type": "MOVE", **body},
            )

        def ticket(**body):
            return call(
                "POST",
                "/service/tickets",
                {
                    "title": "검사",
                    "category_id": category,
                    "received_at": "2026-01-01T00:00:00Z",
                    "store_id": store,
                    **body,
                },
                201,
            )

        def rental(serials):
            return ticket(
                is_rental=True,
                rental_type_id=rental_type,
                rental_serials=serials,
                rental_due_date="2026-12-31",
            )

        def patch(t, **body):
            return call("PATCH", f"/service/tickets/{t['id']}", body)

        def delete(t):
            return call("DELETE", f"/service/tickets/{t['id']}")

        t = rental("REVIEW-A, REVIEW-B")
        patch(t, rental_serials="review-b")
        check(
            "removed serial returned, retained serial stays loaned",
            asset("REVIEW-A")["status"] == "IN_STOCK"
            and asset("REVIEW-B")["status"] == "LOANED",
        )
        patch(t, is_rental=False)
        check(
            "disabling rental returns unreturned asset",
            asset("REVIEW-B")["status"] == "IN_STOCK"
            and asset("REVIEW-B")["store_id"] is None,
        )
        t = rental("REVIEW-A")
        delete(t)
        check(
            "deleting rental returns asset",
            asset("REVIEW-A")["status_item"]["name"] == "창고",
        )
        t = rental("REVIEW-A")
        move("REVIEW-A", to_status="REPAIR", moved_at="2025-01-01T00:00:00Z")
        patch(t, is_rental=False)
        check(
            "backdated manual move is preserved on unlink",
            asset("REVIEW-A")["status"] == "REPAIR",
        )
        t = rental("REVIEW-A")
        newer = rental("REVIEW-A")
        delete(t)
        check(
            "newer rental ownership is preserved even at same store/status",
            asset("REVIEW-A")["status"] == "LOANED",
        )
        delete(newer)
        check(
            "latest owning rental can return asset",
            asset("REVIEW-A")["status"] == "IN_STOCK",
        )
        move("REVIEW-A", to_store_id=store, to_status="IN_USE")
        a = move("REVIEW-A", movement_type="DISPOSE")
        check(
            "DISPOSE synchronizes enum/detail/store",
            a["status"] == "DISPOSED"
            and a["status_item"]["name"] == "폐기"
            and a["store_id"] is None
            and a["set_no"] == 0,
        )
        a = move("REVIEW-A", to_status="IN_STOCK")
        check(
            "enum-only return synchronizes location",
            a["status_item"]["name"] == "창고" and a["location"]["name"] == "창고",
        )
        call(
            "POST",
            f"/inventory/assets/{asset_ids['REVIEW-A']}/move",
            {
                "movement_type": "MOVE",
                "to_status": "DISPOSED",
                "to_status_item_id": status_items["창고"],
            },
            400,
        )
        check(
            "contradictory status request leaves asset unchanged",
            asset("REVIEW-A")["status"] == "IN_STOCK",
        )
        t = ticket(responder_ids=[responder])
        path = f"/service/tickets/{t['id']}"
        call(
            "POST",
            path + "/status",
            {
                "status": "COMPLETED",
                "result_note": "완료",
                "completed_at": "2025-12-31T23:59:59Z",
            },
            400,
        )
        check(
            "completion before receipt rejected atomically",
            call("GET", path)["status"] == "RECEIVED",
        )
        call(
            "POST",
            path + "/status",
            {
                "status": "COMPLETED",
                "result_note": "완료",
                "completed_at": "2026-01-02T00:00:00",
            },
        )
        call("PATCH", path, {"received_at": "2026-01-03T00:00:00Z"}, 400)
        check(
            "receipt edits cannot make negative duration",
            call("GET", path)["received_at"].startswith("2026-01-01"),
        )
        call(
            "POST", path + "/logs", {"content": "접수로", "to_status": "RECEIVED"}, 400
        )
        reopened = call("POST", path + "/status", {"status": "IN_PROGRESS"})
        check(
            "reopen clears result and completion timestamp",
            reopened["completed_at"] is None and reopened["result_note"] is None,
        )
        call("POST", path + "/status", {"status": "CANCELED"})
        call(
            "POST",
            path + "/logs",
            {"content": "종결 우회", "to_status": "COMPLETED"},
            400,
        )
        check(
            "canceled cannot complete through logs",
            call("GET", path)["status"] == "CANCELED",
        )
        call("POST", path + "/status", {"status": "IN_PROGRESS"})
        check(
            "canceled can explicitly reopen",
            call("GET", path)["status"] == "IN_PROGRESS",
        )
    sentinel = Path(TEMP.name) / "production.db"
    sentinel.write_bytes(b"do not touch production data")
    env = {
        **os.environ,
        "ENVIRONMENT": "production",
        "CORS_ORIGINS": "",
        "SECRET_KEY": "production-guard-test-key-only-1234567890",
        "FIRST_SUPERADMIN_PASSWORD": "Safe-test-password-1234",
        "DATABASE_URL": f"sqlite+pysqlite:///{sentinel.as_posix()}",
    }
    blocked = subprocess.run(
        [sys.executable, str(ROOT / "scripts/seed_demo.py"), "--reset"],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    check(
        "production demo reset refuses before database access",
        blocked.returncode != 0
        and "운영 환경에서는" in blocked.stderr
        and sentinel.read_bytes() == b"do not touch production data",
    )
    print(f"Passed {PASSED} review regressions")
finally:
    engine.dispose()
    TEMP.cleanup()
