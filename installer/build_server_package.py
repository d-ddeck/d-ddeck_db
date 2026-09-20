"""우분투 서버용 단일 설치 파일(.run)을 만든다.

프로젝트 폴더를 통째로 옮기는 대신 파일 하나만 미니PC로 보내고
`sudo ./ddeck-server-1.0.0.run` 한 줄로 설치가 끝나게 한다.

만들어지는 것은 자기 압축 해제 셸 스크립트다. 앞부분은 평범한 sh 스크립트이고
뒷부분에 tar.gz 바이트가 그대로 붙어 있다. 실행하면 스스로를 잘라 임시 폴더에
풀고 deploy/install.sh 를 호출한다. 우분투에 별도 도구를 설치할 필요가 없다.

    python installer/build_server_package.py
    python installer/build_server_package.py --version 0.2.0
"""
from __future__ import annotations

import argparse
import hashlib
import io
import re
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"

# 서버에 필요한 것만 담는다. 클라이언트(app/)와 설치 산출물은 뺀다.
INCLUDE = ["backend", "deploy"]

EXCLUDE_DIRS = {".venv", "__pycache__", ".git", ".ruff_cache", "storage", "backups"}
EXCLUDE_SUFFIXES = {".pyc", ".pyo", ".db", ".db-wal", ".db-shm", ".log"}
# .env 는 서버마다 다르고 비밀키가 들어 있다. 절대 패키지에 넣지 않는다.
EXCLUDE_NAMES = {".env", ".DS_Store"}

STUB = """#!/bin/sh
# ============================================================
#  d-ddeck DB Server - 자기 압축 해제 설치 파일
#  버전 {version}
#
#    sudo ./{filename}
#
#  옵션은 그대로 전달된다:
#    sudo ./{filename} --port 8080 --database postgres
# ============================================================
set -eu

ARCHIVE_LINE={archive_line}

if [ "$(id -u)" -ne 0 ]; then
  echo ""
  echo "  root 권한이 필요합니다:  sudo ./{filename}"
  echo ""
  exit 1
fi

TMPDIR=$(mktemp -d /tmp/ddeck-install.XXXXXX)
# 설치 도중 무엇이 실패하든 임시 폴더는 지운다.
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

echo ""
echo "  파일을 푸는 중..."
tail -n +$ARCHIVE_LINE "$0" | tar xz -C "$TMPDIR" || {{
  echo "  압축 해제에 실패했습니다. 파일이 손상되었을 수 있습니다." >&2
  exit 1
}}

if [ ! -x "$TMPDIR/deploy/install.sh" ]; then
  chmod +x "$TMPDIR/deploy/install.sh" 2>/dev/null || true
fi
if [ ! -f "$TMPDIR/deploy/install.sh" ]; then
  echo "  설치 스크립트를 찾을 수 없습니다." >&2
  exit 1
fi

cd "$TMPDIR"
./deploy/install.sh "$@"
STATUS=$?

# install.sh 는 /opt/ddeck 으로 코드를 복사하므로 임시 폴더는 없어도 된다.
exit $STATUS

__ARCHIVE_BELOW__
"""


def should_skip(path: Path) -> bool:
    if path.name in EXCLUDE_NAMES:
        return True
    if path.suffix in EXCLUDE_SUFFIXES:
        return True
    return any(part in EXCLUDE_DIRS for part in path.parts)


def read_version() -> str:
    """app/pubspec.yaml 의 버전을 따라가 클라이언트와 번호를 맞춘다."""
    pubspec = ROOT / "app" / "pubspec.yaml"
    if pubspec.exists():
        m = re.search(r"^version:\s*([0-9.]+)", pubspec.read_text(encoding="utf-8"), re.M)
        if m:
            return m.group(1)
    return "0.1.0"


def build_archive() -> bytes:
    buf = io.BytesIO()
    count = 0
    # mtime 을 고정하면 내용이 같을 때 결과 파일도 같아져, 배포본이 바뀌었는지
    # 해시로 판단할 수 있다.
    with tarfile.open(fileobj=buf, mode="w:gz", compresslevel=9) as tar:
        for top in INCLUDE:
            base = ROOT / top
            if not base.exists():
                sys.exit(f"[X] {top} 폴더가 없습니다: {base}")
            for path in sorted(base.rglob("*")):
                if not path.is_file():
                    continue
                rel = path.relative_to(ROOT)
                if should_skip(rel):
                    continue
                info = tar.gettarinfo(path, arcname=str(rel).replace("\\", "/"))
                info.mtime = 0
                info.uid = info.gid = 0
                info.uname = info.gname = "root"
                # 셸 스크립트는 실행 권한이 있어야 한다. Windows 에는 실행
                # 비트가 없으므로 여기서 직접 붙인다.
                info.mode = 0o755 if rel.suffix == ".sh" else 0o644
                with path.open("rb") as fh:
                    tar.addfile(info, fh)
                count += 1
    print(f"    파일 {count}개 포함")
    return buf.getvalue()


def main() -> None:
    ap = argparse.ArgumentParser(description="우분투 서버 설치 파일 생성")
    ap.add_argument("--version", default=None, help="기본: app/pubspec.yaml 의 버전")
    args = ap.parse_args()

    version = args.version or read_version()
    filename = f"ddeck-server-{version}.run"
    out = DIST / filename

    print()
    print("==> 서버 설치 파일 생성")
    print(f"    버전: {version}")

    archive = build_archive()

    # 스텁의 줄 수를 세어 tar 가 시작하는 줄 번호를 확정한다. 이 숫자가 어긋나면
    # 우분투에서 압축 해제가 깨진다.
    placeholder = STUB.format(version=version, filename=filename, archive_line=0)
    archive_line = placeholder.count("\n") + 1
    stub = STUB.format(version=version, filename=filename, archive_line=archive_line)
    assert stub.count("\n") + 1 == archive_line, "스텁 줄 수가 달라졌습니다"

    DIST.mkdir(parents=True, exist_ok=True)
    # 셸 스크립트는 LF 여야 한다. CRLF 면 우분투에서 bad interpreter 로 죽는다.
    with out.open("wb") as fh:
        fh.write(stub.encode("utf-8"))
        fh.write(archive)

    size_mb = out.stat().st_size / 1024 / 1024
    digest = hashlib.sha256(out.read_bytes()).hexdigest()

    print()
    print("=" * 60)
    print("  설치 파일 생성 완료")
    print("=" * 60)
    print()
    print(f"  {out}")
    print(f"  크기 {size_mb:.1f} MB")
    print(f"  SHA256 {digest[:32]}...")
    print()
    print("  미니PC 로 보내기:")
    print(f"    scp dist/{filename} 사용자명@미니PC주소:~/")
    print()
    print("  미니PC 에서 설치:")
    print(f"    chmod +x {filename}")
    print(f"    sudo ./{filename}")
    print()


if __name__ == "__main__":
    main()
