"""ASGI entrypoint.

Run:  uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
Docs: http://127.0.0.1:8000/docs   (OpenAPI JSON at /openapi.json)
"""
from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.v1.router import api_router
from app.core.config import settings
from app.core.database import SessionLocal, engine
from app.core.errors import register_exception_handlers
from app.models import Base
from app.services import bootstrap, scheduler

logging.basicConfig(
    level=logging.DEBUG if settings.DEBUG else logging.INFO,
    format="%(asctime)s %(levelname)-8s %(name)s | %(message)s",
)
log = logging.getLogger("ddeck")

DESCRIPTION = """
사내 통합 DB 서버 API.

**진입 순서**: 회원가입 → 관리자 승인 → 로그인 → 이용

| 모듈 | prefix | 내용 |
|---|---|---|
| 인증 | `/auth` | 가입 · 로그인 · 토큰 · 세션 · 기기 등록 |
| 사용자 | `/users` | 승인 대기열 · 권한 · 구성원 목록 |
| 서비스(AS) | `/service` | 접수 · 처리 이력 · 부품 · **자동 통계** |
| 재고관리 | `/inventory` | 자산 · 위치 트리 · 이동 이력 |
| 게시판 | `/board` | 게시판 설정 · 게시글 · 댓글 |
| 캘린더 | `/calendar` | 일정 공유 · 참석자 · 알림 |
| 관리기능 | `/admin` | **모듈별 설정** · 분류 코드 · 부서 · 감사로그 · 상태 |
| 첨부 | `/files` | 공통 파일 업로드/다운로드 |

인증은 `Authorization: Bearer <access_token>` 헤더를 사용합니다.
""".strip()


@asynccontextmanager
async def lifespan(_: FastAPI):
    # create_all is the skeleton's schema path. Once the shape settles, switch
    # to `alembic upgrade head` and drop this line - see alembic/README.
    Base.metadata.create_all(bind=engine)
    settings.storage_path.mkdir(parents=True, exist_ok=True)

    db = SessionLocal()
    try:
        bootstrap.run(db)
    finally:
        db.close()

    scheduler.start()
    log.info(
        "%s started | env=%s | db=%s",
        settings.APP_NAME,
        settings.ENVIRONMENT,
        engine.dialect.name,
    )
    yield
    scheduler.shutdown()


app = FastAPI(
    title=settings.APP_NAME,
    description=DESCRIPTION,
    version="0.1.0",
    lifespan=lifespan,
    docs_url="/docs",
    redoc_url="/redoc",
)

# Wildcard CORS and credentials cannot be combined, and desktop/mobile clients
# do not need cookie credentials anyway - they send a bearer token.
origins = settings.cors_origin_list
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=origins != ["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

register_exception_handlers(app)
app.include_router(api_router, prefix=settings.API_V1_PREFIX)


@app.get("/", tags=["meta"])
def root():
    return {
        "name": settings.APP_NAME,
        "version": "0.1.0",
        "api": settings.API_V1_PREFIX,
        "docs": "/docs",
    }


@app.get("/healthz", tags=["meta"])
def healthz():
    """Unauthenticated liveness probe for a load balancer or systemd."""
    return {"status": "ok"}
