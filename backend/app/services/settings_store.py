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
    rows = db.scalars(
        select(ModuleSetting).where(ModuleSetting.module == module)
    ).all()
    return {r.key: _coerce(r.value, r.value_type, None) for r in rows}


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
