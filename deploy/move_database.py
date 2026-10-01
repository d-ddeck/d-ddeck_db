"""Plan/apply a local SQLite move to a mounted external disk or DAS.
Run with the backend virtualenv Python. Default is a read-only plan.
"""
from __future__ import annotations

import argparse
import fcntl
import os
import pwd
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

from backup_bundle import config, database_path
from sqlite_backup import snapshot, validate
from storage_guard import verify, volume


def command(*args):
    return subprocess.run(list(args), check=True, capture_output=True, text=True).stdout.strip()


def quote(value):
    return '"' + str(value).replace('%', '%%').replace('\\', '\\\\').replace('"', '\\"') + '"'


def atomic_write(path, content, uid, gid):
    fd, name = tempfile.mkstemp(prefix='.ddeck-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(content)
            out.flush()
            os.fsync(out.fileno())
        os.chmod(name, 0o600)
        os.chown(name, uid, gid)
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def replace_url(content, url):
    lines = content.decode('utf-8-sig').splitlines()
    result = []
    found = False
    for line in lines:
        if line.partition('=')[0].strip() == 'DATABASE_URL':
            if not found:
                result.append('DATABASE_URL=' + url)
                found = True
        else:
            result.append(line)
    if not found:
        raise ValueError('DATABASE_URL 설정이 없습니다.')
    return ('\n'.join(result) + '\n').encode()


def healthy():
    for _ in range(30):
        try:
            with urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2) as reply:
                if reply.status == 200:
                    return
        except OSError:
            pass
        time.sleep(1)
    raise RuntimeError('이전 후 서버 상태 확인 실패')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mount', type=Path, required=True,
                        help='UUID로 영구 마운트한 외장 디스크의 마운트 지점')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    mount = args.mount.resolve(strict=True)
    if any(c in str(mount) for c in '\n\r\x00?#'):
        raise ValueError('지원하지 않는 마운트 경로입니다.')
    info = volume(mount)
    if mount == Path('/') or Path(info['target']).resolve() != mount or info.get('uuid') == volume(Path('/')).get('uuid'):
        raise ValueError('루트 디스크가 아닌 별도 마운트 지점을 지정하세요.')
    if info.get('fstype') not in {'ext4', 'xfs', 'btrfs'} or not info.get('uuid'):
        raise ValueError('로컬 ext4/XFS/Btrfs 디스크와 UUID가 필요합니다. SMB/NFS는 지원하지 않습니다.')
    source = database_path(root, config(root)['DATABASE_URL'])
    if source is None:
        raise ValueError('이 도구는 현재 서버의 SQLite 전용입니다.')
    source = source.resolve(strict=True)
    target_dir = mount / 'ddeck-database'
    target = target_dir / 'ddeck.db'
    if target_dir.exists() or source.is_relative_to(mount):
        raise ValueError('대상 디렉터리가 이미 있거나 현재 DB가 해당 디스크에 있습니다.')
    validate(source)
    if shutil.disk_usage(mount).free < source.stat().st_size * 3 + 64 * 1024 * 1024:
        raise ValueError('디스크 여유 공간이 부족합니다.')
    working = command('systemctl', 'show', 'ddeck', '--property=WorkingDirectory', '--value')
    if Path(working).resolve() != root / 'backend':
        raise ValueError('현재 ddeck 서비스와 프로젝트 경로가 다릅니다.')
    print(f'DB 이전 계획: {source} → {target}\n대상 UUID: {info["uuid"]}')
    if not args.apply:
        print('검사만 완료했습니다. 변경 사항 없음. 적용하려면 --apply를 지정하세요.')
        return
    if os.geteuid() != 0:
        raise PermissionError('적용은 관리자 권한이 필요합니다.')
    service_user = command('systemctl', 'show', 'ddeck', '--property=User', '--value')
    owner = pwd.getpwnam(service_user or 'root')
    env_file = root / 'backend/.env'
    original = env_file.read_bytes()
    env_stat = env_file.stat()
    dropin = Path('/etc/systemd/system/ddeck.service.d/70-external-database.conf')
    if dropin.exists():
        raise ValueError('외장 DB 설정이 이미 있습니다. 덮어쓰지 않습니다.')
    with (root / 'backend/.database-move.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # A verified cloud safety backup is mandatory; no local backup archive.
        subprocess.run(['runuser', '-u', owner.pw_name, '--', str(root / 'backend/.venv/bin/python'),
                        str(root / 'deploy/cloud_backup.py'), '--root', str(root)], check=True)
        current_volume = volume(mount)
        if current_volume.get('uuid') != info['uuid'] or Path(current_volume['target']).resolve() != mount:
            raise ValueError('백업 도중 대상 디스크가 변경되었습니다.')
        command('systemctl', 'stop', 'ddeck')
        activated = False
        start_attempted = False
        try:
            target_dir.mkdir(mode=0o700)
            os.chown(target_dir, owner.pw_uid, owner.pw_gid)
            snapshot(source, target)
            os.chmod(target, 0o600)
            os.chown(target, owner.pw_uid, owner.pw_gid)
            verify(mount, info['uuid'], target)
            mount_unit = command('systemd-escape', '--path', '--suffix=mount', str(mount))
            dropin.parent.mkdir(parents=True, exist_ok=True)
            guard = ' '.join(map(quote, [root / 'backend/.venv/bin/python', root / 'deploy/storage_guard.py', mount, info['uuid'], target]))
            dropin.write_text(f'[Unit]\nRequiresMountsFor={quote(mount)}\nBindsTo={mount_unit}\nAfter={mount_unit}\n'
                              f'[Service]\nReadWritePaths={quote(target_dir)}\nExecStartPre={guard}\n')
            atomic_write(env_file, replace_url(original, 'sqlite+pysqlite:///' + str(target)), env_stat.st_uid, env_stat.st_gid)
            command('systemctl', 'daemon-reload')
            start_attempted = True
            command('systemctl', 'start', 'ddeck')
            healthy()
            # Health alone could succeed against a different DB if systemd has
            # an overriding environment setting. Prove the running process uses
            # the destination before retiring the original file.
            pid = command('systemctl', 'show', 'ddeck', '--property=MainPID', '--value')
            if not pid.isdigit() or pid == '0':
                raise RuntimeError('실행 중인 서버 PID를 확인하지 못했습니다.')
            opened = []
            for descriptor in Path('/proc', pid, 'fd').iterdir():
                try:
                    opened.append(descriptor.resolve(strict=True))
                except OSError:
                    continue
            if target not in opened or source in opened:
                raise RuntimeError('서버가 새 DB를 사용 중인지 확인하지 못했습니다.')
            activated = True
        finally:
            if not activated:
                command('systemctl', 'stop', 'ddeck')
                if start_attempted:
                    raise RuntimeError('전환 후 확인 실패. 서버를 중지했습니다. 새 DB와 원본을 보존했으므로 확인 후 재시작하세요.')
                atomic_write(env_file, original, env_stat.st_uid, env_stat.st_gid)
                dropin.unlink(missing_ok=True)
                command('systemctl', 'daemon-reload')
                command('systemctl', 'start', 'ddeck')
                # Keep failed destination for investigation; never use it automatically.
                print('원래 DB 경로로 복구했습니다. 대상 파일은 확인 후 제거하세요.')
        # Keep the original untouched until verification; retire it after success.
        for path in [source, Path(str(source) + '-wal'), Path(str(source) + '-shm')]:
            path.unlink(missing_ok=True)
        print('외장 DB 전환 및 서버 상태 확인 완료. 원래 DB 파일은 제거했습니다. 첨부파일 경로는 유지됩니다.')


if __name__ == '__main__':
    try:
        main()
    except Exception:  # noqa: BLE001 - hide credential-bearing transport errors
        # Never expose credential-bearing configuration/exception details.
        print('DB 이전 실패. 디스크·권한·Google 백업·서버 상태를 확인하세요.', file=sys.stderr)
        raise SystemExit(1) from None
