"""PostgreSQL CI integration. Requires a disposable ddeck_test database."""

import atexit
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from sqlalchemy import create_engine, inspect, text
from sqlalchemy.engine import make_url


def main():
    url = os.environ["TEST_POSTGRES_URL"]
    parsed = make_url(url)
    if parsed.database != "ddeck_test":
        raise SystemExit("Only disposable database ddeck_test is accepted")
    workspace = tempfile.TemporaryDirectory(prefix="ddeck-pg-api-")
    atexit.register(workspace.cleanup)
    os.environ.update(
        STORAGE_DIR=str(Path(workspace.name) / "storage"),
        DATABASE_URL=url,
        DEBUG="false",
        ENVIRONMENT="test",
        SCHEDULER_ENABLED="false",
        FIRST_SUPERADMIN_PASSWORD="CI-only-Test-1234",
        FIRST_SUPERADMIN_EMAIL="admin@ddeck.local",
        SECRET_KEY="disposable-postgres-test-key-0123456789abcdef",
        CORS_ORIGINS="http://localhost",
        AUTH_RATE_LIMIT_ENABLED="false",
    )
    root = Path(__file__).resolve().parents[1]
    for args in [("upgrade", "head"), ("check",)]:
        subprocess.run([sys.executable, "-m", "alembic", *args], cwd=root, check=True)
    sys.path.insert(0, str(root))
    from unittest.mock import patch

    from fastapi.testclient import TestClient

    from app.main import app
    from app.models import Base

    engine = create_engine(url)
    assert len(set(inspect(engine).get_table_names()) - {"alembic_version"}) == 31
    with engine.connect() as connection:
        assert connection.scalar(text("SELECT count(*) FROM alembic_version")) == 1
    with patch.object(
        Base.metadata, "create_all", side_effect=AssertionError("unexpected DDL")
    ):
        os.environ["ENVIRONMENT"] = "production"
        # lifespan checks the settings singleton, not the environment after import.
        from app.core.config import settings

        settings.ENVIRONMENT = "production"
        with TestClient(app) as client:
            assert client.get("/healthz").status_code == 200
            login = client.post(
                "/api/v1/auth/login",
                json={"email": "admin", "password": "CI-only-Test-1234"},
            )
            assert login.status_code == 200, login.text
            headers = {"Authorization": "Bearer " + login.json()["access_token"]}
            assert client.get("/api/v1/auth/me", headers=headers).status_code == 200

            def call(method, path, body=None, expected=200):
                response = client.request(
                    method, "/api/v1" + path, json=body, headers=headers
                )
                assert response.status_code == expected, (
                    path,
                    response.status_code,
                    response.text,
                )
                return response.json()

            call(
                "POST",
                "/auth/change-password",
                {
                    "current_password": "CI-only-Test-1234",
                    "new_password": "CI-only-Updated-5678",
                },
            )
            renewed = client.post(
                "/api/v1/auth/login",
                json={"email": "admin", "password": "CI-only-Updated-5678"},
            )
            assert renewed.status_code == 200
            headers = {"Authorization": "Bearer " + renewed.json()["access_token"]}
            store = call("POST", "/stores", {"name": "PG 한글 매장"}, 201)
            category = next(
                item
                for item in call("GET", "/admin/codes/SERVICE_CATEGORY")["items"]
                if item["code"] == "PROGRAM"
            )
            ticket = call(
                "POST",
                "/service/tickets",
                {
                    "title": "PG 검사",
                    "store_id": store["id"],
                    "category_id": category["id"],
                },
                201,
            )
            location = call(
                "POST", "/inventory/locations", {"name": "PG 창고", "code": "PG"}, 201
            )
            asset = call(
                "POST",
                "/inventory/assets",
                {
                    "name": "PG 부품",
                    "serial_no": "PG-001",
                    "quantity": 3,
                    "location_id": location["id"],
                },
                201,
            )
            call(
                "POST",
                "/inventory/assets",
                {
                    "name": "duplicate",
                    "serial_no": "pg-001",
                    "location_id": location["id"],
                },
                409,
            )
            call(
                "POST",
                f"/service/tickets/{ticket['id']}/parts",
                {
                    "asset_id": asset["id"],
                    "part_name": "부품",
                    "quantity": 1,
                    "unit_price": 50,
                },
            )
            for path in (
                "/service/stats/summary",
                "/service/stats/grouped?group_by=category",
                "/service/stats/trend?interval=month",
                "/service/stats/crosstab?rows=brand&cols=category",
                "/stores?sort=asset_count",
                "/inventory/overview",
                f"/service/tickets/{ticket['id']}/history",
            ):
                call("GET", path)
            assert call("GET", "/service/tickets?sort=brand_asc")["total"] == 1
            calendar = call(
                "POST",
                "/calendar/calendars",
                {"name": "PG 일정", "type": "PERSONAL"},
                201,
            )
            from datetime import datetime, timedelta, timezone

            start = datetime.now(timezone.utc) + timedelta(days=1)
            call(
                "POST",
                "/calendar/events",
                {
                    "calendar_id": calendar["id"],
                    "title": "반복",
                    "starts_at": start.isoformat(),
                    "ends_at": (start + timedelta(hours=1)).isoformat(),
                    "rrule": "FREQ=DAILY;COUNT=2",
                },
                201,
            )
            call("GET", "/calendar/notifications")
    for args in [("downgrade", "83c49d102fa1"), ("upgrade", "head"), ("check",)]:
        subprocess.run([sys.executable, "-m", "alembic", *args], cwd=root, check=True)
    engine.dispose()
    print(
        "PASS: PostgreSQL install, schema comparison, login, service/inventory/store/statistics/recurrence APIs, upgrade/downgrade"
    )


if __name__ == "__main__":
    main()
