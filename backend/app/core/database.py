"""Engine / session wiring. Portable between SQLite (dev) and PostgreSQL (prod)."""

from __future__ import annotations

from collections.abc import Generator

from sqlalchemy import create_engine, event
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session, sessionmaker

from app.core.config import settings

_connect_args: dict = {}
_engine_kwargs: dict = {"pool_pre_ping": True, "future": True}

if settings.is_sqlite:
    # SQLite + FastAPI threadpool: the default same-thread check has to go.
    _connect_args["check_same_thread"] = False
else:
    _engine_kwargs.update(pool_size=10, max_overflow=20, pool_recycle=1800)

engine: Engine = create_engine(
    settings.DATABASE_URL, connect_args=_connect_args, echo=False, **_engine_kwargs
)


@event.listens_for(engine, "connect")
def _sqlite_pragmas(dbapi_conn, _record):  # pragma: no cover - driver level
    """SQLite ignores FK constraints unless asked; WAL keeps reads unblocked.

    또 pysqlite 의 기본 트랜잭션 처리는 SAVEPOINT 를 망가뜨린다(RELEASE 때 통째로
    COMMIT 해 버려, 뒤에 오류가 나도 앞의 INSERT 가 남는다). SQLAlchemy 문서의
    처방대로 드라이버의 BEGIN 을 끄고 우리가 직접 BEGIN 을 낸다(아래 _sqlite_begin).
    접수번호·자산번호 채번의 begin_nested() 와 일괄 이동의 건별 롤백이 이것에 기댄다.
    """
    if not settings.is_sqlite:
        return
    dbapi_conn.isolation_level = None
    cur = dbapi_conn.cursor()
    cur.execute("PRAGMA foreign_keys=ON")
    cur.execute("PRAGMA journal_mode=WAL")
    cur.close()


@event.listens_for(engine, "begin")
def _sqlite_begin(conn):  # pragma: no cover - driver level
    if settings.is_sqlite:
        conn.exec_driver_sql("BEGIN")


SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False, future=True)


def get_db() -> Generator[Session, None, None]:
    """FastAPI dependency: one session per request, always closed."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
