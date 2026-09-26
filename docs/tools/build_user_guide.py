#!/usr/bin/env python3
"""Build the self-contained user guide HTML and optionally print it to PDF.

Requirements: Python Markdown 3.8.2 (`python -m pip install Markdown==3.8.2`).
PDF additionally requires a local Chrome/Chromium executable.

python docs/tools/build_user_guide.py
python docs/tools/build_user_guide.py --pdf --chrome /usr/bin/google-chrome
"""
from __future__ import annotations

import argparse
import base64
import html
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unicodedata

import markdown

DOCS = Path(__file__).resolve().parents[1]
CSS = """
:root { color-scheme: light; }
* { box-sizing:border-box; }
body { margin:0; color:#18283b; background:#eef2f7;
  font-family:'Noto Sans CJK KR','Malgun Gothic',sans-serif; line-height:1.85; }
main { max-width:1100px; margin:32px auto; padding:44px 56px; background:white;
  box-shadow:0 8px 35px #1b2b4012; }
h1 { font-size:34px; margin-top:0; color:#173960; }
h2 { border-top:3px solid #345d8c; padding-top:22px; margin-top:60px; color:#173960; }
h3 { margin-top:34px; color:#274d77; }
a { color:#1b5fb3; text-underline-offset:3px; }
img { display:block; width:100%; height:auto; border:1px solid #d8e0ea;
 border-radius:8px; margin:24px 0 10px; }
p:has(>img) { break-inside:avoid; break-after:avoid; }
p:has(>em:only-child) { font-size:13px; color:#526376; margin-top:6px; }
blockquote { margin:24px 0; padding:12px 20px; background:#edf3fb;
 border-left:4px solid #496e9c; font-size:14px; }
table { width:100%; border-collapse:collapse; font-size:14px; margin:20px 0; }
th,td { text-align:left; vertical-align:top; padding:10px 12px; border:1px solid #d4deea; }
th { background:#eaf0f8; }
li { margin:5px 0; }
code { background:#edf1f6; border-radius:3px; padding:2px 4px; }
.toolbar { position:sticky; top:0; z-index:10; background:#173960; color:white;
 padding:10px 24px; display:flex; justify-content:space-between; align-items:center; }
.toolbar a { color:white; }
button { cursor:pointer; padding:7px 18px; border:0; border-radius:5px; }
@media(max-width:700px) { main { margin:0; padding:24px 18px; } table { font-size:12px; }
th,td { padding:6px; } }
@page { size:A4; margin:15mm 14mm;
 @bottom-left { content:'d-ddeck 사용자 가이드 · 1.0.6'; font-size:8pt; color:#526376; }
 @bottom-right { content:counter(page) ' / ' counter(pages); font-size:8pt; color:#526376; }
}
@media print {
 body { background:white; font-size:10pt; line-height:1.65; }
 main { max-width:none; margin:0; padding:0; box-shadow:none; }
 .toolbar { display:none; }
 h1 { font-size:25pt; } h2 { break-before:page; margin-top:0; padding-top:10px; font-size:18pt; }
 h3 { break-after:avoid; margin-top:18px; font-size:13pt; }
 img { max-height:150mm; object-fit:contain; margin:12px 0 6px; }
 table { font-size:8.5pt; } th,td { padding:6px 8px; }
 tr, blockquote { break-inside:avoid; } thead { display:table-header-group; }
 p { orphans:3; widows:3; } a { color:inherit; }
}
"""


def slugify(value: str, separator: str) -> str:
    value = unicodedata.normalize('NFKC', value).strip().lower()
    value = re.sub(r'[^\w\s-]', '', value)
    return re.sub(r'[-\s]+', separator, value)


def build() -> Path:
    source = (DOCS / '사용자-가이드.md').read_text(encoding='utf-8')
    body = markdown.markdown(source, extensions=['tables', 'toc'],
                             extension_configs={'toc': {'slugify': slugify}})

    def embed(match: re.Match) -> str:
        relative = html.unescape(match.group(1))
        path = (DOCS / relative).resolve()
        if not path.is_relative_to(DOCS) or not path.is_file():
            raise ValueError(f'Missing or invalid image: {relative}')
        encoded = base64.b64encode(path.read_bytes()).decode('ascii')
        return 'src="data:image/png;base64,' + encoded + '"'

    body = re.sub(r'src="([^"]+\.png)"', embed, body)
    # Keep supporting Markdown documents clickable next to the standalone HTML.
    output = DOCS / '사용자-가이드.html'
    output.write_text('<!doctype html>\n<html lang="ko"><head><meta charset="utf-8">'
                      '<meta name="viewport" content="width=device-width,initial-scale=1">'
                      '<title>d-ddeck 사용자 가이드 · 1.0.6</title><style>' + CSS +
                      '</style></head><body><div class="toolbar"><span>d-ddeck · 사용자 가이드</span>'
                      '<button onclick="window.print()">인쇄 / PDF 저장</button></div><main>' +
                      body + '</main></body></html>\n', encoding='utf-8')
    print(f'HTML: {output}')
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pdf', action='store_true')
    parser.add_argument('--chrome', default=None)
    args = parser.parse_args()
    output = build()
    if args.pdf:
        chrome = args.chrome or shutil.which('google-chrome') or shutil.which('chromium')
        if not chrome:
            parser.error('Chrome/Chromium not found; pass --chrome PATH')
        pdf = DOCS / '사용자-가이드.pdf'
        with tempfile.TemporaryDirectory(prefix='ddeck-guide-chrome-') as profile:
            subprocess.run([chrome, '--headless', '--disable-gpu', '--no-pdf-header-footer',
                            '--no-first-run', '--disable-background-networking',
                            f'--user-data-dir={profile}', f'--print-to-pdf={pdf}',
                            output.as_uri()], check=True, timeout=120,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        if not pdf.is_file() or pdf.stat().st_size == 0:
            raise RuntimeError('Chrome did not produce a PDF')
        print(f'PDF: {pdf}')


if __name__ == '__main__':
    main()
