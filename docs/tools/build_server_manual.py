#!/usr/bin/env python3
"""Render the server manual to HTML and optionally PDF.

Requires Markdown==3.8.2 and (for --pdf) Google Chrome/Chromium.
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
import tempfile
from pathlib import Path

import markdown
from build_user_guide import CSS


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pdf", action="store_true")
    args = parser.parse_args()
    docs = Path(__file__).resolve().parents[1]
    source = docs / "서버-운영-매뉴얼.md"
    body = markdown.markdown(
        source.read_text(),
        extensions=["tables", "toc", "fenced_code"],
        extension_configs={
            "toc": {
                "slugify": lambda value, separator: (
                    "section-" + hashlib.sha256(value.encode()).hexdigest()[:12]
                )
            }
        },
    )
    css = CSS.replace("사용자 가이드 · 1.0.7", "서버 운영 매뉴얼 · 1.0.13")
    css += """
pre { white-space:pre-wrap; overflow-wrap:anywhere; background:#edf1f6;
 padding:12px; border-radius:5px; font-size:12px; line-height:1.6; }
pre code { padding:0; background:none; }
code { font-family:'Noto Sans Mono CJK KR',monospace; overflow-wrap:anywhere; }
@media print { pre { font-size:8pt; break-inside:avoid; }
h2 { break-before:auto; margin-top:24pt; } h2,h3 { break-after:avoid; }
.toc { font-size:9pt; } }
"""
    output = docs / "서버-운영-매뉴얼.html"
    output.write_text(
        '<!doctype html><html lang="ko"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        "<title>d-ddeck 서버 운영 매뉴얼</title><style>"
        + css
        + '</style></head><body><div class="toolbar"><span>d-ddeck 서버 운영 매뉴얼 · 1.0.13</span>'
        '<button onclick="window.print()">인쇄 / PDF 저장</button></div><main>'
        + body
        + "</main></body></html>",
        encoding="utf-8",
    )
    print(output)
    if args.pdf:
        chrome = shutil.which("google-chrome") or shutil.which("chromium")
        if not chrome:
            parser.error("Chrome/Chromium is required for PDF output")
        pdf = docs / "서버-운영-매뉴얼.pdf"
        with tempfile.TemporaryDirectory(prefix="ddeck-manual-chrome-") as profile:
            subprocess.run(
                [
                    chrome,
                    "--headless",
                    "--disable-gpu",
                    "--no-pdf-header-footer",
                    "--no-first-run",
                    "--disable-background-networking",
                    f"--user-data-dir={profile}",
                    f"--print-to-pdf={pdf}",
                    output.as_uri(),
                ],
                check=True,
                timeout=120,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
        if not pdf.is_file() or not pdf.stat().st_size:
            raise RuntimeError("PDF was not generated")
        print(pdf)


if __name__ == "__main__":
    main()
