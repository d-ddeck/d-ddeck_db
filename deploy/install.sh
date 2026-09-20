#!/usr/bin/env bash
#
# d-ddeck DB Server - Ubuntu 설치 스크립트
#
#   sudo ./deploy/install.sh
#
# 하는 일:
#   1. Python 3.11+ 확보 (없으면 설치)
#   2. PostgreSQL 설치 + DB/계정 생성
#   3. /opt/ddeck 에 코드 배치 + 가상환경 구성
#   4. .env 자동 생성 (SECRET_KEY, DB 비밀번호 난수)
#   5. Alembic 마이그레이션 적용
#   6. systemd 서비스 등록 (부팅 시 자동 시작)
#   7. 방화벽 + mDNS(.local 이름) 설정
#   8. 동작 확인 후 접속 정보 출력
#
# 여러 번 실행해도 안전합니다(재실행 시 기존 설정 유지).

set -euo pipefail

# ------------------------------------------------------------------ 설정
APP_NAME="ddeck"
APP_DIR="/opt/${APP_NAME}"
APP_USER="${APP_NAME}"
SERVICE="${APP_NAME}"
PORT="${PORT:-8000}"
DB_NAME="${DB_NAME:-ddeck}"
DB_USER="${DB_USER:-ddeck}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@ddeck.local}"
MIN_PY_MINOR=11   # StrEnum 사용으로 3.11 이상 필요

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; BOLD=$'\e[1m'; OFF=$'\e[0m'
step()  { echo; echo "${BLUE}${BOLD}▶ $*${OFF}"; }
ok()    { echo "  ${GREEN}✓${OFF} $*"; }
warn()  { echo "  ${YELLOW}!${OFF} $*"; }
die()   { echo; echo "${RED}${BOLD}✗ $*${OFF}" >&2; exit 1; }

usage() {
  cat <<USAGE
사용법: sudo ./deploy/install.sh [옵션]

옵션:
  --port <번호>      서비스 포트 (기본 8000)
  --admin <이메일>   최고 관리자 이메일 (기본 admin@ddeck.local)
  --sqlite           PostgreSQL 대신 SQLite 사용 (소규모/임시)
  -h, --help         이 도움말

예: sudo ./deploy/install.sh --port 8080 --admin it@mycompany.co.kr
USAGE
  exit 0
}

USE_SQLITE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)  PORT="$2"; shift 2 ;;
    --admin) ADMIN_EMAIL="$2"; shift 2 ;;
    --sqlite) USE_SQLITE=1; shift ;;
    -h|--help) usage ;;
    *) die "알 수 없는 옵션: $1 (--help 참고)" ;;
  esac
done

# ------------------------------------------------------------------ 사전 점검
step "사전 점검"

[[ $EUID -eq 0 ]] || die "root 권한이 필요합니다.  sudo ./deploy/install.sh"

