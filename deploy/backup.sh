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

# ------------------------------------------------------------------ cron 등록
if [[ "${1:-}" == "--install-cron" ]]; then
  cat > /etc/cron.d/ddeck-backup <<CRONEOF
# d-ddeck DB Server 자동 백업 - 매일 03:00
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * * root ${SCRIPT_PATH} --quiet >> /var/log/ddeck-backup.log 2>&1
CRONEOF
  chmod 644 /etc/cron.d/ddeck-backup
  echo "${GREEN}${BOLD}✓ 매일 새벽 3시 자동 백업 등록${OFF}"
  echo "  보관 기간: ${KEEP_DAYS}일 (${BACKUP_DIR})"
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
  tar xzf "$ARCHIVE" -C "$TMP"
  # mktemp -d 는 0700 이라 postgres 사용자가 덤프를 읽지 못한다.
  chmod 755 "$TMP"
  [[ -f "$TMP/db.dump" ]] && chmod 644 "$TMP/db.dump"

  systemctl stop "$SERVICE"

  if [[ "$DATABASE_URL" == postgresql* ]]; then
    DB_NAME="$(sed -E 's|.*/([^/?]+).*|\1|' <<<"$DATABASE_URL")"
    DB_USER="$(sed -E 's|.*://([^:]+):.*|\1|' <<<"$DATABASE_URL")"
    sudo -u postgres pg_restore -d "$DB_NAME" --clean --if-exists "$TMP"/db.dump \
      || die "DB 복구 실패"
    sudo -u postgres psql -q -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};"
  else
    cp "$TMP"/ddeck.db "${APP_DIR}/backend/ddeck.db"
    chown ddeck:ddeck "${APP_DIR}/backend/ddeck.db"
  fi

  if [[ -d "$TMP/storage" ]]; then
    rm -rf "${APP_DIR}/storage"
    cp -a "$TMP/storage" "${APP_DIR}/storage"
    chown -R ddeck:ddeck "${APP_DIR}/storage"
  fi

  systemctl start "$SERVICE"
  echo "${GREEN}${BOLD}✓ 복구 완료${OFF}"
  exit 0
fi

[[ "${1:-}" == "--quiet" ]] && QUIET=1

# ------------------------------------------------------------------ 백업
STAMP="$(date +%Y%m%d_%H%M%S)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$BACKUP_DIR"

step "데이터베이스"
if [[ "$DATABASE_URL" == postgresql* ]]; then
  DB_NAME="$(sed -E 's|.*/([^/?]+).*|\1|' <<<"$DATABASE_URL")"
  sudo -u postgres pg_dump -Fc "$DB_NAME" > "$TMP/db.dump" || die "pg_dump 실패"
  ok "PostgreSQL 덤프 ($(du -h "$TMP/db.dump" | cut -f1))"
else
  # SQLite는 .backup 을 써야 쓰기 중에도 일관된 스냅샷이 나온다.
  sqlite3 "${APP_DIR}/backend/ddeck.db" ".backup '$TMP/ddeck.db'" 2>/dev/null \
    || cp "${APP_DIR}/backend/ddeck.db" "$TMP/ddeck.db"
  ok "SQLite 스냅샷 ($(du -h "$TMP/ddeck.db" | cut -f1))"
fi

step "첨부파일"
if [[ -d "${APP_DIR}/storage" ]]; then
  cp -a "${APP_DIR}/storage" "$TMP/storage"
  ok "storage ($(du -sh "$TMP/storage" | cut -f1))"
else
  mkdir -p "$TMP/storage"
  ok "첨부파일 없음"
fi

step "압축"
ARCHIVE="${BACKUP_DIR}/ddeck_${STAMP}.tar.gz"
tar czf "$ARCHIVE" -C "$TMP" .
chmod 600 "$ARCHIVE"
ok "$(basename "$ARCHIVE") ($(du -h "$ARCHIVE" | cut -f1))"

step "오래된 백업 정리"
DELETED="$(find "$BACKUP_DIR" -name 'ddeck_*.tar.gz' -mtime "+${KEEP_DAYS}" -print -delete | wc -l)"
ok "${KEEP_DAYS}일 초과 ${DELETED}건 삭제 / 보관 중 $(find "$BACKUP_DIR" -name 'ddeck_*.tar.gz' | wc -l)건"

say
say "${GREEN}${BOLD}백업 완료: ${ARCHIVE}${OFF}"
say "복구:  sudo ${SCRIPT_PATH} --restore ${ARCHIVE}"
