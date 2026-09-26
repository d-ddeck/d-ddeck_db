"""Read the company quotation workbook; use --apply to save supplier defaults.

The workbook and bank account are not copied into source control.
Run from backend: python scripts/import_quotation_defaults.py /path/to/template.xlsx --apply
Without --apply, validates the layout and prints only the names of populated fields.
"""

from __future__ import annotations

import argparse
import io
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from openpyxl import load_workbook
from sqlalchemy import select

from app.core.database import SessionLocal
from app.models.admin import ModuleSetting
from app.models.enums import ModuleKey
from app.schemas.quotation import Party


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workbook", type=Path)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    workbook = load_workbook(io.BytesIO(args.workbook.read_bytes()), data_only=True)
    sheet = workbook["견적서"]
    supplier = Party(
        **{
            key: str(sheet[cell].value or "").strip()
            for key, cell in {
                "company": "C10",
                "contact": "C11",
                "address": "C12",
                "phone": "C13",
                "email": "C14",
            }.items()
        }
    ).model_dump()
    bank = str(sheet["F7"].value or "").strip()
    if len(bank) > 200:
        raise ValueError("입금계좌는 최대 200자입니다.")
    print("Validated supplier fields:", ", ".join(k for k, v in supplier.items() if v))
    print("Bank account present:", bool(bank))
    if not args.apply:
        print("No database changes. Use --apply to save these defaults.")
        return
    with SessionLocal() as db:
        for key, value, kind, label in [
            ("quotation_supplier", supplier, "json", "견적서 기본 공급자 정보"),
            ("quotation_bank_account", bank, "string", "견적서 기본 입금계좌"),
        ]:
            row = db.scalar(
                select(ModuleSetting).where(
                    ModuleSetting.module == ModuleKey.SERVICE, ModuleSetting.key == key
                )
            )
            if row is None:
                db.add(
                    ModuleSetting(
                        module=ModuleKey.SERVICE,
                        key=key,
                        value=value,
                        value_type=kind,
                        label=label,
                        is_public=False,
                    )
                )
            else:
                row.value = value
        db.commit()
    print("Saved supplier defaults. Existing quotation versions were not changed.")


if __name__ == "__main__":
    main()