# 스크립트 위치 기준으로 backend 소스를 찾는다 (리포 루트/deploy 어디서 실행해도 동작).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if   [[ -d "${SCRIPT_DIR}/../backend/app" ]]; then SRC="$(cd "${SCRIPT_DIR}/.." && pwd)/backend"
elif [[ -d "${SCRIPT_DIR}/backend/app"    ]]; then SRC="${SCRIPT_DIR}/backend"
else die "backend 폴더를 찾을 수 없습니다. 리포지토리 안에서 실행해 주세요."; fi
ok "소스: ${SRC}"

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  ok "OS: ${PRETTY_NAME:-unknown}"
  [[ "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *debian* ]] \
    || warn "Ubuntu/Debian 계열이 아닙니다. 계속 진행하지만 패키지 설치가 실패할 수 있습니다."
fi

# 포트 충돌 확인 - 이 미니PC가 이미 다른 서버로 쓰이고 있을 수 있다.
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}$"; then
  echo
  ss -ltnp 2>/dev/null | grep -E "[:.]${PORT}\s" || true
  die "포트 ${PORT} 이(가) 이미 사용 중입니다. --port 로 다른 포트를 지정하세요."
fi
ok "포트 ${PORT} 사용 가능"

# ------------------------------------------------------------------ Python
step "Python 확보 (3.${MIN_PY_MINOR}+ 필요)"

pick_python() {
  for c in python3.13 python3.12 python3.11 python3; do
    command -v "$c" >/dev/null 2>&1 || continue
    local minor
    minor="$("$c" -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo 0)"
    local major
    major="$("$c" -c 'import sys; print(sys.version_info.major)' 2>/dev/null || echo 0)"
    if [[ "$major" == "3" && "$minor" -ge "$MIN_PY_MINOR" ]]; then echo "$c"; return 0; fi
  done
  return 1
}

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

if ! PY="$(pick_python)"; then
  warn "3.${MIN_PY_MINOR}+ 이 없습니다. 설치를 시도합니다."
  # Ubuntu 22.04는 3.10이 기본이라 deadsnakes PPA가 필요하다.
  apt-get install -y -qq software-properties-common >/dev/null
  add-apt-repository -y ppa:deadsnakes/ppa >/dev/null 2>&1 || \
    warn "deadsnakes PPA 추가 실패 - 기본 저장소로 시도합니다."
  apt-get update -qq
  apt-get install -y -qq python3.12 python3.12-venv python3.12-dev >/dev/null 2>&1 \
    || apt-get install -y -qq python3.11 python3.11-venv python3.11-dev >/dev/null 2>&1 \
    || die "Python 3.${MIN_PY_MINOR}+ 설치에 실패했습니다. 수동으로 설치 후 다시 실행해 주세요."
  PY="$(pick_python)" || die "설치 후에도 Python 3.${MIN_PY_MINOR}+ 를 찾을 수 없습니다."
fi
ok "Python: $("$PY" --version) ($(command -v "$PY"))"

# venv 모듈이 별도 패키지인 배포판 대응
"$PY" -m venv --help >/dev/null 2>&1 || {
  PYVER="$("$PY" -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  apt-get install -y -qq "python${PYVER}-venv" >/dev/null || die "python${PYVER}-venv 설치 실패"
}

# ------------------------------------------------------------------ 시스템 패키지
step "시스템 패키지 설치"
PKGS=(build-essential libpq-dev curl ca-certificates avahi-daemon rsync openssl sqlite3)
[[ $USE_SQLITE -eq 0 ]] && PKGS+=(postgresql postgresql-contrib)
apt-get install -y -qq "${PKGS[@]}" >/dev/null
ok "설치 완료: ${PKGS[*]}"

# ------------------------------------------------------------------ 계정 / 디렉터리
step "서비스 계정과 디렉터리 준비"
if ! id -u "$APP_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
  ok "시스템 계정 '${APP_USER}' 생성"
else
  ok "시스템 계정 '${APP_USER}' 이미 존재"
fi

mkdir -p "$APP_DIR"/{backend,storage,backups}
# 소스 복사. .env / storage / DB 파일은 덮어쓰지 않는다.
rsync -a --delete \
  --exclude '.venv' --exclude '__pycache__' --exclude '*.pyc' \
  --exclude '.env' --exclude 'storage' --exclude '*.db' --exclude '*.db-*' \
  "$SRC"/ "$APP_DIR/backend"/
ok "코드 배치: ${APP_DIR}/backend"

# ------------------------------------------------------------------ 가상환경
step "가상환경 구성 (몇 분 걸릴 수 있습니다)"
if [[ ! -x "$APP_DIR/backend/.venv/bin/python" ]]; then
  "$PY" -m venv "$APP_DIR/backend/.venv"
fi
VENV_PY="$APP_DIR/backend/.venv/bin/python"
"$VENV_PY" -m pip install --quiet --upgrade pip wheel
"$VENV_PY" -m pip install --quiet -r "$APP_DIR/backend/requirements.txt"
ok "의존성 설치 완료"

# ------------------------------------------------------------------ 데이터베이스
ENV_FILE="$APP_DIR/backend/.env"

if [[ -f "$ENV_FILE" ]] && grep -q '^DATABASE_URL=' "$ENV_FILE"; then
  # 재실행: 기존 .env 가 유일한 진실이다. 여기서 새로 만들면 기존 데이터와 연결이 끊긴다.
  step "데이터베이스: 기존 설정 재사용"
  DATABASE_URL="$(grep '^DATABASE_URL=' "$ENV_FILE" | cut -d= -f2-)"
  [[ "$DATABASE_URL" == postgresql* ]] && { systemctl enable --now postgresql >/dev/null 2>&1 || true; }
  ok "${DATABASE_URL%%:*} (기존 .env 에서 읽음)"

elif [[ $USE_SQLITE -eq 1 ]]; then
  step "데이터베이스: SQLite"
  DATABASE_URL="sqlite+pysqlite:///${APP_DIR}/backend/ddeck.db"
  ok "경로: ${APP_DIR}/backend/ddeck.db"

else
  step "데이터베이스: PostgreSQL"
  systemctl enable --now postgresql >/dev/null 2>&1 || true

  DB_PASS="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
    sudo -u postgres psql -q -c "ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASS}';"
    ok "기존 DB 계정 '${DB_USER}' 비밀번호 갱신"
  else
    sudo -u postgres psql -q -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';"
    ok "DB 계정 '${DB_USER}' 생성"
  fi

  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
    # 애플리케이션은 모든 시각을 UTC로 저장하므로 로캘은 C로 고정한다.
    sudo -u postgres psql -q -c \
      "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;"
    ok "데이터베이스 '${DB_NAME}' 생성"
  else
    ok "데이터베이스 '${DB_NAME}' 이미 존재"
  fi

  sudo -u postgres psql -q -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};"
  # PostgreSQL 15부터 public 스키마의 CREATE 권한이 기본 회수된다. 이 두 줄이 없으면
  # 마이그레이션이 'permission denied for schema public' 로 실패한다.
  sudo -u postgres psql -d "${DB_NAME}" -q -c "ALTER SCHEMA public OWNER TO ${DB_USER};"
  sudo -u postgres psql -d "${DB_NAME}" -q -c "GRANT ALL ON SCHEMA public TO ${DB_USER};"
  ok "public 스키마 권한 부여"

  DATABASE_URL="postgresql+psycopg://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}"
