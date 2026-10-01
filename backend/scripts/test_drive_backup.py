"""Isolated Drive backup/API regressions. No real Google or production DB access."""
import hashlib
import os
import sys
import tempfile
from datetime import datetime, timezone
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
    folder = Path(TEMP.name)/'backups/.drive-private/uploads'
    folder.mkdir(parents=True, exist_ok=True)
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
    assert not archive.exists(), 'temporary archive retained'
    archive.write_bytes(b'zip-test')
    result = d.status()
    assert result['last_file_id'] == 'file' and result['last_account'] == 'new@example.com'
    assert not result['running'] and not result['requested']
    with patch.object(d.settings, 'SCHEDULER_ENABLED', True):
        d.request_backup()
    with patch.object(d.subprocess, 'run', side_effect=OSError('SECRET MUST NOT LEAK')):
        d.tick()
    assert d.status()['last_error'] and 'SECRET' not in d.status()['last_error']
    assert not d.status()['running']
    with patch.object(d.settings, 'SCHEDULER_ENABLED', True):
        d.request_backup()
    with patch.object(d.subprocess, 'run', return_value=type('Result', (), {'stdout':str(archive)})()), patch.object(d, 'upload', side_effect=AppError('UPLOAD_FAILED','upload failed',502)):
        d.tick()
    assert not archive.exists(), 'failed upload left a local backup'
    archive.write_bytes(b'zip-test')
    d.disconnect()
    assert not d.status()['connected'] and not d.status()['enabled']
    assert d.next_run({'hour': 3}, datetime(2026,9,29,4,tzinfo=d.TZ)).startswith('2026-09-30T03:00')

    # Shared Drive: reject personal folders/read-only membership, preserve the
    # previous connection on failure and upload using supportsAllDrives.
    import json

    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    from app.services import shared_drive
    pem = rsa.generate_private_key(public_exponent=65537, key_size=2048).private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode()
    raw_key = json.dumps({'type': 'service_account', 'client_email': 'backup@test.iam.gserviceaccount.com',
        'private_key': pem, 'private_key_id': 'test-key', 'token_uri': 'https://untrusted.example/token'})
    assert shared_drive.parse_key(raw_key)['token_uri'] == 'https://oauth2.googleapis.com/token'
    target = 'shared_folder_12345'
    assert shared_drive.folder_id('https://drive.google.com/drive/u/0/folders/' + target) == target
    expect_error(lambda: shared_drive.folder_id('https://evil.example/folders/' + target), 'INVALID_DRIVE_FOLDER')
    expect_error(lambda: shared_drive.parse_key('{}'), 'INVALID_SERVICE_ACCOUNT')
    metadata = {'id': target, 'name': 'Backup', 'driveId': 'drive_12345', 'mimeType': 'application/vnd.google-apps.folder', 'capabilities': {'canAddChildren': True}}
    shared_calls = []
    def shared_http(req):
        shared_calls.append(req)
        if req.method == 'GET':
            assert req.url.params['supportsAllDrives'] == 'true'
            return httpx.Response(200, json=metadata)
        if req.method == 'POST':
            assert req.url.params['supportsAllDrives'] == 'true'
            assert json.loads(req.content)['parents'] == [target]
            return httpx.Response(200, headers={'Location': 'https://www.googleapis.com/upload-session'})
        return httpx.Response(200, json={'id': 'shared-file', 'size': str(archive.stat().st_size), 'md5Checksum': hashlib.md5(archive.read_bytes()).hexdigest()})
    with patch.object(shared_drive, 'access_token', return_value='service-access'), patch.object(d.httpx, 'Client', side_effect=lambda **kw: RealClient(transport=httpx.MockTransport(shared_http), **kw)):
        response = client.put(base + '/shared-drive', headers=headers, json={'service_account_json': raw_key, 'folder': target})
        assert response.status_code == 200, response.text
        public = response.json()
        assert public['connected'] and public['connection_type'] == 'shared_drive' and public['folder_name'] == 'Backup'
        assert 'private_key' not in response.text and 'service_account' not in public
        # Existing key can be reused to change the target folder.
        assert d.configure_shared_drive('', target)['account'] == 'backup@test.iam.gserviceaccount.com'
        metadata.pop('driveId')
        expect_error(lambda: d.configure_shared_drive(raw_key, target), 'SHARED_DRIVE_FOLDER_REQUIRED')
        assert d.status()['connected']
        metadata['driveId'] = 'drive_12345'
        metadata['capabilities']['canAddChildren'] = False
        expect_error(lambda: d.configure_shared_drive(raw_key, target), 'SHARED_DRIVE_FOLDER_REQUIRED')
        metadata['capabilities']['canAddChildren'] = True
        with d.state() as st:
            snapshot = dict(st)
        assert d.upload(snapshot, archive) == 'shared-file'
        with patch.object(d.settings, 'SCHEDULER_ENABLED', True):
            assert d.schedule(True, 3)['enabled']
    d.disconnect()
    assert not d.status()['connected']

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

    # Existing records may retain inactive legacy personnel; new forms must not
    # expose them, and edit validation must not mutate the code master.
    from app.models.service import ServiceTicket, ServiceTicketResponder
    from app.services import ticket_rules
    with SessionLocal() as db:
        ticket = ServiceTicket(ticket_no='HISTORY-TEST', title='Historical responders', received_at=datetime.now(timezone.utc))
        db.add(ticket)
        db.flush()
        db.add(ServiceTicketResponder(ticket_id=ticket.id, seq=1, responder_id=old_id))
        ticket_id = ticket.id
        db.get(CodeItem, old_id).is_active = False
        db.commit()
        assert ticket_rules.validate_responder_ids(db, [old_id], include_historical=True) == [old_id]
        expect_error(lambda: ticket_rules.validate_responder_ids(db, [old_id]), 'CODE_NOT_FOUND')
    historic = client.get('/api/v1/admin/codes/SERVICE_RESPONDER?include_historical=true', headers=headers)
    assert historic.status_code == 200, historic.text
    assert any(i['id'] == str(old_id) for i in historic.json()['items'])
    assert not any(i['id'] == str(old_id) for i in responders())
    saved = client.patch(f'/api/v1/service/tickets/{ticket_id}', headers=headers,
                         json={'responder_ids': [str(old_id)]})
    assert saved.status_code == 200, saved.text
    assert saved.json()['responders'][0]['id'] == str(old_id)

    # Explicit alarm clock times may fall after midnight on an all-day event.
    from datetime import timedelta
    start = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=2)
    calendars = client.get('/api/v1/calendar/calendars', headers=headers).json()
    created = client.post('/api/v1/calendar/events', headers=headers, json={
        'calendar_id': calendars[0]['id'], 'title': 'Clock time alarm',
        'starts_at': start.isoformat(), 'ends_at': (start + timedelta(days=1)).isoformat(),
        'all_day': True, 'reminders': [{'offset_minutes': -540, 'method': 'PUSH'}],
    })
    assert created.status_code == 201, created.text
    reminder = created.json()['reminders'][0]
    assert datetime.fromisoformat(reminder['scheduled_at'].replace('Z', '+00:00')) == start + timedelta(hours=9)

    with SessionLocal() as db:
        admin = db.scalar(select(User).where(User.email == 'admin@ddeck.local'))
        admin.role = Role.MANAGER
        db.commit()
    for method, path, payload in [
        ('GET', '', None),
        ('PUT', '/rclone', {'target': 'gdrive:Backup'}),
        ('POST', '/setup', None),
        ('GET', '/files', None),
        ('POST', '/restore/start', {'name': 'drive_20260929_000000_000000.zip'}),
        ('GET', '/setup/test', None),
        ('POST', '/setup/test/answer', {'value': 'x'}),
        ('POST', '/setup/test/finish', {'folder': 'Backup'}),
        ('DELETE', '/setup/test', None),
        ('PUT', '/shared-drive', {'folder': 'shared_folder_12345'}), ('POST', '/connect', None), ('POST', '/run', None),
        ('DELETE', '/connection', None),
        ('PUT', '/schedule', {'enabled': False, 'hour': 3}),
        ('PUT', '/config', {'client_id': 'x', 'client_secret': 'x', 'redirect_uri': 'https://example.com/api/v1/admin/drive-backup/callback'}),
    ]:
        assert client.request(method, base + path, headers=headers, json=payload).status_code == 403

with d.state() as stored:
    stored.clear()
    stored.update(refresh_token='old-token', email='old@example.com')
with patch.object(d.rclone_backup, 'validate', side_effect=AppError('BAD', 'bad', 502)):
    expect_error(lambda: d.configure_rclone('gdrive:Backup'), 'BAD')
with d.state() as stored:
    assert stored['refresh_token'] == 'old-token'
with patch.object(d.rclone_backup, 'validate', return_value='gdrive'):
    result = d.configure_rclone('gdrive:Backup')
assert result['connected'] and result['connection_type'] == 'rclone'
assert result['retention_count'] == 30
with d.state() as stored:
    assert 'refresh_token' not in stored
assert not d.disconnect()['connected']

print('Drive backup and service responder regressions passed')
TEMP.cleanup()
