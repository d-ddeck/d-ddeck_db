#!/usr/bin/env bash
#
# d-ddeck DB Server - 코드 갱신
#
#   sudo ./deploy/update.sh
#
# 새 코드를 미니PC에 복사한 뒤 실행하면 의존성과 스키마를 맞추고 재시작합니다.
# .env·첨부를 보존하며 백업 후 데이터베이스 스키마를 갱신합니다.

set -euo pipefail

APP_DIR="/opt/ddeck"
SERVICE="ddeck"
AUTO_ROLLBACK=false
[[ "${1:-}" == "--rollback-on-failure" ]] && AUTO_ROLLBACK=true
SNAPSHOT=""

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

# A backup failure before code replacement may safely restart the old service.
# After replacement, leave it stopped and explain recovery instead of starting
# new code against an uncertain schema.
PHASE=before_stop
on_exit() {
  local result=$?
  if [[ $result -ne 0 ]]; then
    if [[ "$PHASE" == stopped ]]; then systemctl start "$SERVICE" || true; fi
    if [[ "$PHASE" == replacing ]]; then
      systemctl stop "$SERVICE" || true
      if [[ "$AUTO_ROLLBACK" == true && -n "$SNAPSHOT" ]]; then
        if "$SNAPSHOT/backend/.venv/bin/python" "$SCRIPT_DIR/update_snapshot.py" recover --root "$APP_DIR" --snapshot "$SNAPSHOT"; then
          echo "SQLite 백업과 이전 코드·의존성으로 복구했습니다." >&2
          return
        fi
      fi
      echo "갱신 실패. 서비스를 중지 상태로 유지합니다. Google 드라이브의 백업과 journalctl -u ${SERVICE} 를 확인하세요." >&2
    fi
  fi
}
trap on_exit EXIT
[[ -f "$SCRIPT_DIR/backup.sh" ]] || die "backup.sh 가 없어 갱신을 중단합니다."
rm -f /etc/cron.d/ddeck-backup
step "서비스 중지"
systemctl stop "$SERVICE"
PHASE=stopped
step "갱신 전 백업"
if ! bash "$SCRIPT_DIR/backup.sh" --quiet; then die "백업 실패로 갱신을 중단합니다."; fi
ok "백업 완료"
SNAPSHOT="$("$APP_DIR/backend/.venv/bin/python" "$SCRIPT_DIR/update_snapshot.py" prepare --root "$APP_DIR" --unit "/etc/systemd/system/${SERVICE}.service")"
ok "이전 코드·의존성 보관: $SNAPSHOT"

step "코드 갱신"
PHASE=replacing
rsync -a --delete \
  --exclude '.venv' --exclude '.venv-linux' --exclude '__pycache__' --exclude '*.pyc' \
  --exclude '.env' --exclude 'storage' --exclude '*.db' --exclude '*.db-*' \
  "$SRC"/ "$APP_DIR/backend"/
chown -R ddeck:ddeck "$APP_DIR/backend"
mkdir -p "$APP_DIR/deploy"
if [[ "$SCRIPT_DIR" != "$APP_DIR/deploy" ]]; then rsync -a "$SCRIPT_DIR/" "$APP_DIR/deploy/"; fi
chown -R root:root "$APP_DIR/deploy"
chmod -R u=rwX,go=rX "$APP_DIR/deploy"
chmod 755 "$APP_DIR/deploy/"*.sh
ok "코드 복사 완료"

step "의존성 갱신"
VENV_PY="$APP_DIR/backend/.venv/bin/python"
"$VENV_PY" -m pip install --quiet --upgrade pip wheel
"$VENV_PY" -m pip install --quiet -r "$APP_DIR/backend/requirements.txt"
ok "완료"

step "스키마 마이그레이션"
cd "$APP_DIR/backend"
if sudo -u ddeck "$VENV_PY" scripts/adopt_schema.py >/dev/null 2>&1; then
  sudo -u ddeck "$VENV_PY" scripts/adopt_schema.py --stamp
fi
sudo -u ddeck "$VENV_PY" -m alembic upgrade head
sudo -u ddeck "$VENV_PY" -m alembic check
ok "완료"

# Apply the same process limits and writable paths to existing installs.
UNIT_FILE="/etc/systemd/system/${SERVICE}.service"
"$VENV_PY" "$SCRIPT_DIR/harden_service.py" --root "$APP_DIR" --unit "$UNIT_FILE"
systemctl daemon-reload

step "서비스 시작"
systemctl start "$SERVICE"
for i in $(seq 1 30); do
  if curl -fsS -m 2 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
    PHASE=complete
    ok "정상 응답 확인"
    echo
    echo "${GREEN}${BOLD}갱신 완료${OFF}"
    exit 0
  fi
  sleep 1
done

journalctl -u "$SERVICE" -n 30 --no-pager || true
die "갱신 후 서버가 응답하지 않습니다. 위 로그를 확인하고, 필요하면 백업으로 복구하세요."
