"""Operational and priority 3 feature regressions, isolated from application data."""

import os
import sys
import tempfile
from datetime import timedelta
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


def main():
    with tempfile.TemporaryDirectory(prefix="ddeck-p345-") as tmp:
        os.environ.update(
            DATABASE_URL=f"sqlite:///{tmp}/test.db",
            STORAGE_DIR=f"{tmp}/storage",
            BACKUP_ROOT=tmp,
            ENVIRONMENT="test",
            DEBUG="false",
            SCHEDULER_ENABLED="false",
            AUTH_RATE_LIMIT_ENABLED="false",
            FIRST_SUPERADMIN_EMAIL="admin@ddeck.local",
            FIRST_SUPERADMIN_PASSWORD="Admin-test-1234",
        )
        from fastapi.testclient import TestClient
        from sqlalchemy import select

        from app.core.config import settings
        from app.core.database import SessionLocal
        from app.core.security import now_utc
        from app.main import app
        from app.models.admin import Attachment, ModuleSetting
        from app.models.calendar import Event
        from app.models.enums import ModuleKey, NotificationType
        from app.models.user import Device, User
        from app.services.notifications import dispatch_push, notify
        from app.services.retention import sweep

        count = 0
        with TestClient(app) as client:
            token = None

            def call(method, path, body=None, status=200):
                nonlocal count
                r = client.request(
                    method,
                    "/api/v1" + path,
                    json=body,
                    headers={"Authorization": f"Bearer {token}"} if token else {},
                )
                assert r.status_code == status, (path, r.status_code, r.text)
                count += 1
                return r.json()

            token = call(
                "POST", "/auth/login", {"email": "admin", "password": "Admin-test-1234"}
            )["access_token"]
            call(
                "POST",
                "/auth/change-password",
                {
                    "current_password": "Admin-test-1234",
                    "new_password": "Admin-test-5678",
                },
            )
            pair = call(
                "POST", "/auth/login", {"email": "admin", "password": "Admin-test-5678"}
            )
            token = pair["access_token"]
            call("POST", "/auth/refresh", {"refresh_token": pair["refresh_token"]})
            assert len(call("GET", "/auth/sessions")) == 1
            for url in ("/docs", "/redoc", "/openapi.json"):
                assert client.get(url).status_code == 404
            health = call("GET", "/admin/health")
            assert health["version"] == app.version
            assert health["backup"]["state"] == "google_drive"
            assert not health["backup"]["connected"]
            assert not health["backup"]["overdue"]  # Disabled schedules are not late.
            call("POST", "/admin/backup", status=503)
            store = call("POST", "/stores", {"name": "운영 검사"}, 201)
            location = call(
                "POST",
                "/inventory/locations",
                {"code": "PARTS", "name": "부품 창고"},
                201,
            )
            asset = call(
                "POST",
                "/inventory/assets",
                {"name": "교체 부품", "quantity": 5, "location_id": location["id"]},
                201,
            )
            call("PATCH", f"/inventory/assets/{asset['id']}", {"serial_no": "PART-001"})
            compared = call(
                "POST",
                "/inventory/delivery-compare",
                {"serials": ["part-001", "MISSING", "PART-001"]},
            )
            assert len(compared["found"]) == 1 and compared["missing"] == ["missing"]
            assert compared["duplicates"] == ["part-001"]
            import io

            from openpyxl import Workbook, load_workbook

            book = Workbook()
            book.active.append(["S/N"])
            book.active.append(["PART-001"])
            stream = io.BytesIO()
            book.save(stream)
            headers = {"Authorization": f"Bearer {token}"}
            reply = client.post(
                "/api/v1/inventory/delivery-compare/xlsx",
                headers=headers,
                files={"file": ("shipment.xlsx", stream.getvalue())},
            )
            assert reply.status_code == 200 and len(reply.json()["found"]) == 1
            reply = client.post(
                "/api/v1/inventory/delivery-compare/xlsx",
                headers=headers,
                files={"file": ("broken.xlsx", b"not an excel")},
            )
            assert reply.status_code == 400
            for category_name in ("shop", "robot", "ctrl", "panel", "serial"):
                reply = client.post(
                    "/api/v1/files",
                    headers=headers,
                    data={
                        "entity_type": "store",
                        "entity_id": store["id"],
                        "photo_category": category_name,
                    },
                    files={
                        "file": (category_name + ".png", b"test-image", "image/png")
                    },
                )
                assert reply.status_code == 201, reply.text
                rows = call(
                    "GET",
                    f"/files/by-entity/store/{store['id']}?photo_category={category_name}",
                )
                assert len(rows) == 1 and rows[0]["photo_category"] == category_name
            reply = client.post(
                "/api/v1/files",
                headers=headers,
                data={
                    "entity_type": "store",
                    "entity_id": store["id"],
                    "photo_category": "shop",
                },
                files={"file": ("note.txt", b"text", "text/plain")},
            )
            assert reply.status_code == 400
            category = next(
                i
                for i in call("GET", "/admin/codes/SERVICE_CATEGORY")["items"]
                if i["code"] == "PROGRAM"
            )
            ticket = call(
                "POST",
                "/service/tickets",
                {
                    "title": "검사",
                    "store_id": store["id"],
                    "category_id": category["id"],
                },
                201,
            )
            call("DELETE", f"/stores/{store['id']}", status=409)
            call("PATCH", f"/stores/{store['id']}", {"is_active": False})
            assert not call("GET", "/stores")["items"]
            assert (
                call("GET", "/stores?include_inactive=true&sort=ticket_count")["items"][
                    0
                ]["ticket_count"]
                == 1
            )
            with SessionLocal() as db:
                setting = db.scalar(
                    select(ModuleSetting).where(
                        ModuleSetting.module == ModuleKey.SERVICE,
                        ModuleSetting.key == "auto_deduct_parts",
                    )
                )
                setting.value = True
                db.commit()
            call(
                "POST",
                f"/service/tickets/{ticket['id']}/parts",
                {"part_name": "과다", "asset_id": asset["id"], "quantity": 6},
                409,
            )
            part = call(
                "POST",
                f"/service/tickets/{ticket['id']}/parts",
                {"part_name": "부품", "asset_id": asset["id"], "quantity": 2},
            )
            assert (
                float(call("GET", f"/inventory/assets/{asset['id']}")["quantity"]) == 3
            )
            call("DELETE", f"/service/tickets/{ticket['id']}/parts/{part['id']}")
            assert (
                float(call("GET", f"/inventory/assets/{asset['id']}")["quantity"]) == 5
            )
            call(
                "POST",
                f"/service/tickets/{ticket['id']}/logs",
                {"content": "추가", "work_minutes": 10},
            )
            log = call("GET", f"/service/tickets/{ticket['id']}")["logs"][-1]
            call(
                "PATCH",
                f"/service/tickets/{ticket['id']}/logs/{log['id']}",
                {"content": "수정", "work_minutes": 5},
            )
            call("DELETE", f"/service/tickets/{ticket['id']}/logs/{log['id']}")
            assert call("GET", f"/service/tickets/{ticket['id']}/history")["total"] > 0
            import io

            import openpyxl

            headers = {"Authorization": f"Bearer {token}"}
            response = client.get("/api/v1/service/stats/all.xlsx", headers=headers)
            assert response.status_code == 200, response.text
            workbook = openpyxl.load_workbook(io.BytesIO(response.content))
            assert set(workbook.sheetnames) == {
                "업무 구분",
                "서비스구분",
                "세부분류",
                "제조사",
                "브랜드",
                "매장",
                "대응인원",
                "연도별 서비스구분",
                "제조사 연도별",
                "브랜드 연도별",
                "매장 연도별",
            }
            assert call("GET", f"/inventory/assets/{asset['id']}/tickets")["total"] == 0
            assert call("GET", "/service/tickets?missing=maker")["total"] == 1
            call("GET", "/service/tickets?missing=invalid", status=400)
            call("GET", "/service/tickets?sort=store_desc")
            history_rows = call("GET", f"/service/tickets/{ticket['id']}/history")[
                "items"
            ]
            history_id = history_rows[0]["id"]
            call("DELETE", f"/admin/history/audit/{history_id}", status=403)
            from app.core.deps import ClientInfo, client_info

            app.dependency_overrides[client_info] = lambda: ClientInfo(
                "127.0.0.1", "local-test"
            )
            try:
                call("DELETE", f"/admin/history/audit/{history_id}")
                assert history_id not in {
                    row["id"]
                    for row in call("GET", f"/service/tickets/{ticket['id']}/history")[
                        "items"
                    ]
                }
                moves = call("GET", f"/inventory/assets/{asset['id']}/movements")[
                    "items"
                ]
                call("DELETE", f"/admin/history/movement/{moves[0]['id']}")
                call("DELETE", f"/admin/history/movement/{moves[0]['id']}", status=404)
            finally:
                app.dependency_overrides.pop(client_info)
            with SessionLocal() as db:
                from app.models.admin import AuditLog
                from app.models.inventory import AssetMovement

                assert db.get(AuditLog, __import__("uuid").UUID(history_id)).hidden_at
                assert db.get(
                    AssetMovement, __import__("uuid").UUID(moves[0]["id"])
                ).hidden_at
            exported = client.get("/api/v1/service/stats/all.xlsx", headers=headers)
            assert exported.status_code == 200, (
                exported.text if exported.status_code != 200 else ""
            )
            sheets = load_workbook(io.BytesIO(exported.content))
            assert sheets.sheetnames == workbook.sheetnames
            sheets.close()
            calendar = call("POST", "/calendar/calendars", {"name": "반복 검사"}, 201)
            start = now_utc() + timedelta(days=1)
            event = call(
                "POST",
                "/calendar/events",
                {
                    "calendar_id": calendar["id"],
                    "title": "반복",
                    "starts_at": start.isoformat(),
                    "ends_at": (start + timedelta(hours=1)).isoformat(),
                    "rrule": "FREQ=DAILY;COUNT=3",
                },
                201,
            )
            with SessionLocal() as db:
                events = db.scalars(select(Event)).all()
                assert len(events) == 3
            call("PATCH", f"/calendar/events/{event['id']}", {"title": "반복 수정"})
            with SessionLocal() as db:
                assert all(e.title == "반복 수정" for e in db.scalars(select(Event)))
            call(
                "PATCH",
                f"/calendar/events/{event['id']}",
                {"rrule": "FREQ=SECONDLY"},
                400,
            )
            with SessionLocal() as db:
                child = db.scalar(
                    select(Event).where(Event.recurrence_parent_id.is_not(None))
                )
                child_id = str(child.id)
            reply = client.post(
                "/api/v1/files",
                headers=headers,
                data={"entity_type": "event", "entity_id": child_id},
                files={"file": ("child.txt", b"child", "text/plain")},
            )
            assert reply.status_code == 201, reply.text
            child_file_id = reply.json()["id"]
            call("PATCH", f"/calendar/events/{event['id']}", {"title": "첨부 보존"})
            assert len(call("GET", f"/files/by-entity/event/{child_id}")) == 1
            call("DELETE", f"/calendar/events/{event['id']}")
            with SessionLocal() as db:
                assert all(e.deleted_at for e in db.scalars(select(Event)))
                assert db.get(
                    Attachment, __import__("uuid").UUID(child_file_id)
                ).deleted_at
                user = db.scalar(select(User))
                settings.FCM_PROJECT_ID = "test-project"
                settings.FCM_CREDENTIALS_FILE = "mock.json"
                row = notify(
                    db, user_ids=[user.id], type=NotificationType.SYSTEM, title="queued"
                )[0]
                db.add(
                    Device(
                        user_id=user.id,
                        platform="ANDROID",
                        push_token="mock-token",
                        is_active=True,
                    )
                )
                db.commit()
                with patch(
                    "app.services.notifications.send_push", return_value=set()
                ) as send:
                    assert dispatch_push(db) == 1 and send.call_count == 1
                    assert dispatch_push(db) == 0
                assert row.pushed_at and not row.push_pending
                retry = notify(
                    db, user_ids=[user.id], type=NotificationType.SYSTEM, title="retry"
                )[0]
                db.commit()
                with patch(
                    "app.services.notifications.send_push",
                    side_effect=RuntimeError("offline"),
                ):
                    dispatch_push(db)
                assert (
                    retry.push_pending
                    and retry.push_attempts == 1
                    and retry.push_after > now_utc()
                )
                path = settings.storage_path / "old.txt"
                path.write_text("deleted file")
                file = Attachment(
                    entity_type="service_ticket",
                    entity_id=__import__("uuid").UUID(ticket["id"]),
                    original_name="old.txt",
                    stored_path="old.txt",
                    deleted_at=now_utc() - timedelta(days=31),
                )
                db.add(file)
                db.commit()
                assert sweep(db)["attachments"] == 1 and not path.exists()
            with SessionLocal() as db:
                from reset_admin import recover

                from app.core.security import verify_password
                from app.models.user import RefreshToken

                admin_user = db.scalar(select(User))
                recover(db, admin_user, "Recovered-Password-9876")
                assert verify_password(
                    "Recovered-Password-9876", admin_user.password_hash
                )
                assert admin_user.must_change_password
                assert all(row.revoked_at for row in db.scalars(select(RefreshToken)))
                assert all(not row.is_active for row in db.scalars(select(Device)))
        print(
            f"PASS: {count} priority 3–5 API assertions plus recurrence, stock reversal, FCM outbox and retention invariants"
        )


if __name__ == "__main__":
    main()
