#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_VERSION="$(cat "$TASK_ROOT/VERSION")"
TASK_DIST="$TASK_ROOT/build/distribution"
mkdir -p "$TASK_DIST"
"$TASK_ROOT/scripts/build_release_app.sh"
TASK_STAGE="$(mktemp -d "$TASK_ROOT/build/.dmg-XXXXXX")"
trap 'rm -rf "$TASK_STAGE"' EXIT
TASK_CONTENTS="$TASK_STAGE/contents"
mkdir -p "$TASK_CONTENTS"
ditto "$TASK_ROOT/build/AgentBarBar.app" "$TASK_CONTENTS/AgentBarBar.app"
ln -s /Applications "$TASK_CONTENTS/Applications 应用程序"
TASK_VERSION="$TASK_VERSION" python3 - "$TASK_CONTENTS" <<'PY'
import os,sys
from pathlib import Path
version=os.environ['TASK_VERSION']
Path(sys.argv[1], '安装说明.txt').write_text(f'''AgentBarBar {version}

安装 / Install
1. 将 AgentBarBar 拖入 Applications（应用程序）文件夹。
   Drag AgentBarBar to the Applications folder.
2. 打开 App，点击菜单栏图标查看 AI 用量。
   Open the app, then click its menu bar icon to view AI usage.

首次打开 / First launch
若系统提示无法验证开发者，请前往“系统设置 → 隐私与安全性”，点击“仍要打开”。
If macOS cannot verify the developer, go to System Settings → Privacy & Security and click Open Anyway.

适用于 M 系列 Mac，macOS 14 或更新版本。
Requires an Apple Silicon Mac with macOS 14 or later.
''', encoding='utf-8')
PY
python3 "$TASK_ROOT/scripts/audit_release.py" "$TASK_CONTENTS/AgentBarBar.app" --report "$TASK_DIST/AgentBarBar-$TASK_VERSION-privacy-audit.json"
TASK_DMG="$TASK_DIST/AgentBarBar-$TASK_VERSION-apple-silicon.dmg"
TASK_PYTHON="$TASK_ROOT/build/packaging-tools/bin/python"
if [[ ! -x "$TASK_PYTHON" ]]; then
  python3 -m venv "$TASK_ROOT/build/packaging-tools"
  "$TASK_PYTHON" -m pip install -r "$TASK_ROOT/scripts/requirements-packaging.txt"
fi
TASK_VOLUME="AgentBarBar $TASK_VERSION"
TASK_MOUNT="/Volumes/$TASK_VOLUME"
if [[ -e "$TASK_MOUNT" ]]; then echo "Eject the existing $TASK_VOLUME volume before packaging." >&2; exit 1; fi
TASK_RW="$TASK_STAGE/install-rw.dmg"
hdiutil create -volname "$TASK_VOLUME" -srcfolder "$TASK_CONTENTS" -format UDRW "$TASK_RW"
hdiutil attach -readwrite -nobrowse -mountpoint "$TASK_MOUNT" "$TASK_RW"
trap 'hdiutil detach "$TASK_MOUNT" >/dev/null 2>&1 || true; rm -rf "$TASK_STAGE"' EXIT
"$TASK_PYTHON" "$TASK_ROOT/scripts/style_dmg.py" "$TASK_MOUNT" --version "$TASK_VERSION" --preview "$TASK_DIST/AgentBarBar-$TASK_VERSION-install-preview.png"
python3 "$TASK_ROOT/scripts/audit_release.py" "$TASK_MOUNT/AgentBarBar.app"
hdiutil detach "$TASK_MOUNT"
hdiutil convert "$TASK_RW" -format UDZO -o "$TASK_DMG" -ov
hdiutil verify "$TASK_DMG"
(cd "$TASK_DIST" && shasum -a 256 "$(basename "$TASK_DMG")") > "$TASK_DMG.sha256"
echo "Packaged $TASK_DMG"
