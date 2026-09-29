"""Local administrator login isolation and revocation regression tests."""
import json
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
TEMP = tempfile.TemporaryDirectory(prefix='ddeck-local-admin-test-')
os.environ.update(DATABASE_URL=f'sqlite:///{TEMP.name}/test.db', ENVIRONMENT='test', DEBUG='false',
    SCHEDULER_ENABLED='false', AUTH_RATE_LIMIT_ENABLED='false', STORAGE_DIR=f'{TEMP.name}/storage',
    BACKUP_ROOT=TEMP.name, FIRST_SUPERADMIN_EMAIL='admin@ddeck.local', FIRST_SUPERADMIN_PASSWORD='admin1234')
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.core.database import SessionLocal
from app.main import app
from app.models.enums import Role, UserStatus
from app.models.user import User
from app.services.local_admin import enable, registry_path

url='/api/v1/auth/local-admin'
with TestClient(app, client=('127.0.0.1',50000)) as client:
    with SessionLocal() as db:
        user=db.scalar(select(User).where(User.email=='admin@ddeck.local'))
        user.must_change_password=False
        db.commit()
        uid=user.id
        enable(user, Path(TEMP.name)/'profile', 'http://127.0.0.1:8000')
        try:
            enable(user, Path(TEMP.name)/'profile', 'http://192.168.0.20:8000')
        except ValueError:
            pass
        else:
            raise AssertionError('remote URL accepted')
    credential=Path(TEMP.name)/'profile/.ddeck/local-admin-login.json'
    secret=json.loads(credential.read_text())['secret']
    assert secret not in registry_path().read_text()
    if os.name != 'nt':
        assert credential.stat().st_mode & 0o777 == 0o600
    payload={'secret':secret}
    response=client.post(url,json=payload)
    assert response.status_code==200,response.text
    assert response.json()['user']['email']=='admin@ddeck.local'
    token=response.json()['access_token']
    assert client.get('/api/v1/auth/me',headers={'Authorization':'Bearer '+token}).status_code==200
    for headers in [{'Origin':'http://localhost'}, {'X-Forwarded-For':'127.0.0.1'}, {'Forwarded':'for=127.0.0.1'}, {'X-Real-IP':'127.0.0.1'}]:
        assert client.post(url,json=payload,headers=headers).status_code==401
    assert client.post(url,json={'secret':'x'*64}).status_code==401
    with TestClient(app, client=('192.168.0.50',50001)) as remote:
        assert remote.post(url,json=payload).status_code==401
    for role,status,deleted in [(Role.MEMBER,UserStatus.APPROVED,False),(Role.SUPERADMIN,UserStatus.SUSPENDED,False),(Role.SUPERADMIN,UserStatus.APPROVED,True)]:
        from app.core.security import now_utc
        with SessionLocal() as db:
            user=db.get(User,uid);user.role=role;user.status=status;user.deleted_at=now_utc() if deleted else None;db.commit()
        assert client.post(url,json=payload).status_code==401
    with SessionLocal() as db:
        user=db.get(User,uid);user.role=Role.SUPERADMIN;user.status=UserStatus.APPROVED;user.deleted_at=None
        user.password_hash='changed-password-hash';db.commit()
    assert client.post(url,json=payload).status_code==401
    registry_path().unlink()
    assert client.post(url,json=payload).status_code==401
print('Local admin login: loopback, secret, browser/proxy rejection, account and password revocation passed')
TEMP.cleanup()
