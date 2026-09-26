"""Password hashing and JWT issue/verify."""

from __future__ import annotations

import hashlib
import secrets
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any, Literal

import bcrypt
import jwt

from app.core.config import settings

TokenType = Literal["access", "refresh"]

# bcrypt truncates silently past 72 bytes; pre-hash so long passwords stay distinct.
_BCRYPT_MAX_BYTES = 72


def _prepare(password: str) -> bytes:
    raw = password.encode("utf-8")
    if len(raw) > _BCRYPT_MAX_BYTES:
        return hashlib.sha256(raw).hexdigest().encode("utf-8")
    return raw


def hash_password(password: str) -> str:
    return bcrypt.hashpw(_prepare(password), bcrypt.gensalt()).decode("utf-8")


def verify_password(password: str, hashed: str) -> bool:
    try:
        return bcrypt.checkpw(_prepare(password), hashed.encode("utf-8"))
    except (ValueError, TypeError):
        return False


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def create_token(
    subject: str | uuid.UUID,
    token_type: TokenType,
    extra_claims: dict[str, Any] | None = None,
) -> tuple[str, datetime]:
    """Returns (encoded_jwt, expires_at)."""
    if token_type == "access":
        expires = now_utc() + timedelta(minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES)
    else:
        expires = now_utc() + timedelta(days=settings.REFRESH_TOKEN_EXPIRE_DAYS)

    payload: dict[str, Any] = {
        "sub": str(subject),
        "typ": token_type,
        "iat": int(now_utc().timestamp()),
        "exp": int(expires.timestamp()),
        "jti": secrets.token_urlsafe(16),
    }
    if extra_claims:
        payload.update(extra_claims)
    token = jwt.encode(payload, settings.SECRET_KEY, algorithm=settings.ALGORITHM)
    return token, expires


def decode_token(token: str, expected_type: TokenType | None = None) -> dict[str, Any]:
    """Raises jwt.PyJWTError on anything wrong (expiry, signature, wrong type)."""
    payload = jwt.decode(token, settings.SECRET_KEY, algorithms=[settings.ALGORITHM])
    if expected_type and payload.get("typ") != expected_type:
        raise jwt.InvalidTokenError(f"expected {expected_type} token")
    return payload


def hash_refresh_token(token: str) -> str:
    """Refresh tokens are stored hashed so a DB leak cannot replay sessions."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def validate_password_strength(password: str) -> list[str]:
    """Returns a list of human-readable problems; empty list means OK."""
    problems: list[str] = []
    if len(password) < settings.PASSWORD_MIN_LENGTH:
        problems.append(
            f"비밀번호는 {settings.PASSWORD_MIN_LENGTH}자 이상이어야 합니다."
        )
    if not any(c.isalpha() for c in password):
        problems.append("영문자를 1자 이상 포함해야 합니다.")
    if not any(c.isdigit() for c in password):
        problems.append("숫자를 1자 이상 포함해야 합니다.")
    return problems
