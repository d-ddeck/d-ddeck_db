"""Power off after a scheduled backup. Isolated: the request file and the root
helper paths all live in a temp folder, so this never powers the machine off."""
import os
import sys
import tempfile
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
TEMP = tempfile.TemporaryDirectory(prefix='ddeck-power-test-')
os.environ.update(DATABASE_URL=f'sqlite:///{TEMP.name}/test.db', ENVIRONMENT='test', DEBUG='false',
    SCHEDULER_ENABLED='false', AUTH_RATE_LIMIT_ENABLED='false', STORAGE_DIR=f'{TEMP.name}/storage',
    BACKUP_ROOT=TEMP.name, FIRST_SUPERADMIN_EMAIL='admin@ddeck.local', FIRST_SUPERADMIN_PASSWORD='admin1234')

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.core.database import SessionLocal
from app.core.errors import AppError
from app.main import app
from app.models.calendar import Notification
from app.models.enums import Role
from app.models.user import User
from app.services import drive_backup as d

TZ = d.TZ
request = d.power_request()
assert str(request).startswith(TEMP.name), 'test must never touch the real request file'
unit = Path(TEMP.name) / 'ddeck-power.path'
helper = Path(TEMP.name) / 'ddeck-power-off'


def expect_error(fn, code):
    try:
        fn()
    except AppError as exc:
        assert exc.code == code, exc.code
    else:
        raise AssertionError('Expected ' + code)


def run_backup(now, *, requested=False):
    """One scheduled (or manual) backup that succeeds without Drive or subprocess."""
    archive = Path(TEMP.name) / 'backups/.drive-private/uploads/test.zip'
    archive.parent.mkdir(parents=True, exist_ok=True)
    archive.write_bytes(b'zip')
    with d.state() as s:
        s.update(rclone_target='remote:ddeck', email='backup@example.com', enabled=True, requested=requested, lease_until=0,
                 next_run_at=(now - timedelta(minutes=1)).isoformat() if not requested else (now + timedelta(hours=5)).isoformat())
    clock = type('Clock', (), {'now': staticmethod(lambda tz=None: now)})
    with patch.object(d, 'datetime', wraps=datetime) as fake, \
            patch.object(d.subprocess, 'run', return_value=type('Result', (), {'stdout': str(archive)})()), \
            patch.object(d, 'upload', return_value='file'):
        fake.now = clock.now
        fake.fromisoformat = datetime.fromisoformat
        d.tick()


