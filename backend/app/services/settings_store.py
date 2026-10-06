"""Typed read access to ModuleSetting rows.

Named settings_store rather than settings to avoid colliding with
app.core.config.settings, which is the environment config.
"""

from __future__ import annotations

from typing import Any, TypeVar

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.admin import ModuleSetting
from app.models.enums import ModuleKey

T = TypeVar("T")


def get(db: Session, module: ModuleKey, key: str, default: T = None) -> T | Any:
    """Reads one setting. Falls back to `default` when the row is missing, so a
    half-seeded database degrades instead of erroring."""
    row = db.scalar(
        select(ModuleSetting).where(
            ModuleSetting.module == module, ModuleSetting.key == key
        )
    )
    if row is None or row.value is None:
        return default
    return _coerce(row.value, row.value_type, default)


def get_many(db: Session, module: ModuleKey) -> dict[str, Any]:
    rows = db.scalars(select(ModuleSetting).where(ModuleSetting.module == module)).all()
    return {r.key: _coerce(r.value, r.value_type, None) for r in rows}


def normalize(key: str, value: Any, value_type: str) -> Any:
    """저장 전에 값을 선언된 타입으로 맞춘다. 못 맞추면 ValueError.

    저장 쪽에서 막지 않으면 소비 쪽이 깨진다: `default_due_days` 가 "3일" 이면 접수 등록이
    전부 500 이 되고, `maker_required_categories` 가 문자열이면 글자 집합이 되어 제조사
    필수 규칙이 조용히 꺼진다. 설정창이 문자열로 보낸 "3" 이나 "a, b" 는 고쳐 준다.
    """
    if value is None:
        return None
    if key == "quotation_checklist":
        from app.core.errors import AppError
        from app.services import quotation_checklist

        # 어느 항목의 무엇이 틀렸는지 그대로 보여 준다.
        try:
            return quotation_checklist.normalize(value)
        except (TypeError, ValueError) as exc:
            raise AppError("INVALID_SETTING_VALUE", str(exc)) from None
    if value_type == "int":
        if isinstance(value, bool):
            raise ValueError(f"{key}: 정수가 필요합니다")
        if isinstance(value, int):
            return value
        if isinstance(value, float) and value.is_integer():
            return int(value)
        if isinstance(value, str) and value.strip().lstrip("-").isdigit():
            return int(value.strip())
        raise ValueError(f"{key}: 정수가 필요합니다")
    if value_type == "float":
        if isinstance(value, bool):
            raise ValueError(f"{key}: 숫자가 필요합니다")
        if isinstance(value, (int, float)):
            return float(value)
        if isinstance(value, str):
            return float(value.strip())
        raise ValueError(f"{key}: 숫자가 필요합니다")
    if value_type == "bool":
        if isinstance(value, bool):
            return value
        if isinstance(value, str):
            low = value.strip().lower()
            if low in {"1", "true", "yes", "on"}:
                return True
            if low in {"0", "false", "no", "off"}:
                return False
        raise ValueError(f"{key}: 참/거짓이 필요합니다")
    if value_type == "list":
        if isinstance(value, (list, tuple)):
            return list(value)
        if isinstance(value, str):
            return [part.strip() for part in value.split(",") if part.strip()]
        raise ValueError(f"{key}: 목록이 필요합니다")
    if value_type == "string":
        if isinstance(value, str):
            return value
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return str(value)
        raise ValueError(f"{key}: 문자열이 필요합니다")
    return value  # json: 형식 자유


def _coerce(value: Any, value_type: str, default: Any) -> Any:
    # Values round-trip through JSON, so they usually arrive already typed.
    # This only repairs the case where a settings screen posted a raw string.
    try:
        if value_type == "int":
            return int(value)
        if value_type == "float":
            return float(value)
        if value_type == "bool":
            if isinstance(value, bool):
                return value
            return str(value).strip().lower() in {"1", "true", "yes", "on"}
        if value_type == "list":
            return list(value) if isinstance(value, (list, tuple)) else [value]
        return value
    except (TypeError, ValueError):
        return default
