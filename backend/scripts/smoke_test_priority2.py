"""Priority 2 regressions. Uses only a temporary SQLite DB/storage directory."""

import os
import sys
import tempfile
import uuid
from datetime import timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def main():
    with tempfile.TemporaryDirectory(prefix="ddeck-p2-") as tmp:
        os.environ.update(
            DATABASE_URL=f"sqlite:///{tmp}/test.db",
            STORAGE_DIR=f"{tmp}/storage",
            ENVIRONMENT="test",
            DEBUG="false",
            SCHEDULER_ENABLED="false",
            AUTH_RATE_LIMIT_ENABLED="false",
            FIRST_SUPERADMIN_EMAIL="admin@ddeck.local",
            FIRST_SUPERADMIN_PASSWORD="Admin-test-1234",
        )
        from app.core.config import settings
        from app.core.database import SessionLocal
        from app.core.deps import client_info
        from app.core.security import hash_password, hash_refresh_token, now_utc
        from app.main import app
        from app.models.enums import Role, UserStatus
        from app.models.service import ServiceTicketCause
        from app.models.user import Device, RefreshToken, User
        from fastapi.testclient import TestClient
        from sqlalchemy import select, text
        from sqlalchemy.exc import IntegrityError
        from starlette.requests import Request

        count = 0
        with TestClient(app, raise_server_exceptions=False) as client:

            def call(method, path, body=None, status=200, token=None, **kwargs):
                nonlocal count
                response = client.request(
                    method,
                    "/api/v1" + path,
                    json=body,
                    headers={"Authorization": "Bearer " + token} if token else {},
                    **kwargs,
                )
                assert response.status_code == status, (
                    path,
                    response.status_code,
                    response.text,
                )
                count += 1
                return response.json()

            def login():
                return call(
                    "POST",
                    "/auth/login",
                    {"email": "admin", "password": "Admin-test-5678"},
                )

            first = call(
                "POST", "/auth/login", {"email": "admin", "password": "Admin-test-1234"}
            )
            call(
                "POST",
                "/auth/change-password",
                {
                    "current_password": "Admin-test-1234",
                    "new_password": "Admin-test-5678",
                },
                token=first["access_token"],
            )
            call("GET", "/auth/me", status=401, token=first["access_token"])
            one, two = login(), login()
            call(
                "POST",
                "/auth/devices",
                {"platform": "ANDROID", "push_token": "test-push"},
                token=one["access_token"],
            )
            rotated = call(
                "POST", "/auth/refresh", {"refresh_token": one["refresh_token"]}
            )
            assert rotated["refresh_token"] != one["refresh_token"]
            call("GET", "/auth/me", token=one["access_token"])
            call(
                "POST",
                "/auth/refresh",
                {"refresh_token": one["refresh_token"]},
                status=401,
            )
            call("GET", "/auth/me", status=401, token=rotated["access_token"])
            call("GET", "/auth/me", status=401, token=two["access_token"])
            with SessionLocal() as db:
                assert db.scalar(select(Device)).is_active is False
            one, two = login(), login()
            call(
                "POST",
                "/auth/devices",
                {"platform": "ANDROID", "push_token": "test-push"},
                token=one["access_token"],
            )
            call(
                "POST",
                "/auth/logout",
                {"refresh_token": one["refresh_token"]},
                token=one["access_token"],
            )
            call("GET", "/auth/me", status=401, token=one["access_token"])
            call("GET", "/auth/me", token=two["access_token"])
            with SessionLocal() as db:
                assert not db.scalar(select(Device)).is_active
                row = db.scalar(
                    select(RefreshToken).where(
                        RefreshToken.token_hash
                        == hash_refresh_token(two["refresh_token"])
                    )
                )
                session_row_id = str(row.id)
            call(
                "DELETE", f"/auth/sessions/{session_row_id}", token=two["access_token"]
            )
            call("GET", "/auth/me", status=401, token=two["access_token"])
            one = login()
            with SessionLocal() as db:
                admin = db.scalar(select(User).where(User.email == "admin@ddeck.local"))
                admin.locked_until = now_utc() + timedelta(minutes=1)
                db.commit()
            call(
                "POST",
                "/auth/refresh",
                {"refresh_token": one["refresh_token"]},
                status=423,
            )
            with SessionLocal() as db:
                admin = db.scalar(select(User).where(User.email == "admin@ddeck.local"))
                admin.locked_until = None
                member = User(
                    email="member@example.com",
                    full_name="사원",
                    password_hash=hash_password("Member-1234"),
                    status=UserStatus.APPROVED,
                    role=Role.MEMBER,
                )
                db.add(member)
                db.commit()
            admin_token = one["access_token"]

            def api(method, path, body=None, status=200):
                return call(method, path, body, status, admin_token)

            me = api("GET", "/auth/me")
            api("PATCH", "/users/" + me["id"], {"role": "MEMBER"}, 400)
            api("PATCH", "/users/" + me["id"], {"status": "SUSPENDED"}, 400)
            api("PATCH", "/auth/me", {"full_name": None}, 422)
            api("PATCH", "/auth/me", {"phone": None})
            api(
                "PUT",
                "/admin/settings/SYSTEM",
                {
                    "settings": [
                        {
                            "key": "unsupported",
                            "value": True,
                            "value_type": "bool",
                            "label": "x",
                        }
                    ]
                },
                400,
            )
            member_session = call(
                "POST",
                "/auth/login",
                {"email": "member@example.com", "password": "Member-1234"},
            )
            store = api("POST", "/stores", {"name": "폐점 테스트"}, 201)
            call(
                "POST",
                f"/stores/{store['id']}/close",
                {},
                403,
                member_session["access_token"],
            )
            api("POST", f"/stores/{store['id']}/close", {})
            category = next(
                i
                for i in api("GET", "/admin/codes/SERVICE_CATEGORY")["items"]
                if i["code"] == "PROGRAM"
            )
            ticket = api(
                "POST",
                "/service/tickets",
                {
                    "title": "검사",
                    "category_id": category["id"],
                    "store_id": store["id"],
                },
                201,
            )
            assert ticket["notices"]
            listed = api("GET", "/stores?include_closed=true")
            assert (
                next(s for s in listed["items"] if s["id"] == store["id"])[
                    "open_ticket_count"
                ]
                == 1
            )
            grouped = api("GET", "/service/stats/grouped?group_by=category")
            assert grouped["buckets"][0]["key"] == category["id"]
            api("PATCH", f"/admin/codes/items/{category['id']}", {"is_active": False})
            api(
                "POST",
                "/service/tickets",
                {"title": "비활성", "category_id": category["id"]},
                400,
            )
            api("PATCH", f"/admin/codes/items/{category['id']}", {"is_active": True})
            api("PATCH", f"/service/tickets/{ticket['id']}", {"title": None}, 422)
            api("PATCH", f"/service/tickets/{ticket['id']}", {"labor_cost": -1}, 422)
            api(
                "GET",
                "/service/tickets?date_from=2026-02-01T00:00:00&date_to=2026-01-01T00:00:00Z",
                status=400,
            )
            api("GET", "/worklogs?year=1", status=422)
            loc = api(
                "POST", "/inventory/locations", {"name": "상위", "code": "PARENT"}, 201
            )
            child = api(
                "POST",
                "/inventory/locations",
                {"name": "하위", "code": "CHILD", "parent_id": loc["id"]},
                201,
            )
            api(
                "PATCH",
                f"/inventory/locations/{loc['id']}",
                {"parent_id": child["id"]},
                400,
            )
            api("DELETE", f"/inventory/locations/{loc['id']}", status=400)
            api("POST", "/inventory/assets", {"name": "음수", "quantity": -1}, 422)
            api(
                "POST",
                "/inventory/assets",
                {"name": "유일성", "serial_no": "P2-unique", "location_id": loc["id"]},
                201,
            )
            with SessionLocal() as db:
                try:
                    db.execute(
                        text(
                            "INSERT INTO assets (id, asset_no, name, serial_no, status, quantity, unit) VALUES (:id, 'P2-DUP', 'dup', ' p2-UNIQUE ', 'IN_STOCK', 1, 'EA')"
                        ),
                        {"id": uuid.uuid4().hex},
                    )
                    db.commit()
                    raise AssertionError("DB accepted duplicate serial")
                except IntegrityError:
                    db.rollback()
                db.query(ServiceTicketCause).filter(
                    ServiceTicketCause.ticket_id == uuid.UUID(ticket["id"])
                ).delete()
                db.commit()
            grouped = api("GET", "/service/stats/grouped?group_by=category")
            assert grouped["tickets_without_cause"] == 1 and grouped["total"] == 1
            api(
                "PUT",
                "/admin/settings/SYSTEM",
                {
                    "settings": [
                        {
                            "key": "maintenance_mode",
                            "value": True,
                            "value_type": "bool",
                            "label": "점검",
                        }
                    ]
                },
            )
            call("GET", "/stores", status=503, token=member_session["access_token"])
            api("GET", "/stores")
            # Reject before multipart parsing or target lookup.
            response = client.post(
                "/api/v1/files",
                headers={"Content-Length": str(30 * 1024 * 1024)},
                content=b"x",
            )
            assert response.status_code == 413
            settings.TRUSTED_PROXY_IPS = "127.0.0.1"

            def ip(peer, forwarded):
                return client_info(
                    Request(
                        {
                            "type": "http",
                            "client": (peer, 123),
                            "headers": [(b"x-forwarded-for", forwarded.encode())],
                        }
                    )
                ).ip

            assert ip("10.0.0.1", "1.2.3.4") == "10.0.0.1"
            assert ip("127.0.0.1", "9.9.9.9, 10.0.0.1") == "10.0.0.1"
            settings.AUTH_RATE_LIMIT_ENABLED = True
            for _ in range(20):
                call(
                    "POST",
                    "/auth/login",
                    {"email": "nobody@example.com", "password": "Wrong-1234"},
                    401,
                )
            call(
                "POST",
                "/auth/login",
                {"email": "nobody@example.com", "password": "Wrong-1234"},
                429,
            )
            print(
                f"PASS: {count} API assertions plus refresh/device, DB uniqueness, upload, proxy and statistics invariants"
            )


if __name__ == "__main__":
    main()
