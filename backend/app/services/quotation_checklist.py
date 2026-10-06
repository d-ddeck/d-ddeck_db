"""견적서 체크리스트: 체크하면 안내사항 문구와 견적 품목을 채워 주는 항목들.

관리자가 설정(SERVICE.quotation_checklist, json)으로 관리한다. json 설정은 형식이
자유라서, 저장 전에 여기서 모양을 맞추고 견적서가 받을 수 없는 값은 막는다.
"""

from __future__ import annotations

import re
import uuid
from typing import Any

from pydantic import ValidationError

from app.schemas.quotation import QuoteLine

KEY = "quotation_checklist"
MAX_ENTRIES = 50
MAX_ITEMS = 20
_ID = re.compile(r"[A-Za-z0-9_-]{1,40}")


def normalize(value: Any) -> list[dict]:
    """설정값을 저장할 모양으로 맞춘다. 맞출 수 없으면 TypeError/ValueError."""
    if not isinstance(value, list):
        raise TypeError("견적서 체크리스트는 목록이어야 합니다")
    if len(value) > MAX_ENTRIES:
        raise ValueError(f"체크리스트는 {MAX_ENTRIES}개까지 등록할 수 있습니다")
    out: list[dict] = []
    seen: set[str] = set()
    for entry in value:
        if not isinstance(entry, dict):
            raise TypeError("체크리스트 항목 형식이 올바르지 않습니다")
        ident = str(entry.get("id") or "").strip() or uuid.uuid4().hex[:12]
        if not _ID.fullmatch(ident) or ident in seen:
            raise ValueError("체크리스트 항목 id가 올바르지 않거나 중복됩니다")
        seen.add(ident)
        label = str(entry.get("label") or "").strip()
        if not 1 <= len(label) <= 60:
            raise ValueError("체크리스트 이름은 1~60자로 입력하세요")
        notes = str(entry.get("notes") or "").strip()
        if len(notes) > 1000:
            raise ValueError(f"'{label}' 안내사항은 1000자까지 입력할 수 있습니다")
        raw_items = entry.get("items") or []
        if not isinstance(raw_items, list) or len(raw_items) > MAX_ITEMS:
            raise ValueError(f"'{label}' 품목은 {MAX_ITEMS}개까지 등록할 수 있습니다")
        items = []
        for raw in raw_items:
            try:
                line = QuoteLine.model_validate(raw)
            except ValidationError:
                raise ValueError(f"'{label}' 품목의 품명·수량·단가를 확인하세요") from None
            quantity = format(line.quantity, "f")
            items.append(
                {
                    "name": line.name,
                    "specification": line.specification,
                    "quantity": quantity.rstrip("0").rstrip(".") if "." in quantity else quantity,
                    "unit_price": str(int(line.unit_price)),
                    "note": line.note,
                }
            )
        if not notes and not items:
            raise ValueError(f"'{label}'에 채울 안내사항이나 품목을 입력하세요")
        out.append(
            {
                "id": ident,
                "label": label,
                "notes": notes,
                "items": items,
                "active": entry.get("active", True) is not False,
            }
        )
    return out


def active(value: Any) -> list[dict]:
    """견적서 작성 화면에 보여 줄 항목. 저장값이 깨져 있으면 빈 목록."""
    try:
        return [e for e in normalize(value or []) if e["active"]]
    except (TypeError, ValueError):
        return []
