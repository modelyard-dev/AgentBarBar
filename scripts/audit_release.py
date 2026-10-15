#!/usr/bin/env python3
"""Fail packaging if personal data or unexpected files enter a release bundle."""
import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
parser.add_argument('--report', type=Path)
args = parser.parse_args()
app = args.app.resolve()
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
icon = app / 'Contents/Resources' / info.get('CFBundleIconFile', '')
if not icon.is_file() or icon.read_bytes()[:4] != b'icns':
    raise SystemExit('Bundle icon declaration does not resolve to a valid ICNS file')
forbidden = [str(Path.home()).encode(), str(Path(__file__).resolve().parent.parent).encode(), b'SECRET_CANARY']
# Compare against the live local credential without printing or packaging it.
runtime = Path.home() / 'Library/Application Support/AgentBarBar/runtime.json'
if runtime.exists():
    token = json.loads(runtime.read_text()).get('token', '')
    if token:
        forbidden.append(token.encode())
allowed_exact = {'Contents/Info.plist', 'Contents/MacOS/AgentBarBar', 'Contents/_CodeSignature/CodeResources', 'Contents/Resources/THIRD_PARTY_NOTICES.txt', 'Contents/Resources/Licenses/zstd-BSD.txt', 'Contents/Resources/Dashboard/index.html', 'Contents/Resources/Dashboard/popup.html', 'Contents/Resources/Dashboard/app-icon.png', 'Contents/Resources/Dashboard/mark.svg'}
files = []
for file in sorted(app.rglob('*')):
    if file.is_symlink():
        raise SystemExit('Release bundle contains an unexpected symlink')
    if not file.is_file():
        continue
    relative = file.relative_to(app).as_posix()
    resource = file.relative_to(app / 'Contents/Resources').as_posix() if file.is_relative_to(app / 'Contents/Resources') else ''
    allowed = relative in allowed_exact or resource == 'AgentBarBar.icns' or (resource.startswith('Dashboard/assets/') and file.suffix in {'.js', '.css'}) or (resource.startswith('MenuBar/') and file.suffix in {'.svg', '.png'})
    if not allowed:
        raise SystemExit(f'Unexpected release resource: {relative}')
    data = file.read_bytes()
    if resource == 'Dashboard/app-icon.png' and data[:8] != b'\x89PNG\r\n\x1a\n':
        raise SystemExit('Dashboard application icon is not a PNG')
    if any(value in data for value in forbidden):
        raise SystemExit(f'Local/private build data detected in {relative}')
    files.append({'path': relative, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
report = {'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'], 'status': 'passed', 'checks': ['resource allowlist', 'no local home or repository paths', 'no local API credential', 'no database, logs, browser snapshots, fixtures or source files'], 'files': files}
if args.report:
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(f"Release privacy audit passed: {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}), {len(files)} files")
