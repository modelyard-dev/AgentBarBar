#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == "--windows" ]]; then
  TASK_VERSION="${2:?Usage: set_version.sh --windows version build}"
  TASK_BUILD="${3:?Windows build number required}"
  [[ "$TASK_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$TASK_BUILD" =~ ^[1-9][0-9]*$ ]] || exit 1
  if command -v python3 >/dev/null 2>&1; then TASK_PYTHON=python3; else TASK_PYTHON=python; fi
  "$TASK_PYTHON" - "$TASK_ROOT" "$TASK_VERSION" "$TASK_BUILD" <<'PY'
import pathlib, re, sys
root=pathlib.Path(sys.argv[1]);version=sys.argv[2].encode();build=sys.argv[3].encode()
config=root/'Windows/src-tauri/tauri.conf.json'
raw=config.read_bytes()
updated,count=re.subn(rb'(?m)^([ \t]*"version"[ \t]*:[ \t]*")[^"]+(",[ \t]*\r?)$',lambda m:m.group(1)+version+m.group(2),raw,count=1)
if count!=1: raise SystemExit('Windows Tauri version field not found exactly once')
config.write_bytes(updated)
cargo=root/'Windows/src-tauri/Cargo.toml'
raw=cargo.read_bytes()
updated,count=re.subn(rb'(?m)^(version = ")[^"]+("[ \t]*\r?)$',lambda m:m.group(1)+version+m.group(2),raw,count=1)
if count!=1: raise SystemExit('Windows Cargo package version field not found exactly once')
cargo.write_bytes(updated)
build_path=root/'Windows/BUILD_NUMBER'
old=build_path.read_bytes()
ending=b'\r\n' if old.endswith(b'\r\n') else b'\n' if old.endswith(b'\n') else b''
build_path.write_bytes(build+ending)
PY
  echo "AgentBarBar Windows $TASK_VERSION ($TASK_BUILD); macOS unchanged"
  exit 0
fi
TASK_VERSION="${1:?Usage: set_version.sh version [build]}"
if [[ ! "$TASK_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo 'Use a numeric major.minor.patch version' >&2; exit 1; fi
TASK_BUILD="${2:-$(( $(cat "$TASK_ROOT/BUILD_NUMBER") + 1 ))}"
if [[ ! "$TASK_BUILD" =~ ^[1-9][0-9]*$ ]]; then echo 'Build must be a positive integer' >&2; exit 1; fi
printf '%s\n' "$TASK_VERSION" > "$TASK_ROOT/VERSION"
printf '%s\n' "$TASK_BUILD" > "$TASK_ROOT/BUILD_NUMBER"
echo "AgentBarBar $TASK_VERSION ($TASK_BUILD)"
