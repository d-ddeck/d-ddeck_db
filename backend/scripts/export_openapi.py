"""Dump the OpenAPI spec to docs/openapi.json without starting the server.

The Flutter client contract reference. Regenerate whenever an endpoint or schema changes:

    python scripts/export_openapi.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app.main import app

OUT = ROOT.parent / "docs" / "openapi.json"


def main() -> None:
    spec = app.openapi()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(
        json.dumps(spec, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    operations = sum(
        1
        for path in spec["paths"].values()
        for method in path
        if method in {"get", "post", "put", "patch", "delete"}
    )
    print(f"wrote {OUT}")
    print(
        f"  {len(spec['paths'])} paths / {operations} operations / "
        f"{len(spec['components']['schemas'])} schemas"
    )


if __name__ == "__main__":
    main()
