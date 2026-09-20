#!/usr/bin/env bash
#
# d-ddeck DB Server - 제거
#
#   sudo ./deploy/uninstall.sh            서비스와 코드만 제거 (데이터 보존)
#   sudo ./deploy/uninstall.sh --purge    데이터베이스와 첨부파일까지 전부 삭제
#
# 기본은 데이터를 남깁니다. --purge 는 되돌릴 수 없습니다.

set -euo pipefail

APP_DIR="/opt/ddeck"
APP_USER="ddeck"
SERVICE="ddeck"

GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; BOLD=$'\e[1m'; OFF=$'\e[0m'
ok()  { echo "  ${GREEN}✓${OFF} $*"; }
die() { echo; echo "${RED}${BOLD}✗ $*${OFF}" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "root 권한이 필요합니다."

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

if [[ $PURGE -eq 1 ]]; then
  echo "${RED}${BOLD}경고: 데이터베이스와 첨부파일을 영구 삭제합니다.${OFF}"
  echo "  계정, AS 이력, 자산, 게시글, 일정이 모두 사라집니다."
  echo "  ${YELLOW}먼저 백업하세요:  sudo ./deploy/backup.sh${OFF}"
  echo
  read -rp "정말 삭제하려면 'DELETE' 를 입력하세요: " CONFIRM
  [[ "$CONFIRM" == "DELETE" ]] || die "취소했습니다."
fi

echo
if systemctl list-unit-files | grep -q "^${SERVICE}.service"; then
  systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SERVICE}.service"
  systemctl daemon-reload
  ok "서비스 제거"
fi

rm -f /etc/cron.d/ddeck-backup && ok "자동 백업 cron 제거" || true

if [[ $PURGE -eq 1 ]]; then
  if [[ -f "${APP_DIR}/backend/.env" ]]; then
    DATABASE_URL="$(grep '^DATABASE_URL=' "${APP_DIR}/backend/.env" | cut -d= -f2-)"
    if [[ "$DATABASE_URL" == postgresql* ]]; then
      DB_NAME="$(sed -E 's|.*/([^/?]+).*|\1|' <<<"$DATABASE_URL")"
      DB_USER="$(sed -E 's|.*://([^:]+):.*|\1|' <<<"$DATABASE_URL")"
      sudo -u postgres psql -q -c "DROP DATABASE IF EXISTS ${DB_NAME};" && ok "데이터베이스 삭제"
      sudo -u postgres psql -q -c "DROP USER IF EXISTS ${DB_USER};" && ok "DB 계정 삭제"
    fi
  fi
  rm -rf "$APP_DIR"
  ok "${APP_DIR} 삭제 (백업 포함)"
  id -u "$APP_USER" >/dev/null 2>&1 && userdel "$APP_USER" && ok "시스템 계정 삭제" || true
  echo
  echo "${GREEN}${BOLD}완전히 제거되었습니다.${OFF}"
else
  # 코드만 지우고 .env / storage / backups / DB 는 남긴다.
  rm -rf "${APP_DIR}/backend/app" "${APP_DIR}/backend/alembic" \
         "${APP_DIR}/backend/scripts" "${APP_DIR}/backend/.venv"
  ok "코드와 가상환경 제거"
  echo
  echo "${GREEN}${BOLD}서비스를 중지하고 코드를 제거했습니다.${OFF}"
  echo "  데이터는 그대로 있습니다:"
  echo "    설정      ${APP_DIR}/backend/.env"
  echo "    첨부파일   ${APP_DIR}/storage"
  echo "    백업      ${APP_DIR}/backups"
  echo "    데이터베이스는 PostgreSQL 에 그대로 남아 있습니다."
  echo
  echo "  다시 설치하려면 install.sh 를 실행하세요. 기존 설정을 이어받습니다."
  echo "  완전히 지우려면:  sudo ./deploy/uninstall.sh --purge"
fi