fi

# ------------------------------------------------------------------ .env
step "환경 설정 생성"
if [[ -f "$ENV_FILE" ]]; then
  ok ".env 가 이미 있어 유지합니다 (${ENV_FILE})"
  ADMIN_PASS="(기존 설정 유지 - 변경하려면 .env 수정 후 재시작)"
else
  SECRET_KEY="$("$VENV_PY" -c 'import secrets;print(secrets.token_urlsafe(64))')"
  ADMIN_PASS="$(openssl rand -base64 18 | tr -d '/+=' | head -c 16)"
  cat > "$ENV_FILE" <<ENVEOF
# d-ddeck DB Server - install.sh 가 생성함 ($(date -Iseconds))
APP_NAME="d-ddeck DB Server"
ENVIRONMENT=production
DEBUG=false
API_V1_PREFIX=/api/v1

DATABASE_URL=${DATABASE_URL}

SECRET_KEY=${SECRET_KEY}
ACCESS_TOKEN_EXPIRE_MINUTES=60
REFRESH_TOKEN_EXPIRE_DAYS=14
PASSWORD_MIN_LENGTH=8

# 데스크톱/모바일 앱은 Bearer 토큰을 쓰므로 브라우저 CORS가 필요 없다.
# 웹 클라이언트를 붙이면 그 주소를 쉼표로 나열할 것.
CORS_ORIGINS=

FIRST_SUPERADMIN_EMAIL=${ADMIN_EMAIL}
FIRST_SUPERADMIN_PASSWORD=${ADMIN_PASS}
FIRST_SUPERADMIN_NAME=최고관리자

STORAGE_DIR=${APP_DIR}/storage
MAX_UPLOAD_MB=25

SCHEDULER_ENABLED=true
REMINDER_SCAN_SECONDS=60
FCM_SERVER_KEY=
ENVEOF
  ok ".env 생성 (SECRET_KEY / 관리자 비밀번호 난수 생성)"
fi
chmod 600 "$ENV_FILE"
chown -R "$APP_USER":"$APP_USER" "$APP_DIR"

