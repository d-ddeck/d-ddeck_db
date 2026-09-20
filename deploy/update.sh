#!/usr/bin/env bash
#
# d-ddeck DB Server - 코드 갱신
#
#   sudo ./deploy/update.sh
#
# 새 코드를 미니PC에 복사한 뒤 실행하면 의존성과 스키마를 맞추고 재시작합니다.
# .env, storage, 데이터베이스는 건드리지 않습니다.

set -euo pipefail

APP_DIR="/opt/ddeck"
SERVICE="ddeck"

GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; BLUE=$'\e[34m'; BOLD=$'\e[1m'; OFF=$'\e[0m'
step() { echo; echo "${BLUE}${BOLD}▶ $*${OFF}"; }
ok()   { echo "  ${GREEN}✓${OFF} $*"; }
die()  { echo; echo "${RED}${BOLD}✗ $*${OFF}" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "root 권한이 필요합니다.  sudo ./deploy/update.sh"
[[ -d "$APP_DIR" ]] || die "${APP_DIR} 가 없습니다. install.sh 를 먼저 실행하세요."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if   [[ -d "${SCRIPT_DIR}/../backend/app" ]]; then SRC="$(cd "${SCRIPT_DIR}/.." && pwd)/backend"
elif [[ -d "${SCRIPT_DIR}/backend/app"    ]]; then SRC="${SCRIPT_DIR}/backend"
else die "backend 폴더를 찾을 수 없습니다."; fi

PORT="$(grep -oP '(?<=--port )\d+' "/etc/systemd/system/${SERVICE}.service" 2>/dev/null || echo 8000)"

# 갱신 전 DB를 먼저 받아둔다. 마이그레이션이 잘못돼도 되돌릴 수 있도록.
step "갱신 전 백업"
if [[ -x "${SCRIPT_DIR}/backup.sh" ]]; then
  "${SCRIPT_DIR}/backup.sh" --quiet && ok "백업 완료"
else
  echo "  ${YELLOW}!${OFF} backup.sh 가 없어 건너뜁니다"
fi

step "서비스 중지"
systemctl stop "$SERVICE"
ok "중지됨"

step "코드 갱신"
rsync -a --delete \
  --exclude '.venv' --exclude '__pycache__' --exclude '*.pyc' \
  --exclude '.env' --exclude 'storage' --exclude '*.db' --exclude '*.db-*' \
  "$SRC"/ "$APP_DIR/backend"/
chown -R ddeck:ddeck "$APP_DIR/backend"
ok "코드 복사 완료"

step "의존성 갱신"
VENV_PY="$APP_DIR/backend/.venv/bin/python"
"$VENV_PY" -m pip install --quiet --upgrade pip wheel
"$VENV_PY" -m pip install --quiet -r "$APP_DIR/backend/requirements.txt"
ok "완료"

step "스키마 마이그레이션"
cd "$APP_DIR/backend"
sudo -u ddeck "$VENV_PY" -m alembic upgrade head
ok "완료"

step "서비스 시작"
systemctl start "$SERVICE"
for i in $(seq 1 30); do
  if curl -fsS -m 2 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
    ok "정상 응답 확인"
    echo
    echo "${GREEN}${BOLD}갱신 완료${OFF}"
    exit 0
  fi
  sleep 1
done

journalctl -u "$SERVICE" -n 30 --no-pager || true
die "갱신 후 서버가 응답하지 않습니다. 위 로그를 확인하고, 필요하면 백업으로 복구하세요."
