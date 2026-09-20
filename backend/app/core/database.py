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
    """SQLite ignores FK constraints unless asked; WAL keeps reads unblocked."""
    if not settings.is_sqlite:
        return
    cur = dbapi_conn.cursor()
    cur.execute("PRAGMA foreign_keys=ON")
    cur.execute("PRAGMA journal_mode=WAL")
    cur.close()


SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False, future=True)


def get_db() -> Generator[Session, None, None]:
    """FastAPI dependency: one session per request, always closed."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
