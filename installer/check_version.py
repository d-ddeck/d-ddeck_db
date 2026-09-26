"""Release names must describe the code actually being built."""
import re
import sys
from pathlib import Path

root=Path(__file__).resolve().parents[1]
version=sys.argv[1]
if not re.fullmatch(r'\d+\.\d+\.\d+',version):raise SystemExit('Invalid release version')
app=re.search(r'^version:\s*([^\s]+)',(root/'app/pubspec.yaml').read_text(),re.M).group(1)
server=re.search(r'VERSION\s*=\s*["\']([^"\']+)',(root/'backend/app/version.py').read_text()).group(1)
client=re.search(r"appVersion\s*=\s*'([^']+)'",(root/'app/lib/core/version.dart').read_text()).group(1)
if app.split('+')[0]!=version or server!=version or client!=app:raise SystemExit('Tag, pubspec, client and server versions must match')
print('Verified release version:',version)
