"""Application settings, loaded from environment / .env."""
from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

BASE_DIR = Path(__file__).resolve().parents[2]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=str(BASE_DIR / ".env"),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # --- app ---
    APP_NAME: str = "d-ddeck DB Server"
    ENVIRONMENT: str = "development"
    DEBUG: bool = True
    API_V1_PREFIX: str = "/api/v1"

    # --- db ---
    DATABASE_URL: str = "sqlite+pysqlite:///./ddeck.db"

    # --- security ---
    SECRET_KEY: str = "CHANGE_ME_dev_only_secret_key_do_not_use_in_production"
    ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 60
    REFRESH_TOKEN_EXPIRE_DAYS: int = 14
    PASSWORD_MIN_LENGTH: int = 8

    # --- cors ---
    CORS_ORIGINS: str = "*"

    # --- bootstrap ---
    FIRST_SUPERADMIN_EMAIL: str = "admin@ddeck.local"
    FIRST_SUPERADMIN_PASSWORD: str = "admin1234"
    FIRST_SUPERADMIN_NAME: str = "SuperAdmin"

    # --- storage ---
    STORAGE_DIR: str = "./storage"
    MAX_UPLOAD_MB: int = 25

    # --- scheduler ---
    SCHEDULER_ENABLED: bool = True
    REMINDER_SCAN_SECONDS: int = 60
    FCM_SERVER_KEY: str = ""

    @field_validator("DATABASE_URL")
    @classmethod
    def _normalize_db_url(cls, v: str) -> str:
        # Accept the bare "postgresql://" form that hosting panels hand out
        # and steer it onto the psycopg3 driver we actually depend on.
        if v.startswith("postgresql://"):
            return v.replace("postgresql://", "postgresql+psycopg://", 1)
        if v.startswith("sqlite:///"):
            return v.replace("sqlite:///", "sqlite+pysqlite:///", 1)
        return v

    @property
    def is_sqlite(self) -> bool:
        return self.DATABASE_URL.startswith("sqlite")

    @property
    def is_postgres(self) -> bool:
        return self.DATABASE_URL.startswith("postgresql")

    @property
    def cors_origin_list(self) -> list[str]:
        raw = self.CORS_ORIGINS.strip()
        if raw == "*":
            return ["*"]
        return [o.strip() for o in raw.split(",") if o.strip()]

    @property
    def storage_path(self) -> Path:
        p = Path(self.STORAGE_DIR)
        return p if p.is_absolute() else (BASE_DIR / p).resolve()


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