# ------------------------------------------------------------------ 마이그레이션
step "데이터베이스 스키마 적용"
cd "$APP_DIR/backend"
sudo -u "$APP_USER" "$VENV_PY" -m alembic upgrade head
ok "Alembic 마이그레이션 완료"

# ------------------------------------------------------------------ systemd
step "systemd 서비스 등록"
cat > "/etc/systemd/system/${SERVICE}.service" <<UNITEOF
[Unit]
Description=d-ddeck DB Server
Documentation=file://${APP_DIR}/backend
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}/backend
ExecStart=${APP_DIR}/backend/.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port ${PORT}
Restart=always
RestartSec=5

# 일정 알림 스케줄러가 인프로세스로 돌기 때문에 워커는 1개여야 한다.
# 여러 개로 늘리면 같은 알림이 중복 발송된다.

# 파일 쓰기는 storage/backups 에만 허용
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${APP_DIR}/storage ${APP_DIR}/backups ${APP_DIR}/backend

StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE}

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable "${SERVICE}" >/dev/null
systemctl restart "${SERVICE}"
ok "서비스 등록 및 시작 (부팅 시 자동 실행)"

# ------------------------------------------------------------------ 방화벽 / mDNS
step "네트워크 설정"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${PORT}/tcp" >/dev/null && ok "방화벽 ${PORT}/tcp 허용"
else
  ok "ufw 비활성 상태 - 방화벽 규칙 불필요"
fi
systemctl enable --now avahi-daemon >/dev/null 2>&1 \
  && ok "mDNS 활성화 (.local 이름으로 접속 가능)" \
  || warn "avahi-daemon 시작 실패 - IP로만 접속 가능합니다"

# ------------------------------------------------------------------ 동작 확인
step "동작 확인"
HEALTH=""
for i in $(seq 1 30); do
  if HEALTH="$(curl -fsS -m 2 "http://127.0.0.1:${PORT}/healthz" 2>/dev/null)"; then break; fi
  sleep 1
done

if [[ -z "$HEALTH" ]]; then
  echo
  journalctl -u "${SERVICE}" -n 30 --no-pager || true
  die "서버가 응답하지 않습니다. 위 로그를 확인해 주세요."
fi
ok "healthz 응답: ${HEALTH}"

TABLES="$(curl -fsS -m 3 "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
[[ -n "$TABLES" ]] && ok "API 루트 응답 정상"

# ------------------------------------------------------------------ 접속 정보
LAN_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -vE '^(127\.|172\.1[7-9]\.|172\.2[0-9]\.|172\.3[01]\.)' | head -1)"
HOSTNAME_LOCAL="$(hostname).local"

cat <<SUMMARY

${GREEN}${BOLD}════════════════════════════════════════════════════════════${OFF}
${GREEN}${BOLD}  설치 완료${OFF}
${GREEN}${BOLD}════════════════════════════════════════════════════════════${OFF}

${BOLD}클라이언트에서 입력할 서버 주소${OFF}
    http://${LAN_IP}:${PORT}
    http://${HOSTNAME_LOCAL}:${PORT}      ${YELLOW}← IP가 바뀌어도 동작 (권장)${OFF}

${BOLD}최고 관리자 계정${OFF}
    이메일   ${ADMIN_EMAIL}
    비밀번호 ${ADMIN_PASS}
    ${YELLOW}첫 로그인 시 비밀번호 변경 화면이 강제로 뜹니다.${OFF}
    ${YELLOW}이 비밀번호는 다시 표시되지 않습니다. 지금 기록해 두세요.${OFF}

${BOLD}API 문서${OFF}
    http://${LAN_IP}:${PORT}/docs

${BOLD}서비스 관리${OFF}
    systemctl status ${SERVICE}
    systemctl restart ${SERVICE}
    journalctl -u ${SERVICE} -f            로그 실시간 보기

${BOLD}다음에 할 일${OFF}
    1. 미니PC에 고정 IP 설정 (공유기 DHCP 예약 권장)
    2. 백업 등록:  sudo ${SCRIPT_DIR}/backup.sh --install-cron
    3. 코드 갱신:  sudo ${SCRIPT_DIR}/update.sh

SUMMARY
