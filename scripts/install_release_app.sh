#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == "--windows" ]]; then
  TASK_POWERSHELL="$(command -v pwsh.exe || command -v powershell.exe)"
  "$TASK_POWERSHELL" -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$TASK_ROOT/scripts/windows-port/install_release_app.ps1")" -InstallerPath "$(cygpath -w "${2:?Windows installer path required}")"
  exit $?
fi
"$TASK_ROOT/scripts/build_release_app.sh"
TASK_APP="$TASK_ROOT/build/AgentBarBar.app"
TASK_DEST="${AGENTBARBAR_INSTALL_DIR:-/Applications}/AgentBarBar.app"
if [[ -d "$TASK_DEST" ]]; then
  TASK_OLD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$TASK_DEST/Contents/Info.plist")"
  TASK_OLD_BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$TASK_DEST/Contents/Info.plist")"
  TASK_NEW_VERSION="$(cat "$TASK_ROOT/VERSION")"
  TASK_NEW_BUILD="$(cat "$TASK_ROOT/BUILD_NUMBER")"
  if [[ "$TASK_OLD" == "$TASK_NEW_VERSION" && "$TASK_OLD_BUILD" =~ ^[0-9]+$ && "$TASK_NEW_BUILD" =~ ^[0-9]+$ && "$TASK_OLD_BUILD" -ge "$TASK_NEW_BUILD" ]]; then
    echo 'Increase BUILD_NUMBER with scripts/set_version.sh before replacing an equal or newer installed build.' >&2
    exit 1
  fi
fi
mkdir -p "$(dirname "$TASK_DEST")"
TASK_STAGE="$(dirname "$TASK_DEST")/.AgentBarBar-install-$RANDOM-$RANDOM.app"
ditto "$TASK_APP" "$TASK_STAGE"
codesign --verify --strict "$TASK_STAGE"
# Stop only this installed executable; never another Agent or a process matched by a loose name.
TASK_DEST="$TASK_DEST" python3 - <<'PY'
import os,signal,subprocess,time
target=os.environ['TASK_DEST']+'/Contents/MacOS/AgentBarBar'
for line in subprocess.run(['ps','-axo','pid,comm'],capture_output=True,text=True,check=True).stdout.splitlines():
    parts=line.strip().split(None,1)
    if len(parts)==2 and parts[1]==target:
        try:os.kill(int(parts[0]),signal.SIGTERM)
        except ProcessLookupError:pass
time.sleep(0.3)
PY
if [[ -d "$TASK_DEST" ]]; then
  TASK_BACKUPS="$TASK_ROOT/build/install-backups"
  mkdir -p "$TASK_BACKUPS"
  mv "$TASK_DEST" "$TASK_BACKUPS/AgentBarBar-$TASK_OLD-$(date +%Y%m%d%H%M%S).app"
fi
mv "$TASK_STAGE" "$TASK_DEST"
codesign --verify --strict "$TASK_DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TASK_DEST"
open "$TASK_DEST"
echo "Installed and launched $TASK_DEST"
