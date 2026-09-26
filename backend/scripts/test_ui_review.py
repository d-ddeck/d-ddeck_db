"""UI API regressions; temporary database only."""

import os
import sys
import tempfile
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
with tempfile.TemporaryDirectory(prefix="ddeck-ui-") as tmp:
    os.environ.update(
        DATABASE_URL=f"sqlite:///{tmp}/test.db",
        STORAGE_DIR=f"{tmp}/files",
        DEBUG="false",
        ENVIRONMENT="test",
        SCHEDULER_ENABLED="false",
        AUTH_RATE_LIMIT_ENABLED="false",
        FIRST_SUPERADMIN_PASSWORD="TestOnly1234",
    )
    from fastapi.testclient import TestClient
    from sqlalchemy.orm import Session

    from app.core.database import engine
    from app.core.security import hash_password, now_utc
    from app.main import app
    from app.models.admin import Attachment
    from app.models.enums import Role, UserStatus
    from app.models.user import RefreshToken, User

    with TestClient(app) as client:
        ids = {}
        with Session(engine) as db:
            for name, role in [
                ("admin", Role.ADMIN),
                ("peer", Role.ADMIN),
                ("member", Role.MEMBER),
                ("super", Role.SUPERADMIN),
            ]:
                user = User(
                    email=f"{name}@ui.test",
                    full_name=name,
                    role=role,
                    status=UserStatus.APPROVED,
                    password_hash=hash_password("TestOnly1234"),
                )
                db.add(user)
                db.flush()
                ids[name] = str(user.id)
            db.commit()
        headers = {}
        for name in ids:
            r = client.post(
                "/api/v1/auth/login",
                json={"email": f"{name}@ui.test", "password": "TestOnly1234"},
            )
            assert r.status_code == 200, r.text
            headers[name] = {"Authorization": f"Bearer {r.json()['access_token']}"}
        cases = [
            ("admin", "member", 200),
            ("admin", "admin", 200),
            ("admin", "peer", 403),
            ("admin", "super", 403),
            ("member", "admin", 403),
            ("super", "admin", 200),
        ]
        for viewer, target, status in cases:
            r = client.get(
                f"/api/v1/users/{ids[target]}/sessions", headers=headers[viewer]
            )
            assert r.status_code == status, (viewer, target, r.text)
            if status == 200:
                assert len(r.json()) == 1
                assert not any("token" in key for key in r.json()[0])
        with Session(engine) as db:
            row = (
                db.query(RefreshToken).filter_by(user_id=uuid.UUID(ids["member"])).one()
            )
            row.revoked_at = now_utc()
            db.commit()
        assert (
            client.get(
                f"/api/v1/users/{ids['member']}/sessions", headers=headers["admin"]
            ).json()
            == []
        )
        r = client.post(
            "/api/v1/board/boards",
            headers=headers["admin"],
            json={"code": "UI_TEST", "name": "UI test", "allow_secret": True},
        )
        assert r.status_code == 201, r.text
        board = r.json()["id"]
        r = client.post(
            f"/api/v1/board/boards/{board}/posts",
            headers=headers["admin"],
            json={"title": "Attachment count", "content": "test"},
        )
        assert r.status_code == 201, r.text
        post = r.json()["id"]
        with Session(engine) as db:
            for deleted in [False, False, True]:
                db.add(
                    Attachment(
                        entity_type="post",
                        entity_id=uuid.UUID(post),
                        original_name="test.txt",
                        stored_path="test.txt",
                        content_type="text/plain",
                        size_bytes=4,
                        uploaded_by_id=uuid.UUID(ids["admin"]),
                        deleted_at=now_utc() if deleted else None,
                    )
                )
            db.commit()
        r = client.get(f"/api/v1/board/boards/{board}/posts", headers=headers["admin"])
        assert r.status_code == 200, r.text
        row = r.json()["items"][0]
        assert row["attachment_count"] == 2, row
        assert row["author"]["full_name"] == "admin", row
        print(
            "PASS: session permissions (6 cases), revocation, token exclusion, attachment count and author"
        )
    engine.dispose()
