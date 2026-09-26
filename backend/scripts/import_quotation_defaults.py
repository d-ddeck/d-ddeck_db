"""Read the company quotation workbook; use --apply to save supplier defaults.

The workbook and bank account are not copied into source control.
Run from backend: python scripts/import_quotation_defaults.py /path/to/template.xlsx --apply
Without --apply, validates the layout and prints only the names of populated fields.
"""

from __future__ import annotations

import argparse
import base64
import io
import posixpath
import sys
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from openpyxl import load_workbook
from PIL import Image
from sqlalchemy import select

from app.core.database import SessionLocal
from app.models.admin import ModuleSetting
from app.models.enums import ModuleKey
from app.schemas.quotation import Party


def extract_signature(workbook_bytes: bytes) -> bytes | None:
    """Select the image anchored at the closing/signature rows, not the logo."""
    ns = {
        "x": "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing",
        "a": "http://schemas.openxmlformats.org/drawingml/2006/main",
        "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
    }
    with zipfile.ZipFile(io.BytesIO(workbook_bytes)) as archive:
        drawing = "xl/drawings/drawing1.xml"
        rels = "xl/drawings/_rels/drawing1.xml.rels"
        if drawing not in archive.namelist() or rels not in archive.namelist():
            return None
        relationships = {
            r.attrib["Id"]: r.attrib["Target"]
            for r in ET.fromstring(archive.read(rels))
            if r.attrib.get("TargetMode") != "External"
        }
        candidates = []
        for anchor in ET.fromstring(archive.read(drawing)):
            row = anchor.find("x:from/x:row", ns)
            blip = anchor.find("x:pic/x:blipFill/a:blip", ns)
            if row is not None and 28 <= int(row.text) <= 31 and blip is not None:
                target = relationships.get(blip.attrib.get("{" + ns["r"] + "}embed"))
                if target:
                    path = (
                        target.lstrip("/")
                        if target.startswith("/")
                        else posixpath.normpath(posixpath.join("xl/drawings", target))
                    )
                    if not path.startswith("xl/media/"):
                        raise ValueError("서명 이미지 경로를 확인하세요.")
                    if archive.getinfo(path).file_size > 2 * 1024 * 1024:
                        raise ValueError("서명 이미지는 2MB 이하만 지원합니다.")
                    data = archive.read(path)
                    with Image.open(io.BytesIO(data)) as image:
                        if image.format != "PNG" or max(image.size) > 4096:
                            raise ValueError(
                                "서명 이미지는 4096px 이하 PNG여야 합니다."
                            )
                        image.verify()
                    candidates.append(data)
        if len(candidates) > 1:
            raise ValueError(
                "서명 위치에 이미지가 여러 개 있어 자동 선택할 수 없습니다."
            )
        return candidates[0] if candidates else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workbook", type=Path)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    workbook_bytes = args.workbook.read_bytes()
    signature = extract_signature(workbook_bytes)
    workbook = load_workbook(io.BytesIO(workbook_bytes), data_only=True)
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
    print("Signature image present:", bool(signature))
    if not args.apply:
        print("No database changes. Use --apply to save these defaults.")
        return
    with SessionLocal() as db:
        for key, value, kind, label in [
            ("quotation_supplier", supplier, "json", "견적서 기본 공급자 정보"),
            ("quotation_bank_account", bank, "string", "견적서 기본 입금계좌"),
            (
                "quotation_signature",
                {
                    "company": supplier["company"],
                    "contact": supplier["contact"],
                    "png_base64": base64.b64encode(signature).decode("ascii"),
                }
                if signature
                else {},
                "json",
                "견적서 서명 (양식에서 가져옴)",
            ),
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
