"""Fail closed when a configured external database volume is absent/replaced."""
import argparse
import json
import subprocess
from pathlib import Path


def volume(path):
    result = subprocess.run(
        ['findmnt', '--json', '--target', str(path), '--output', 'TARGET,UUID,FSTYPE'],
        check=True, capture_output=True, text=True,
    )
    return json.loads(result.stdout)['filesystems'][0]


def verify(mount, expected_uuid, database):
    info = volume(mount)
    if Path(info['target']).resolve() != mount.resolve() or info.get('uuid') != expected_uuid:
        raise RuntimeError('외장 DB 디스크가 없거나 다른 디스크입니다. 서버 시작을 중단합니다.')
    if not database.is_file() or database.is_symlink():
        raise RuntimeError('기존 DB 파일이 없습니다. 빈 DB를 만들지 않습니다.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mount', type=Path)
    parser.add_argument('uuid')
    parser.add_argument('database', type=Path)
    args = parser.parse_args()
    verify(args.mount, args.uuid, args.database)
