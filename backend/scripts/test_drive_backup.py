"""Isolated Drive backup/API regressions. No real Google or production DB access."""
import hashlib
import os
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
TEMP = tempfile.TemporaryDirectory(prefix='ddeck-drive-test-')
os.environ.update(DATABASE_URL=f'sqlite:///{TEMP.name}/test.db', ENVIRONMENT='test', DEBUG='false',
    SCHEDULER_ENABLED='false', AUTH_RATE_LIMIT_ENABLED='false', STORAGE_DIR=f'{TEMP.name}/storage',
    BACKUP_ROOT=TEMP.name, FIRST_SUPERADMIN_EMAIL='admin@ddeck.local', FIRST_SUPERADMIN_PASSWORD='admin1234')

import httpx
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.core.database import SessionLocal
from app.core.errors import AppError
from app.main import app
from app.models.admin import CodeGroup, CodeItem
from app.models.enums import Role, UserStatus
from app.models.user import User
from app.services import drive_backup as d


def expect_error(fn, code):
    try:
        fn()
    except AppError as exc:
        assert exc.code == code, exc.code
    else:
        raise AssertionError('Expected ' + code)


with TestClient(app) as client:
    with SessionLocal() as db:
        admin = db.scalar(select(User).where(User.role == Role.SUPERADMIN))
        admin.must_change_password = False
        db.commit()
    auth = client.post('/api/v1/auth/login', json={'email': 'admin', 'password': 'admin1234'}).json()
    headers = {'Authorization': 'Bearer ' + auth['access_token']}
    base = '/api/v1/admin/drive-backup'
    assert client.get(base).status_code == 401
    assert client.get(base, headers=headers).json()['connected'] is False
    assert client.put(base+'/config', headers=headers, json={'client_id':'test', 'client_secret':'secret', 'redirect_uri':'http://evil.example/callback'}).status_code == 422
    assert client.put(base+'/config', headers=headers, json={'client_id':'test', 'client_secret':'secret', 'redirect_uri':'http://localhost:8000/api/v1/admin/drive-backup/callback'}).status_code == 200
    assert 'secret' not in client.get(base, headers=headers).text
    assert client.put(base+'/schedule', headers=headers, json={'enabled': True, 'hour': 24}).status_code == 422
    assert client.post(base+'/run', headers=headers).status_code == 503
    expect_error(lambda: d.callback('wrong', 'code'), 'INVALID_OAUTH_STATE')
    url = d.authorization_url()['url']
    q = parse_qs(urlsplit(url).query)
    assert q['scope'] == [d.SCOPE] and q['prompt'] == ['consent select_account'] and q['code_challenge_method'] == ['S256']
    nonce = q['state'][0]
    expect_error(lambda: d.callback(nonce, '', True), 'OAUTH_CANCELLED')
    expect_error(lambda: d.callback(nonce, 'code'), 'INVALID_OAUTH_STATE')
    with d.state() as s:
        s.update(refresh_token='old', email='old@example.com', enabled=True, folder_id='old-folder')
    url = d.authorization_url()['url']
    nonce = parse_qs(urlsplit(url).query)['state'][0]
    expect_error(lambda: d.callback(nonce, '', True), 'OAUTH_CANCELLED')
    assert d.status()['account'] == 'old@example.com'

    RealClient = httpx.Client
    def oauth(req):
        if req.url.path == '/token':
            return httpx.Response(200, json={'refresh_token':'new', 'access_token':'access', 'scope':d.SCOPE})
        return httpx.Response(200, json={'user': {'emailAddress':'new@example.com', 'permissionId':'new-id'}})
    nonce = parse_qs(urlsplit(d.authorization_url()['url']).query)['state'][0]
    with patch.object(d.httpx, 'Client', side_effect=lambda **kw: RealClient(transport=httpx.MockTransport(oauth), **kw)):
        d.callback(nonce, 'code')
    assert d.status()['account'] == 'new@example.com' and d.status()['folder_id'] is None
    expect_error(lambda: d.callback(nonce, 'code'), 'INVALID_OAUTH_STATE')
    with patch.object(d.settings, 'SCHEDULER_ENABLED', True):
        d.schedule(True, 4)
        assert datetime.fromisoformat(d.status()['next_run_at']).hour == 4
        d.request_backup()
    with d.state() as s:
        s['lease_until'] = d.time.time() + 60
    expect_error(d.disconnect, 'BACKUP_RUNNING')
    expect_error(d.authorization_url, 'BACKUP_RUNNING')
    with d.state() as s:
        s['lease_until'] = 0
    folder = Path(TEMP.name)/'backups'
    archive = folder/'drive_test.zip'
    archive.write_bytes(b'zip-test')
    calls = []
    def drive(req):
        calls.append(req)
        if req.url.path == '/token':
            return httpx.Response(200, json={'access_token':'access'})
        if req.url.path == '/drive/v3/files':
            return httpx.Response(200, json={'id':'new-folder'})
        if req.method == 'POST':
            return httpx.Response(200, headers={'Location':'https://www.googleapis.com/upload-session'})
        return httpx.Response(200, json={'id':'file', 'size':str(archive.stat().st_size), 'md5Checksum':hashlib.md5(archive.read_bytes()).hexdigest()})
    with patch.object(d.httpx, 'Client', side_effect=lambda **kw: RealClient(transport=httpx.MockTransport(drive), **kw)), patch.object(d.subprocess, 'run', return_value=type('Result', (), {'stdout':str(archive)})()):
        d.tick()
        first = len(calls)
        d.tick()
        assert len(calls) == first, 'duplicate scheduled upload'
    result = d.status()
    assert result['last_file_id'] == 'file' and result['last_account'] == 'new@example.com'
    assert not result['running'] and not result['requested']
    with patch.object(d.settings, 'SCHEDULER_ENABLED', True):
        d.request_backup()
    with patch.object(d.subprocess, 'run', side_effect=OSError('SECRET MUST NOT LEAK')):
        d.tick()
    assert d.status()['last_error'] and 'SECRET' not in d.status()['last_error']
    assert not d.status()['running']
    d.disconnect()
    assert not d.status()['connected'] and not d.status()['enabled']
    assert d.next_run({'hour': 3}, datetime(2026,9,29,4,tzinfo=d.TZ)).startswith('2026-09-30T03:00')

    # Directory-backed responders: duplicate names remain separate accounts,
    # superadmin, pending, resigned and soft-deleted users never appear.
    with SessionLocal() as db:
        group = db.scalar(select(CodeGroup).where(CodeGroup.code == 'SERVICE_RESPONDER'))
        old = CodeItem(group_id=group.id, code='LEGACY', name='예전 인원', is_active=True)
        db.add(old)
        for n, status, role in [('member',UserStatus.APPROVED,Role.MEMBER), ('manager',UserStatus.APPROVED,Role.MANAGER), ('pending',UserStatus.PENDING,Role.MEMBER), ('resigned',UserStatus.RESIGNED,Role.MEMBER)]:
            db.add(User(email=n+'@example.com', full_name='동명이인' if n in {'member','manager'} else n, password_hash='unused', status=status, role=role))
        db.commit()
        old_id = old.id
    def responders():
        r = client.get('/api/v1/admin/codes/SERVICE_RESPONDER', headers=headers)
        assert r.status_code == 200, r.text
        return r.json()['items']
    items = responders()
    assert len(items) == 2 and len({i['id'] for i in items}) == 2
    assert {i['id'] for i in responders()} == {i['id'] for i in items}
    assert all(i['extra']['user_id'] and i['is_active'] for i in items)
    with SessionLocal() as db:
        assert db.get(CodeItem, old_id).name == '예전 인원'
        member = db.scalar(select(User).where(User.email == 'member@example.com'))
        member.role = Role.SUPERADMIN
        db.commit()
    assert len(responders()) == 1

    with SessionLocal() as db:
        admin = db.scalar(select(User).where(User.email == 'admin@ddeck.local'))
        admin.role = Role.MANAGER
        db.commit()
    for method, path, payload in [
        ('GET', '', None), ('POST', '/connect', None), ('POST', '/run', None),
        ('DELETE', '/connection', None),
        ('PUT', '/schedule', {'enabled': False, 'hour': 3}),
        ('PUT', '/config', {'client_id': 'x', 'client_secret': 'x', 'redirect_uri': 'https://example.com/api/v1/admin/drive-backup/callback'}),
    ]:
        assert client.request(method, base + path, headers=headers, json=payload).status_code == 403

print('Drive backup and service responder regressions passed')
TEMP.cleanup()
