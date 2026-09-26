"""Application settings, loaded from environment / .env."""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic import Field, field_validator, model_validator
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
    TRUSTED_PROXY_IPS: str = ""
    AUTH_RATE_LIMIT_ENABLED: bool = True
    ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 15
    REFRESH_TOKEN_EXPIRE_DAYS: int = 14
    PASSWORD_MIN_LENGTH: int = 8

    # --- cors ---
    CORS_ORIGINS: str = "*"

    # --- bootstrap ---
    FIRST_SUPERADMIN_EMAIL: str = "admin@ddeck.local"
    # 비우면 첫 기동 때 난수 비밀번호를 만들어 로그에 한 번 출력한다 (bootstrap).
    FIRST_SUPERADMIN_PASSWORD: str = ""
    FIRST_SUPERADMIN_NAME: str = "SuperAdmin"

    # --- storage ---
    STORAGE_DIR: str = "./storage"
    MAX_UPLOAD_MB: int = 25

    BACKUP_ROOT: str = ""

    # --- scheduler ---
    SCHEDULER_ENABLED: bool = True
    REMINDER_SCAN_SECONDS: int = 60
    FCM_PROJECT_ID: str = ""
    FCM_CREDENTIALS_FILE: str = ""
    RETENTION_TOKEN_DAYS: int = Field(default=30, ge=1)
    RETENTION_NOTIFICATION_DAYS: int = Field(default=180, ge=1)
    RETENTION_AUDIT_DAYS: int = Field(default=730, ge=1)
    RETENTION_ATTACHMENT_DAYS: int = Field(default=30, ge=1)

    @field_validator("TRUSTED_PROXY_IPS")
    @classmethod
    def _validate_proxies(cls, value: str) -> str:
        from ipaddress import ip_network

        for network in value.split(","):
            if network.strip():
                ip_network(network.strip(), strict=False)
        return value

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

    @model_validator(mode="after")
    def _refuse_unsafe_production(self):
        """운영(ENVIRONMENT=production)에서 개발용 기본값으로 뜨는 것을 막는다.

        .env 가 유실·오타로 읽히지 않으면 조용히 기본값으로 기동하는데, 그 SECRET_KEY 는
        저장소에 그대로 있는 값이라 누구나 최고관리자 토큰을 위조할 수 있다. 여기서
        멈추는 쪽이 낫다. deploy/install.sh 가 만든 .env 는 네 조건을 모두 통과한다.
        """
        if self.ENVIRONMENT.strip().lower() != "production":
            return self
        problems: list[str] = []
        if self.SECRET_KEY.startswith("CHANGE_ME") or len(self.SECRET_KEY) < 32:
            problems.append("SECRET_KEY 가 기본값이거나 32자 미만")
        if self.DEBUG:
            problems.append("DEBUG=true")
        if "*" in self.cors_origin_list:
            problems.append("CORS_ORIGINS=*")
        if self.FIRST_SUPERADMIN_PASSWORD == "admin1234":
            problems.append("FIRST_SUPERADMIN_PASSWORD 가 기본값(admin1234)")
        if problems:
            raise ValueError(
                "운영 환경에서 쓸 수 없는 설정입니다: "
                + ", ".join(problems)
                + ". backend/.env 를 확인하세요 (deploy/install.sh 가 만든 값이 기준)."
            )
        return self

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
