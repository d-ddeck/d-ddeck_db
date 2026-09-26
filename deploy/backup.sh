#!/usr/bin/env bash
#
# d-ddeck DB Server - 백업
#
#   sudo ./deploy/backup.sh                  지금 한 번 백업
#   sudo ./deploy/backup.sh --install-cron   매일 새벽 3시 자동 백업 등록
#   sudo ./deploy/backup.sh --restore <경로> 백업에서 복구
#
# 데이터는 두 곳에 있습니다. 둘 다 받아야 복구됩니다.
#   1) 데이터베이스  - 계정, AS, 자산, 게시글, 일정
#   2) storage/      - 첨부파일 (DB에는 경로만 저장됨)

set -euo pipefail

APP_DIR="/opt/ddeck"
BACKUP_DIR="${APP_DIR}/backups"
SERVICE="ddeck"
KEEP_DAYS="${KEEP_DAYS:-30}"
KEEP_MIN="${KEEP_MIN:-7}"
umask 077

GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; BLUE=$'\e[34m'; BOLD=$'\e[1m'; OFF=$'\e[0m'
QUIET=0
say()  { [[ $QUIET -eq 1 ]] || echo "$@"; }
step() { [[ $QUIET -eq 1 ]] || { echo; echo "${BLUE}${BOLD}▶ $*${OFF}"; }; }
ok()   { say "  ${GREEN}✓${OFF} $*"; }
die()  { echo; echo "${RED}${BOLD}✗ $*${OFF}" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "root 권한이 필요합니다."
[[ -f "${APP_DIR}/backend/.env" ]] || die "${APP_DIR} 에 설치본이 없습니다."

DATABASE_URL="$(grep '^DATABASE_URL=' "${APP_DIR}/backend/.env" | cut -d= -f2-)"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

VENV_PY="${APP_DIR}/backend/.venv/bin/python"
SQLITE_HELPER="$(dirname "$SCRIPT_PATH")/sqlite_backup.py"
[[ "$KEEP_MIN" =~ ^[1-9][0-9]*$ && "$KEEP_DAYS" =~ ^[0-9]+$ ]] || die "백업 보관 설정이 올바르지 않습니다."

# ------------------------------------------------------------------ cron 등록
if [[ "${1:-}" == "--install-cron" ]]; then
  [[ -f "$APP_DIR/deploy/backup.sh" ]] || die "설치된 deploy/backup.sh 가 없습니다. 설치 프로그램을 갱신하세요."
  cat > /etc/cron.d/ddeck-backup <<CRONEOF
# d-ddeck DB Server 자동 백업 - 매일 03:00
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * * root /bin/bash ${APP_DIR}/deploy/backup.sh --quiet >> /var/log/ddeck-backup.log 2>&1
*/15 * * * * ddeck ${APP_DIR}/backend/.venv/bin/python ${APP_DIR}/deploy/monitor.py --root ${APP_DIR} 2>&1 | /usr/bin/logger -t ddeck-monitor
CRONEOF
  chmod 644 /etc/cron.d/ddeck-backup
  cat > /etc/logrotate.d/ddeck-backup <<LOGEOF
/var/log/ddeck-backup.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
    create 0640 root adm
}
LOGEOF
  echo "${GREEN}${BOLD}✓ 매일 새벽 3시 자동 백업 등록${OFF}"
  echo "  보관 수: 최근 ${KEEP_MIN}개 (${BACKUP_DIR})"
  echo "  로그: /var/log/ddeck-backup.log"
  echo
  echo "  ${YELLOW}권장: 이 폴더를 NAS나 외장 디스크로도 복사하세요.${OFF}"
  echo "  ${YELLOW}미니PC 디스크가 고장나면 백업도 같이 사라집니다.${OFF}"
  exit 0
fi

# ------------------------------------------------------------------ 복구
if [[ "${1:-}" == "--restore" ]]; then
  ARCHIVE="${2:-}"
  [[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || die "복구할 백업 파일 경로를 지정하세요.  --restore <파일>"

  echo "${YELLOW}${BOLD}경고: 현재 데이터를 백업 시점으로 되돌립니다.${OFF}"
  echo "  대상: ${ARCHIVE}"
  read -rp "계속하려면 'yes' 를 입력하세요: " CONFIRM
  [[ "$CONFIRM" == "yes" ]] || die "취소했습니다."

  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  "$VENV_PY" "$(dirname "$SCRIPT_PATH")/backup_bundle.py" --extract "$ARCHIVE" --destination "$TMP"
  # mktemp -d 는 0700 이라 postgres 사용자가 덤프를 읽지 못한다.
  chmod 755 "$TMP"
  [[ -f "$TMP/db.dump" ]] && chmod 644 "$TMP/db.dump"

  [[ -d "$TMP/storage" ]] || die "백업에 storage 폴더가 없습니다."
  if [[ "$DATABASE_URL" == postgresql* ]]; then
    [[ -s "$TMP/db.dump" ]] || die "백업에 DB 덤프가 없습니다."
  else
    "$VENV_PY" "$SQLITE_HELPER" validate "$TMP/ddeck.db" || die "복원본 무결성 검사 실패"
  fi
  systemctl stop "$SERVICE"
  # Preserve the current database and attachments before replacing either.
  if ! bash "$SCRIPT_PATH" --quiet; then
    systemctl start "$SERVICE"
    die "복원 전 백업 실패: 현재 데이터는 변경하지 않았습니다."
  fi

  if [[ "$DATABASE_URL" == postgresql* ]]; then
    "$VENV_PY" "$(dirname "$SCRIPT_PATH")/backup_bundle.py" --root "$APP_DIR" --restore-postgres "$TMP/db.dump" \
      || die "DB 복구 실패: 서비스를 중지 상태로 유지합니다."
  else
    DB_PATH="$("$VENV_PY" "$(dirname "$SCRIPT_PATH")/backup_bundle.py" --root "$APP_DIR" --database-path)"
    "$VENV_PY" "$SQLITE_HELPER" restore "$TMP/ddeck.db" "$DB_PATH"
    chown ddeck:ddeck "$DB_PATH"
  fi

  if [[ -d "$TMP/storage" ]]; then
    STORAGE_PATH="$("$VENV_PY" "$(dirname "$SCRIPT_PATH")/backup_bundle.py" --root "$APP_DIR" --storage-path)"
    mkdir -p "$STORAGE_PATH"
    rsync -a --delete "$TMP/storage/" "$STORAGE_PATH/"
    chown -R ddeck:ddeck "$STORAGE_PATH"
  fi

  systemctl start "$SERVICE"
  RESTORED_PORT="$(grep -oP '(?<=--port )\d+' "/etc/systemd/system/${SERVICE}.service" 2>/dev/null || echo 8000)"
  RESTORE_OK=0
  for i in $(seq 1 30); do
    if curl -fsS -m 2 "http://127.0.0.1:${RESTORED_PORT}/healthz" >/dev/null 2>&1; then RESTORE_OK=1; break; fi
    sleep 1
  done
  if [[ "$RESTORE_OK" != 1 ]]; then systemctl stop "$SERVICE"; die "복원 후 건강 검사 실패: 서비스를 중지했습니다."; fi
  echo "${GREEN}${BOLD}✓ 복구 완료${OFF}"
  exit 0
fi

[[ "${1:-}" == "--quiet" ]] && QUIET=1

# Shared ZIP format, verified atomically, with optional rclone upload.
exec "$VENV_PY" "$(dirname "$SCRIPT_PATH")/backup_bundle.py" --root "$APP_DIR" --keep "$KEEP_MIN"