with patch.object(d, 'POWER_PATH_UNIT', unit), patch.object(d, 'POWER_HELPER', helper), TestClient(app) as client:
    with SessionLocal() as db:
        admin = db.scalar(select(User).where(User.role == Role.SUPERADMIN))
        admin.must_change_password = False
        admin_id = admin.id
        db.commit()
    auth = client.post('/api/v1/auth/login', json={'email': 'admin', 'password': 'admin1234'}).json()
    headers = {'Authorization': 'Bearer ' + auth['access_token']}
    base = '/api/v1/admin/drive-backup'

    # Off by default; turning on requires the root helper watching this server's file.
    power = client.get(base, headers=headers).json()['power']
    assert power['enabled'] is False and power['ready'] is False
    assert power['grace_minutes'] == 5 and (power['wake_hour'], power['wake_minute']) == (7, 0)
    res = client.put(base + '/power', headers=headers, json={'enabled': True, 'grace_minutes': 5, 'wake_hour': 7, 'wake_minute': 0})
    assert res.status_code == 409 and res.json()['error']['code'] == 'POWER_HELPER_MISSING'
    assert client.put(base + '/power', headers=headers, json={'enabled': True, 'grace_minutes': 0, 'wake_hour': 7, 'wake_minute': 0}).status_code == 422
    assert client.put(base + '/power', headers=headers, json={'enabled': True, 'grace_minutes': 5, 'wake_hour': 24, 'wake_minute': 0}).status_code == 422
    helper.write_text('#!/bin/bash\n')
    unit.write_text('[Path]\nPathExists=/somewhere/else/request\n')
    assert d.power_ready() is False, 'unit watching another installation'
    unit.write_text('[Path]\nPathExists=' + str(request).replace('%', '%%') + '\n')
    assert d.power_ready() is True
    res = client.put(base + '/power', headers=headers, json={'enabled': True, 'grace_minutes': 3, 'wake_hour': 6, 'wake_minute': 30})
    assert res.status_code == 200, res.text
    assert res.json()['power']['enabled'] and res.json()['power']['ready']

    # Wake time: next occurrence at least POWER_MIN_OFF after shutdown.
    s = {'power_wake_hour': 6, 'power_wake_minute': 30}
    assert d.next_wake(s, datetime(2026, 10, 3, 3, 5, tzinfo=TZ)) == datetime(2026, 10, 3, 6, 30, tzinfo=TZ)
    assert d.next_wake(s, datetime(2026, 10, 3, 6, 25, tzinfo=TZ)) == datetime(2026, 10, 4, 6, 30, tzinfo=TZ)
    assert d.next_wake(s, datetime(2026, 10, 3, 7, 0, tzinfo=TZ)) == datetime(2026, 10, 4, 6, 30, tzinfo=TZ)

    # A manual backup never powers off.
    now = datetime(2026, 10, 3, 3, 0, 30, tzinfo=TZ)
    run_backup(now, requested=True)
    assert d.status()['power']['pending'] is None and '수동' in d.status()['power']['note']

    # An on-time scheduled backup starts the grace countdown and tells the admins.
    run_backup(now)
    pending = d.status()['power']['pending']
    assert pending, d.status()
    assert datetime.fromisoformat(pending['shutdown_at']) == now + timedelta(minutes=3)
    assert datetime.fromisoformat(pending['wake_at']) == datetime(2026, 10, 3, 6, 30, tzinfo=TZ)
    with SessionLocal() as db:
        note = db.scalar(select(Notification).where(Notification.user_id == admin_id))
        assert note and '전원' in note.title, 'admins were not notified'

    # Nothing is requested before the grace period ends.
    d._power_tick(now + timedelta(minutes=2))
    assert not request.exists() and d.status()['power']['pending']

    # Cancel drops this run only.
    assert client.post(base + '/power/cancel', headers=headers).json()['power']['pending'] is None
    d._power_tick(now + timedelta(minutes=4))
    assert not request.exists()
    assert d.status()['power']['enabled']

    # After grace the request holds the wake time as UNIX seconds.
    run_backup(now)
    d._power_tick(now + timedelta(minutes=3, seconds=10))
    assert request.read_text() == str(int(datetime(2026, 10, 3, 6, 30, tzinfo=TZ).timestamp()))
    assert oct(request.parent.stat().st_mode & 0o777) == '0o700'
    power = d.status()['power']
    assert power['pending'] is None and power['last_wake_at'].startswith('2026-10-03T06:30')
    request.unlink()

    # A late (catch-up) scheduled backup, e.g. right after boot, must not loop power off.
    late = datetime(2026, 10, 3, 6, 31, tzinfo=TZ)
    with d.state() as st:
        st.update(next_run_at=(late - timedelta(hours=3, minutes=31)).isoformat(), lease_until=0, requested=False)
    archive = Path(TEMP.name) / 'backups/.drive-private/uploads/test.zip'
    archive.write_bytes(b'zip')
    with patch.object(d, 'datetime', wraps=datetime) as fake, \
            patch.object(d.subprocess, 'run', return_value=type('Result', (), {'stdout': str(archive)})()), \
            patch.object(d, 'upload', return_value='file'):
        fake.now = lambda tz=None: late
        fake.fromisoformat = datetime.fromisoformat
        d.tick()
    assert d.status()['power']['pending'] is None, 'catch-up backup scheduled a power off'

    # A countdown that outlived a restart or power cut is dropped, not executed on boot.
    run_backup(now)
    d._power_tick(now + timedelta(hours=4))
    assert not request.exists() and '건너뛰' in d.status()['power']['note']

    # Turning the feature off clears a pending countdown.
    run_backup(now)
    assert d.status()['power']['pending']
    assert client.put(base + '/power', headers=headers, json={'enabled': False, 'grace_minutes': 3, 'wake_hour': 6, 'wake_minute': 30}).json()['power']['pending'] is None
    d._power_tick(now + timedelta(minutes=5))
    assert not request.exists()

    # Missing helper at shutdown time: skip with a note.
    client.put(base + '/power', headers=headers, json={'enabled': True, 'grace_minutes': 3, 'wake_hour': 6, 'wake_minute': 30})
    run_backup(now)
    helper.unlink()
    d._power_tick(now + timedelta(minutes=3, seconds=10))
    assert not request.exists() and '도우미' in d.status()['power']['note']

print('drive power-off tests passed')
